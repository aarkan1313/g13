# Rust streaming-policy migration — design

**Date:** 2026-06-07
**Branch:** dem-grounded
**Status:** design, approved direction; implement gated (one step at a time)

## Why

`00_ARCHITECTURE.md` §4 is explicit: **Rust owns page scheduling (bounded work/
frame), residency/pool, and the read-only terrain view; the hot-path streaming
logic lives in Rust from the start, NOT prototyped in GDScript** (§4.3, lines
43/146-148). GDScript owns "thin scene assembly and editor-facing tuning only...
nothing that decides world shape" (§4, line 151).

Today the entire per-frame STREAMING POLICY lives in GDScript
(`dem_grounded_world_view.gd` / `world_view.gd` `_process`): the per-level ring
scan, nearest-first + direction-bias ordering, pin, eviction, and annulus
visibility. This is a pre-existing §4 deviation. It also has a measured perf cost
that is INHERENT to being in GDScript: ~366 `pin_page` FFI calls/frame, a full
GDScript ring scan per moving frame, and dict/string churn. The session's GDScript
micro-opts (skip-when-unchanged, int-key packing) helped (120->159fps) but polish
the wrong-language code. The architecturally-correct fix — and the real remaining
perf win — is to move the policy into `page_pool.rs`.

## The boundary (what moves, what stays)

- **MOVES to Rust (`page_pool.rs`) — POLICY ("what"):** which pages each level
  needs around the camera (ring scan), nearest-first + travel-direction ordering,
  per-frame production caps (fine/mid-coarse/coarsest, as today), pinning,
  eviction, and annulus visibility (a coarse page is hidden iff its 2x2 finer
  footprint is all resident). All on the integer grid index — pure CPU policy,
  no Godot nodes.
- **STAYS in GDScript (the view) — SCENE ASSEMBLY ("how it's shown"):** creating/
  recycling `MeshInstance3D` + `ShaderMaterial`, positioning them, binding the
  page's Texture2DRDs (height/climate/biome/normal), setting visibility, view-mode
  uniforms, custom AABB. This IS §4's "binds resident pages to the ring mesh." The
  view never decides policy; it executes the diff Rust hands it.
- **Floating origin stays in GDScript** (`world_origin.gd`): it shifts the View
  node + Player and converts camera Godot->absolute. The pool's new method takes
  the ABSOLUTE camera position, so the rebase is transparent to it (grid index
  unchanged — already proven by m1_8).

## The new Rust API

One method does the whole per-frame policy and returns a compact DIFF so the view
does minimal node work:

    update_streaming(
        cam_abs_x: f32, cam_abs_z: f32,
        ring_radius: i64, evict_margin: i64, num_levels: i64,
        travel_x: f32, travel_z: f32,          // smoothed unit dir (0,0 = none)
    ) -> Dictionary

It runs entirely on the integer grid (level span = base_span * 2^level), applies
the SAME three production modes that exist today (coarsest = unbounded floor; mid-
coarse = bounded eager; fine = bounded), produces affordable pages, pins all kept
pages, evicts outside keep_radius, and computes annulus visibility. It returns:

    {
      "added":   PackedInt32Array,   // flat [level,gx,gz, level,gx,gz, ...] newly produced this frame
      "removed": PackedInt32Array,   // flat [level,gx,gz, ...] evicted this frame (view recycles)
      "show":    PackedInt32Array,   // flat [level,gx,gz, ...] pages whose visible flag is TRUE
      "hide":    PackedInt32Array,   // flat [level,gx,gz, ...] pages whose visible flag is FALSE
    }

(Flat PackedInt32Array, not Array-of-Vector3i: cheapest marshalling across FFI;
the view strides by 3.) The pool keeps an internal `displayed: HashMap<PageKey,
DisplayState>` so it can emit only CHANGES (added/removed/visibility transitions),
not the full set each frame — that, plus doing the scan once in Rust, removes the
per-frame full GDScript pass and the 366 pin FFI calls.

Textures: the view still calls the existing getters (`request`* happens INSIDE
update_streaming now; for "added" pages the view calls `get_page_*_tex(level,gx,gz)`
which are cache hits). Alternatively update_streaming could return the RIDs, but
keeping the getters keeps the diff small and the texture-binding code unchanged.
DECISION: keep getters (smaller change, getters are already O(1) cache hits).

