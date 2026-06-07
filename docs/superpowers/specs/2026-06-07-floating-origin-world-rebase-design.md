# Floating origin (camera-relative world rebase) — design

**Date:** 2026-06-07
**Branch:** dem-grounded
**Status:** design, approved by user; implement gated (one part at a time)

## Context

The streaming clipmap world is anchored to absolute coordinate (0,0) forever. As
you fly, the camera's `global_position` grows without bound (turbo = 600*25 =
15000 u/s; the loaded reach is ~80–160 km). Fine pages stream fine, but nothing
pulls the world back toward the camera. Two consequences the user feels:

1. **"Never centered / you reach the outside edge."** The coarse ring re-selects
   on `floor(cam/span)` where the coarsest `span` is ~16–32 km, so coarse coverage
   is static between rare boundary crossings and the camera slides toward the edge
   of it — "the far edge becomes not far anymore."
2. **Far-distance float precision degrades.** At ~150 km from origin, 32-bit float
   precision is ~1 cm and falling → vertex shimmer/wobble at distance.

Both are the SAME fix: keep the camera near the Godot origin by periodically
rebasing the displayed world, while terrain stays computed in absolute world math
(so it generates identically — determinism preserved).

The pop-in problem is a SEPARATE, already-fixed concern (fog was off; see
`2026-06-07` DRIFT_LOG fog entry). This spec is centering + precision only.

## Key enabling fact (from the code)

`page_pool.rs` feeds the GPU field `origin_x = key.gx as f32 * span` — the page's
GRID INDEX times span. Terrain at a page is a pure function of its integer grid
coordinate. So if we rebase by a WHOLE NUMBER OF CELLS, the grid index for a given
absolute location is unchanged → the field generates identical terrain. The camera
(Godot world space) and the field (absolute grid index) are decoupled by a single
offset. This is what makes an integer-cell floating origin both safe and
zero-cost on the Rust/field side (no Rust change).

## The mechanism

The world is computed in ABSOLUTE coordinates and displayed in GODOT coordinates
that stay near (0,0). One offset connects them:

    godot_pos = absolute_pos - offset      (offset accumulates as we rebase)
    absolute_pos = godot_pos + offset

Each frame, before streaming: if the camera is ≥ 1 fine-cell from the Godot
origin, shift the displayed world back toward origin by a WHOLE NUMBER of fine
cells and bank that shift into `offset`. The ring center and the GPU field origin
are computed from the ABSOLUTE camera position, so terrain generation never
changes — only where it is drawn.

- **Continuous in feel:** the threshold is one level-0 page span (~508 m). In
  turbo that fires ~30×/sec; each shift is a whole cell applied in one frame,
  visually imperceptible (the world is identical before/after — only the float
  coordinates changed). Not fractional/per-frame (that would force a sub-cell
  offset into the GPU field — more code, more risk, fights determinism). Not
  per-coarse-cell (camera would wander km from origin — looser centering).
  Integer-fine-cell is continuous-feel + max precision + determinism-safe.
- **O(1) per rebase:** page instances, collision bodies, and the fly camera are
  all children of the `View` node, so moving `View.position` shifts them ALL in
  one op. The `Player` (a sibling CharacterBody3D) is shifted separately. Two node
  moves per rebase, not N.

## Components

### 1. `wg-13/scripts/world_origin.gd` — the engine module (new)

A small `RefCounted` (engine capability, not view-specific). Owns the offset and
the rebase decision; every Godot↔absolute boundary crossing goes through it so the
player / auto-tour / gates can't silently desync.

State:
- `offset: Vector3` — accumulated rebase, absolute meters. `godot = absolute - offset`.
- `cell_span: float` — rebase quantum (set to the level-0 page span). Tunable.

