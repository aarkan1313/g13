# M2.4b — Validate the GPU-Portable Oracle, Then Integrate (Approach B)

Date: 2026-06-06
Status: DESIGN — approved for spec, pending writing-plans.
Supersedes nothing. EXTENDS `docs/superpowers/plans/2026-06-06-m2-4b-dem-structural-scaffold.md`
by inserting the missing decision gate before its Step 4 (runtime candidate lane).

## Why this design exists (the core problem)

`rust/structural_scaffold` contains **two different scaffold generators**, and they
are NOT interchangeable. This was the unexamined assumption in the prior M2.4b plan.

| | Window-port (`generate_seamsafe_fields`, `recipes/mountain.rs`) | Per-cell oracle (`sample_cell` / `synthesize_cell`, `lib.rs`) |
|---|---|---|
| Method | WG10 faithful: domain-warp -> oriented ridges -> Gaussian blur -> flow-routed channels -> carve -> floor blend -> final blend | Stateless per-world-coord: segment-distance ranges, analytic sine-curve channels, fbm / ridged-fbm detail |
| Neighbor access | YES — Gaussian blur, flow routing, 160-cell apron | NO — pure function of `(seed, x, z)` |
| Runs in the live per-cell GPU field (`field_height.glsl`)? | NO (architecturally incompatible — the shader computes each cell from world coords with zero neighbor access) | YES (same shape as `composition_height()`) |
| Has it ever been visually reviewed? | YES — every review so far (both 3D scenes, the PNG sheet) is this path | NO — never rendered |

**The trap:** the terrain the human reviewed and called promising (the window-port)
is architecturally not the terrain that can go into the live per-cell GPU field. The
only thing that CAN go in (the per-cell oracle) has never been looked at. Porting an
unreviewed approximation into the live shader, Rust params, collision, and biome
interaction — and THEN discovering it looks wrong — is the exact M2.4a failure
("passed gates, failed eyes"), just more expensive.

This design's job: **see the oracle before we integrate it.**

## Decision and pillar rationale (Approach B)

Chosen by applying the pillars (the user directed "follow pillars"):

- **Quality #1 — do it right, no slop / build it right once:** do not integrate an
  unreviewed approximation. Put eyes on the GPU-portable shape before paying for
  integration.
- **Survivability:** a cheap, reversible probe. The render harness already exists;
  swapping the data source touches nothing live. The live field stays untouched
  until we have earned the right to change it.
- **Modularity:** respects the field's clean per-cell statelessness (what makes it
  seamless + cheap at every LOD). The window-based GPU pipeline (Approach C) would
  fight that with aprons/blur/flow across page boundaries — deferred, not paid for
  until B proves it cannot deliver.
- **Performance:** deferred by design — we do not profile a path we have not
  decided to keep.

Approaches considered and not chosen now:
- **A (port to GLSL now, review live):** faster to "in the world," but reviews an
  unreviewed approximation in-engine with rebuild cycles. Rejected as the M2.4a
  risk pattern at higher cost.
- **C (window-based GPU pipeline — apron + blur + flow on GPU):** maximally faithful
  to the look already liked, but a major page-pipeline re-architecture (aprons
  across page boundaries, multi-pass compute, seam handling at every LOD). Likely
  an M2.6 / M6-scale effort. Held as the escalation target if B's Branch 3 fires.

## Procedural guarantee (a testable invariant)

Every scaffold value used by the live world MUST be a **pure function of
`(seed, world_x, world_z)`**:

- no runtime file I/O;
- no stored tiles or precomputed world data;
- no bake/precompute step before play;
- no lookup tables loaded at runtime.

DEMs inform **code constants only** (range widths, ridge/valley spacing, channel
density, the four style families, relief budgets — e.g. `style_params()` in
`lib.rs`). The DEMs shape what the procedure produces; they are never loaded by the
running game. This is "real-derived structure, invented per-cell on the fly," and
it is what makes the world infinite + deterministic + seamless.

NB: the window-port is ALSO procedural — but procedural in a window/region way (it
needs neighbors + an apron). The per-cell oracle is procedural in a per-point way.
Both are procedural; only the per-point one fits the live per-cell GPU field. That
distinction is the entire reason for the decision gate below.

This invariant is carried from the prior plan's non-goals:
- no static baked world as the final architecture;
- no runtime loading of large DEM files.

## What we build (the cheap probe)

Add an **oracle render path** to the existing review harness. The
`scaffold_3d_review.gd` scene reads a JSON; today `export-godot` writes it from the
window-port. We add an oracle variant:

- New CLI: `export-godot-oracle` (or `export-godot --source oracle|window`) that
  fills the **same JSON schema** by calling `sample_cell(seed, world_x, world_z)`
  per cell instead of `generate_fact_map_style`.
- Reuse the **exact same** `scaffold_3d_review.gd` scene and 2D PNG render path —
  only the data source changes. Zero new render code.