## What the view's `_process` becomes (thin)

    var abs := _origin.to_absolute(tracker.global_position)
    var shift := _origin.maybe_rebase(tracker.global_position)   # (unchanged, before)
    ...apply shift to View + Player...
    var diff := _pool.update_streaming(abs.x, abs.z, ring_radius, evict_margin,
                    num_levels, travel_n.x, travel_n.y)
    for i in range(0, diff["added"].size(), 3):
        var L=diff["added"][i]; var gx=diff["added"][i+1]; var gz=diff["added"][i+2]
        _make_or_recycle_instance(L, gx, gz)          # bind textures via getters
    for i in range(0, diff["removed"].size(), 3): _recycle(...)
    for i in range(0, diff["show"].size(), 3):   _set_visible(..., true)
    for i in range(0, diff["hide"].size(), 3):   _set_visible(..., false)

No ring scan, no candidate sort, no pin loop, no annulus dict in GDScript. The view
holds an `_instances` map (key->MeshInstance3D) only to find the node for a given
(L,gx,gz) when Rust says add/remove/show/hide.

## Invariants preserved (gate each)

- **Determinism / terrain-neutral:** policy is index-only; the field path is
  untouched. m1_8 (floating origin) + m1_7a (heights == FieldCompute) stay PASS.
- **Never-black:** the annulus rule is ported verbatim (hide coarse iff full 2x2
  finer footprint resident). m1_5c coverage/overlap gates stay PASS. The Rust
  `evict_outside` pin-guard already refuses to drop a pinned page.
- **M1.7 collision:** unchanged — collision still reads level-0 `get_page_heights`
  for the near radius; update_streaming just guarantees those pages are produced/
  pinned as before. m1_7a/b/c stay PASS.
- **Caps/spread:** the three production modes + per-frame caps move as-is (the
  M2.6 spread that keeps bursts off the budget). m2_6_burst stays green.

## Acceptance

- All existing gates green (m1_4, m1_5c coverage+overlap, m1_7a/b/c, m1_8, m2_1,
  m2_2, m2_3, m2_6_vram, m2_6_burst).
- A NEW gate `m1_5d_rust_streaming_check`: drive the pool's update_streaming over a
  flight path; assert (a) the resident set matches the expected ring, (b) annulus
  visibility matches the old GDScript rule on a sample, (c) no pinned page evicted,
  (d) the added/removed diffs reconcile to the resident set.
- Human fly (dem scene + production): identical look + never-black, and the
  120fps-dip frame is BETTER than the GDScript version (per-frame scan + 366 pin
  FFI calls gone). Re-run the attribution probe to confirm `process` dropped.

## Build sequence (gated, rebuild between Rust steps)

1. Rust: add `update_streaming` + internal `displayed` state in page_pool.rs
   (policy ported from the GDScript loop, integer-only). Add gate
   `m1_5d_rust_streaming_check`. Rebuild (CARGO_TARGET_DIR set; editor closed).
   Run the new gate + the determinism/coverage gates. Commit at green.
2. Wire `dem_grounded_world_view.gd` to call update_streaming; delete the GDScript
   ring scan / pin / evict / annulus passes from its `_process`. Keep make/recycle/
   bind. Run full suite + attribution probe + human fly. Commit at green.
3. Port the same wiring to `world_view.gd` (production). Full suite + human fly.
   Commit at green.

Each step independently revertable. If the Rust policy ever disagrees with the old
behavior on a gate, REVERT that step and diff the policy port (don't stack a fix).

## Risk notes

- Touches M1-foundational streaming + never-black + the M1.7 produce path. Go
  step-by-step, gate each, keep the field/collision contracts byte-identical.
- The editor locks `wg13.dll` -> close it / `run.ps1 -Stop` before `cargo build`,
  and set `$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"` (01_TOOLCHAIN).
- Keep `request_page*`/`evict_outside`/`pin_page` as-is for now (the gates use
  them); update_streaming calls them internally. A later cleanup can hide them if
  nothing else needs them.