API:
- `to_absolute(godot_pos: Vector3) -> Vector3` — `godot_pos + offset`.
- `to_godot(absolute_pos: Vector3) -> Vector3` — `absolute_pos - offset`.
- `maybe_rebase(cam_godot: Vector3) -> Vector3` — if `abs(cam_godot.x) >= cell_span`
  or `abs(cam_godot.z) >= cell_span`, compute the integer shift in whole cells
  (`shift = round(cam_godot / cell_span) * cell_span`, X/Z only; Y untouched),
  do `offset += shift`, return `shift`. Else return `Vector3.ZERO`.
  (Only X/Z rebase — altitude is bounded, no precision benefit, and shifting Y
  would fight gravity/jump feel.)

### 2. View integration (both `world_view.gd` and `dem_grounded_world_view.gd`)

The mechanism lives in the module; the views call it identically (no duplicated
logic). In `_ready`: create the `WorldOrigin` with `cell_span = page_span`.
At the TOP of `_process`, before streaming:

    var shift := _origin.maybe_rebase(_cam.global_position)
    if shift != Vector3.ZERO:
        position -= shift                          # View + all page children + fly cam + collision bodies
        if _track != null and _track != _cam and is_instance_valid(_track):
            _track.global_position -= shift        # the Player (sibling), if walking

Then compute the ring center from the ABSOLUTE camera position:

    var abs_cam := _origin.to_absolute(tracker.global_position)
    cam_x = abs_cam.x ; cam_z = abs_cam.z          # feeds floor(cam/span) -> grid index, unchanged

`page_terrain_height(wx, wz)` (called by the player with Godot-space coords) must
convert its input to absolute before computing the grid index, since pages are now
displayed at shifted positions but keyed by absolute grid index.

New pages created after a rebase use `position = gx*span + span*0.5` as their LOCAL
position under `View`; since `View.position` carries the negative offset, their
GLOBAL position lands correctly relative to the shifted world. Self-consistent.

### 3. Determinism gate (the evidence)

`m1_8_origin_rebase_check.gd` (new gate): start at origin, read level-0 heights at
a fixed ABSOLUTE coordinate; teleport the camera far enough to force several
rebases; read the heights at the SAME absolute coordinate again; assert
BIT-IDENTICAL. Also assert `offset` is a whole multiple of `cell_span` and the
camera's Godot position stayed within `cell_span` of origin after rebasing while
cruising. PASS = the floating origin changed nothing about the terrain, only where
it's drawn.

## Non-goals / invariants preserved

- Pages stay world-anchored & deterministic: page (gx,gz) always generates the
  same terrain (the rebase is whole-cell; grid index unchanged). No field/Rust
  change. No toroidal/scrolling buffer.
- Never-black annulus, LOD selection, eviction, collision, fog — all unchanged
  (they operate on the absolute grid index, which the offset doesn't alter).
- Y is not rebased (altitude bounded; avoids fighting physics).

## Acceptance (human visual, the real gate)

- Fly out in any direction, including TURBO: the loaded world stays centered on
  you; you never approach an "outside edge"; the far edge stays far.
- No vertex shimmer/wobble at distance (precision held near origin).
- No regressions: no black/holes, no seams, collision/walk still correct after
  flying far then dropping to WALK, perf unchanged (rebase is O(1)).
- Gate `m1_8_origin_rebase_check` PASS (terrain bit-identical across rebases) plus
  the existing suite still green.

## Build sequence (gated, one part at a time)

1. `world_origin.gd` module + the determinism gate `m1_8_origin_rebase_check`
   (gate can be written against the module before view wiring). Commit at green.
2. Wire ONE view (`dem_grounded_world_view.gd`, the scene used for this work):
   rebase in `_process`, absolute ring center, `page_terrain_height` conversion.
   Run the gate + human fly-test (fly far + turbo: stays centered? walk after
   flying far still collides?). Commit at green.
3. Port to `world_view.gd` (production). Re-run gate + human fly. Commit at green.

Each step is independently revertable. If a rebase ever feels like a visible jump,
the lever is `cell_span` (smaller = more frequent, smaller shifts) — a tune, not a
re-architecture.
