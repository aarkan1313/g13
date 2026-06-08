# M2.5b — Regional-archetype terrain (biomes are terrain) — design

**Date:** 2026-06-07
**Branch:** dem-grounded
**Status:** design; direction PROVEN by journey-vista captures of the probe
(`field_height_probe.glsl`, committed as reference). Implement gated + refine.

## Problem (from the M2.5a human gate)

M2.5a made relief "everywhere" but BINARY — the user flew it and said "basically
just mountains with some plains." The world reads as one uniform style (up=mountain
/ down=plain) with no middle and no regional identity. The user's target, verbatim:
"a mountain range here or there, a plain for a while, a singular huge mountain, a
swamp, then a forest then blah blah blah" — a JOURNEY through distinct regions, each
with its own landform character, plus one-off landmarks. "We have a good framework,
just the generation needs changed." And: the current generator "will probably need
trashed — don't feel like we have to save it."

So: KEEP the framework (streaming, pages, the climate/biome classifier, the
field-as-source-of-truth contract, the M2.4 analytic-normal seam fix). REWRITE the
generation (`composition_height`) from a single global recipe to regional archetypes.

## Proven approach (validated by captures)

The probe (`field_height_probe.glsl`) rewrote `composition_height` as:

1. **Region character from MACRO climate.** Sample `macro_altitude` + a macro
   temp/moisture (computed from macro_altitude, NOT detailed height) at a lightly
   domain-warped position. This breaks the circular dependency (terrain reads the
   SMOOTH macro climate; biome classification also reads macro — neither reads the
   detailed height it produces).
2. **Archetype shape recipes**, each its own landform character (world-height fn):
   `arch_plains`, `arch_forest_hills`, `arch_alpine`, `arch_swamp`, `arch_mesa`,
   `arch_highlands`. (Roster is data/extensible — adding one is a recipe + a weight.)
3. **Soft regional blend.** Each archetype gets a gaussian `band()` weight over the
   macro climate axes (e.g. alpine near high macro_alt; swamp near low+very-wet;
   mesa near dry+hot). Weighted-sum / normalized -> smooth borders, no hard seams,
   and a "middle" (highlands/forest-hills) so it's NOT binary.
4. **Macro base** `(macro_alt-0.35)*K` so regions sit at sensible elevations.
5. **Sparse landmark layer** `lone_peaks()` — rare deterministic giant cones placed
   on a coarse tile grid, climate-independent (the "singular huge mountain" anywhere).

Journey vistas across a 5-spot transect confirmed distinct regions (alpine /
open-plain-with-lone-peak / distant-range / rolling-lowland) — the journey feel +
landmarks. Framework untouched.

## What this milestone must do (beyond the probe)

The probe proved the DIRECTION. The milestone productionizes + refines it:

### Core
- **Replace `composition_height`** in the real `field_height.glsl` with the
  regional-archetype version (port from the probe, cleaned). Keep the function
  signature + the analytic-normal callers (the 4 neighbor evals in `main`) intact —
  they re-derive correctly from any continuous `composition_height`, so the seam fix
  keeps working BY CONSTRUCTION (it's pure world math, no texture/clamp).
- **Remove the dead M2.3 machinery** the rewrite obsoletes (uplift_field/valley_carve
  if unused) — but ONLY once nothing references them. No orphan code (slop).

### Refinement (each its own visual gate)
- **Tune each archetype** by vista capture so it reads believable (the probe's
  plains read dune-ish; fix). Low-altitude WALK matters most (project rule).
- **Transitions:** walk/fly across region borders — must blend smoothly, no cliffs
  at archetype boundaries (the blend is continuous, but amplitude jumps between
  archetypes can still make a step — verify and damp if needed).
- **Match biome COLORS to archetypes.** Today biome color (M2.2 classifier ->
  display palette) is independent of these archetypes. For "biomes ARE terrain" the
  color must agree with the shape: a swamp region must look swampy AND be swamp-
  colored. Options to settle at plan time: (a) drive the display biome from the same
  macro-climate the archetype uses, or (b) re-tune the M2.2 centroids so the
  classifier's regions line up with the archetype bands. Pick one; gate that the
  color region == the shape region.

### Landmarks
- Tune `lone_peaks` density/size so giants are rare + memorable, not a polka-dot
  field. Confirm they don't punch through as spikes at coarse LOD (view from afar).

## Invariants / gates (the discipline)

- **Determinism:** still pure function of (world_xz, seed). Re-run any determinism
  check; production of the same page twice = bit-identical.
- **Seam-free normals:** m1_4 (heights bit-identical across page edges) + the
  analytic normal must stay PASS — guaranteed if composition_height stays a pure
  continuous world function (no per-page state).
- **No-cliff:** m2_3 `max_step` gate — archetype blends + lone_peaks must not create
  vertical walls; if a believable steep range trips it, raise the threshold as a
  STATED decision (as in M2.5a), never silently.
- **Climate/biome gates:** m2_1/m2_2 PASS. If biome-color-matching re-tunes centroids,
  update the gate's expectations as a deliberate change.
- **Collision:** m1_7a/c PASS. Steeper archetypes may stress walkability -> that's
  M2.7 character work, logged, NOT a terrain rollback.
- **Perf:** the archetype version evaluates several fbm/ridged calls per cell (the
  probe sums 6 archetypes). Re-run m2_6_burst — if production cost rose materially,
  optimize (only evaluate archetypes with non-trivial weight, or cap octaves) the
  M1.9 way (measure first). The analytic normal calls composition_height 4x/cell, so
  cost matters — budget check is mandatory.

## Non-goals (avoid the M2.4 trap + scope creep)

- NOT DEM-grounded character ("where does character come from" = the proven trap).
  Archetypes are procedural recipes.
- NOT erosion/hydrology (M6) or water (M5) — though the user wants those pulled
  EARLIER; that's a roadmap-review decision AFTER this lands, noted separately.
- NOT textures/materials (M3) — still flat-color skin (but color must match region).
- NOT per-archetype collision specialization — collision reads the heights as-is.

## Risk notes

- **Perf** is the top risk (multiple archetype evals x4 for normals). Measure early;
  the "only-evaluate-significant-weight" optimization is the fallback.
- **Amplitude steps between archetypes** could read as terraces at borders — the
  blend is over WEIGHTS, but two archetypes of very different height still average;
  verify on a walk, damp via a shared macro_base carrying more of the elevation if
  needed.
- **Biome-color vs shape mismatch** is the subtle one — getting shape regional but
  leaving color on the old classifier would look wrong. Treat color-match as a
  first-class part of this milestone, not an afterthought.

## Build sequence (gated)

1. Port the probe's regional composition into `field_height.glsl` (replace
   composition_height; keep signature + normal callers). Re-run m1_4/m2_3/m2_1/m2_2/
   m1_7a/c + m2_6_burst. Fix dependent gates as stated decisions. Human vista gate:
   distinct regions present? Commit at green.
2. Tune archetypes (per-archetype vista + walk captures) until each reads believable.
   Commit at green.
3. Match biome color to archetype regions (pick option a or b). Gate: color region
   == shape region on a capture. Commit at green.
4. Tune lone_peaks density/size + far-LOD check. Commit at green.
5. Human walk+fly acceptance across a multi-region journey. DRIFT_LOG + PROGRESS.
   Then the roadmap review (pull M5 water / M6 erosion earlier).