- Render the oracle at **playable scale** (the playable-scale scene's
  `display_span_m` / `height_scale` settings), so we judge it at the scale
  `demo.tscn` actually streams, not the compressed macro scale.

Output: an oracle review sheet + a 3D scene we can fly, directly comparable with the
window-port already in hand.

## The decision gate (what we do with what we see)

After reviewing the oracle at playable scale, one of three pre-decided branches:

1. **Oracle reads well** -> proceed to integration. The review WAS the de-risking.
2. **Oracle is close but off** -> tune `synthesize_cell` in fast Rust loops (no GPU,
   no rebuild-lock) until it reads right, re-review, then integrate.
3. **Oracle cannot capture what the window-port has** (e.g. flow-routed drainage is
   essential and analytic sine channels cannot fake it) -> STOP and escalate to the
   window-based GPU pipeline (Approach C) as its own larger milestone. We learn this
   cheaply instead of after a failed integration.

This branch point is the whole value of Approach B.

## Integration (only if the gate says go) — sketch, finalized later

Port the **proven** oracle into the live field as a CANDIDATE LANE, not a
replacement (matches the prior plan's Step 4):

- Translate `synthesize_cell` -> GLSL in `field_height.glsl` as a new height function.
- A **terrain-mode switch**: `REFERENCE` = M2.3 `composition_height`,
  `SCAFFOLD_CANDIDATE` = oracle. The accepted M2.3 world is never destroyed; toggle
  and compare live.
- Wire scaffold params through Rust (`page_pool` / `field_gpu`) the same way
  climate/biome params already flow (params block extension, std430-aligned).
- Keep the height-path contract intact: collision still reads channel-0 height;
  climate/biome unchanged (they read height additively, no circularity).
- Gates: M2.1 / M2.2 / M2.3 / M1.7c stay green; a new determinism check comparing
  the GLSL oracle against the Rust oracle (bit-comparable within float tolerance);
  **human visual pass at playable scale in `demo.tscn`** is the real gate.

Deliberately kept a sketch — its details are not finalized until the decision gate
greenlights it.

## Honest risk read (so future-you is not surprised)

The PROCESS will work: Approach B is cheap and finds out fast. Whether the TERRAIN
works is a genuine coin-flip — which is exactly why the expensive part is gated
behind the cheap answer.

Estimate: ~40% the oracle reads well within the cheap tuning loop (Branches 1-2);
~60% it needs the bigger window-based pipeline eventually (Branch 3).

Reasons for caution:
- The oracle is a different, simpler algorithm than the liked window-port. Window
  drainage comes from real flow routing + Gaussian smoothing; the oracle fakes
  channels with analytic sine curves and has no blur. Sine valleys can read too
  regular/wavy — a cousin of the M2.4a "corduroy" failure.
- This terrain has a track record of looking worse in motion than on paper
  (M2.4a + several M2.3 attempts failed visual review).
- Unit tests passing tells us nothing about whether it looks real ("passed gates,
  failed eyes," twice).

Reasons for hope:
- The oracle's bones are sound — segment-distance ranges + style families are real
  structure, not toy lines.
- Branch 2 makes a "close but off" oracle cheap to iterate (Rust loops, no rebuild).
- Even Branch 3 is a USEFUL answer: it prices the window-based GPU pipeline for an
  afternoon's cost instead of a failed integration.

Bottom line: this is the right next move regardless of which way the coin lands —
the cheapest way to learn the truth, and it cannot waste much.

## Gates (carried + added)

Test gates (from prior plan, still required):
- structural oracle determinism; region seam/apron exactness; route connectivity;
  page-pool invariants intact; M2.1 / M2.2 / M2.3 / M1.7c remain green.

Added for this design:
- oracle review artifacts render non-blank at playable scale (sky-only frame fails);
- (integration only) GLSL oracle == Rust oracle within float tolerance;
- (integration only) human visual pass at playable scale in `demo.tscn`.

Visual gates:
- oracle sheet/scene reviewed side-by-side with the window-port and WG10 references
  at PLAYABLE scale;
- overlays prove ranges/channels/passes are real facts;
- player-eye pass reads traversable at gameplay scale;
- the M2.4a failure hotspots included once runtime-integrated;
- human visual pass before M2.4 is marked complete.

## Explicit non-goals

- No more scalar DEM knob tuning as the main plan.
- No static baked world as the final architecture.
- No runtime loading of large DEM files.
- No per-biome terrain recipe fork yet.
- No erosion milestone yet (this scaffold is designed to feed erosion later).
- No integration of the per-cell oracle into the live field until the decision gate
  has greenlit it on visual review.

## Immediate next implementation bite

Build the oracle review path (CLI + reuse the existing harness), render it at
playable scale, and review the per-cell oracle for the first time. Then take the
decision-gate branch the review dictates.
