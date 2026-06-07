# M2.4 terrain-shape attempts — postmortem & recoverable work

**Written 2026-06-07** after rolling `main` back to the M2.3 visual-pass baseline
(`2dd06e5`, tag `backup-m2-3-visual-pass-2026-06-06`). M2.4a→d all tried to make
terrain SHAPE richer than the M2.3 composition machine; all failed visual review.
The code is removed from `main` for a clean reframe — but it's fully recoverable
from git (tag + SHAs below). This doc keeps the WHY so we don't repeat it.

## The one lesson that matters

**The terrain problem is MACRO RESOLUTION × LOD × VIEWING SCALE — not "where does
character come from."** Three attempts chased the character *source* (procedural
tuning, then real-DEM data) and all looked bad the same way. The DEM attempt
(M2.4d) was *proven* to reach the screen (A/B probe: mode-2 vs reference height
differed 564 m on a fine page, 2978 m on a coarse page) — and it STILL looked
blocky/terraced. Root cause: you fly/look from ~10 km altitude at COARSE-LOD
pages; the cached macro is 256 m/texel; bilinear-stretched 256 m texels read as
stair-steps/blocks **regardless** of whether they hold procedural noise or real
DEM character. So character was the wrong layer. Any future approach must first
answer: at the altitudes/speeds the world is actually viewed, what makes the
surface read smooth and believable — finer macro grid? a detail layer ABOVE the
macro grid? a different viewing/LOD model? surface entirely in per-cell detail?

## The attempts (each failed, each root-caused)

- **M2.4a — scalar DEM-knob character tuning.** Passed numeric gates twice, failed
  live twice (corduroy grooves / parallel walls). Lesson: scalar-DEM-tunes-noise
  doesn't read as real.
- **M2.4b — per-cell GPU oracle** (analytic `sample_cell` ported to `field_height.
  glsl`, terrain_mode 1). Walk-test failed: ~1 km coarse-LOD walls. Lesson: a
  per-cell field can't neighbor-smooth, so sharp carves alias at coarse LOD.
- **M2.4c — Approach C: cached macro + GPU bridge** (bake the WG10 window-port per
  ~30 km super-region, upload as R32F, sample with hardware bilinear, terrain_mode
  2). Mechanically correct + FIXED the oracle's walls — but read "noise fest": the
  macro was a single alpine procedural style and its detail bands were near-Nyquist
  at 256 m/texel.
- **M2.4d — DEM-driven macro** (real DEM patches modulate the bake). The full DEM
  pipeline WORKED mechanically; trashed because the 256 m macro grid is itself the
  visible artifact (see "the one lesson").

## Recoverable work (in git; NOT on `main`)

Everything below is reachable from tag **`backup-m2-4-all-attempts-2026-06-07`**
(HEAD `2eb7ee2` before the rollback). Pull individual pieces with
`git checkout <tag> -- <path>` if a future approach wants them.

- **DEM kernel library + tooling (the genuinely reusable bit).** `dem_distill`'s
  `kernels` subcommand extracts detrended, normalized real-DEM surface patches and
  curates a small atlas. Output asset: `wg-13/data/dem_kernels.bin` (32 kernels/
  archetype @128², 4 MB; mountain+grassland done). Runtime loader + deterministic
  non-repeating blender: `rust/gdext/src/macro_cache/kernels.rs` (`KernelAtlas`,
  `kernel_surface`). Spike findings: within-archetype kernel correlation ~0 (blends
  don't visibly repeat); raw-atlas of every patch was ~23 GB (infeasible) → curated.
  Commits: `a6ba652` (spike+asset), `bf8352e` (loader/blender).
- **The macro-cache + GPU bridge (M2.4c).** `macro_cache` (RegionMacro/MacroBake/
  RegionCache), `macro_gpu`, the PageParams 2×2 neighborhood, `dispatch_page`
  sampler binding, GLSL `macro_sample` + terrain_mode 2. Mechanically sound; only
  fails on the macro-resolution ceiling. Commits `3c38822`…`f5ae939`.
- **The WG10 window-port** (`rust/structural_scaffold`: `generate_seamsafe_fields`,
  blur+flow+apron). The macro baked from this.
- **Specs/plans:** `docs/superpowers/specs/2026-06-07-m2-4c-*`, `…-m2-4d-*`;
  `docs/superpowers/plans/2026-06-07-m2-4c-*`, `…-m2-4d-*`.

## State of `main` now

Clean M2.3 baseline: infinite streaming world (M1 complete), climate (M2.1),
10-biome classifier (M2.2), composition-machine terrain (M2.3 — "looks really
good"). All gates green. No M2.4 experiment code. The B-key terrain-mode toggle
and its candidate lanes are gone (they only existed in the M2.4 commits). NEXT:
reframe/refocus the M2 terrain direction with the lesson above in hand.
