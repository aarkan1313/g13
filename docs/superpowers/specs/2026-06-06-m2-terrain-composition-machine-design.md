# M2 terrain — composition machine + per-biome recipes (WG10-informed)

**Date:** 2026-06-06
**Status:** design, approved in brainstorming; pending spec review → planning
**Type:** M2 terrain-synthesis redesign (supersedes the spectral-octave-sum approach)
**Supersedes:** the synthesis method in `2026-06-06-m2-dem-spectral-terrain-design.md`
(the DEM *distillation* part of that spec stands; only the runtime *synthesis*
method — "weight octaves by the amplitude spectrum" — is replaced).

## Why this redesign

The spectral octave-sum synthesis produced uniform terrain: at fine octave scales
it was "spiky oatmeal"; remapped to the DEM frequency range it became gentle
rolling ground everywhere, with mountains indistinguishable from plains. Root
cause: an amplitude spectrum applied as a global octave sum makes the SAME
statistical texture everywhere — it cannot place a discrete mountain *range* with
valleys between, because nothing says "a range stands HERE."

WG10 (the prior attempt, `WG10_MOUNTAIN_DEEP_DIVE.md`) made believable mountains
via **layered composition**: `base + range_envelope × ridge_detail − valley_carve`,
where a blurred low-frequency **envelope** concentrates relief into ranges and
**valley masks** carve between them. That structural composition is the missing
ingredient. We adopt WG10's *technique* (writing our own clean code, referencing
not copying — `00 §3.1`).

The human's framing, accepted: **each biome is its own structured terrain recipe**
(a mountain is ranges/ridges/valleys; a desert is dune fields; karst is towers) —
not one formula with knobs. Doing this to "best realistic" quality is genuinely a
**12-recipe project**, built and visually-accepted one recipe at a time (the same
gated discipline, ~12 iterations of it — NOT one ungated mega-push).

The M2.3 DEM distillation is NOT wasted: the per-archetype fingerprints
(slope_p95, spectrum) TUNE each recipe (relief magnitude, feature scales). The
runtime fingerprint loader + per-biome GPU table (already built/committed) stay.

## Architecture

**A composition machine + per-biome recipe functions, in one field shader.**

- **Composition machine** — shared GLSL primitives in `field_height.glsl`, all
  DEM-tunable:
  - `domain_warp(world_xz, seed)` — bends coordinates for organic, non-grid shapes.
  - `region_envelope(world_xz, seed, freq, threshold)` — a blurred low-frequency
    mask in [0,1]: where does relief "stand up" (ranges/uplands) vs stay low.
  - `ridged_fbm(p, seed, octaves, lacunarity, gain)` — sharp ridgelines (`1-|2n-1|`).
  - `value_fbm(...)` — smooth/rolling noise (already have value_noise).
  - `valley_carve(massif, valley_mask, depth)` — press down inter-range basins.
  - `blend_remap(h)` — final shaping.
- **Per-biome recipe functions** — `recipe_mountain(world_xz, seed, fp)`,
  `recipe_grassland(...)`, etc. Each composes the primitives into that biome's
  landform language. `fp` = the biome's DEM fingerprint (slope_p95 + spectrum).
- **Dispatch + border blend in `main()`**: select the recipe by biome id; at biome
  borders sample the 1–2 nearest biomes' recipes and blend weighted by climate
  distance (this delivers M2.5 border-blending naturally and keeps borders
  continuous — no cliffs).
- **Climate/biome selection (M2.1/2.2) unchanged** — the selector for which recipe
  applies where. **Contract preserved** (`00 §2.1`): one dispatch, one page
  `[h, t, m, biome]`; height channel stays R32F for collision (M1.7).
- **Fallback recipe**: biomes not yet built use a simple DEM-tuned gentle-rolling
  recipe, so the world is always whole — "mountains real, others placeholder-gentle."

## The mountain recipe (M2.4a — the first one)

WG10's composition, our implementation:
```
recipe_mountain(world_xz, seed, fp):
  warp     = domain_warp(world_xz, seed)
  region   = low_freq_noise(warp, ~1/30 km)                # sub-region "uppland-ness"
  envelope = smoothstep(thresh, 1, region)                 # WHERE ranges stand (0..1)
  ridges   = ridged_fbm(warp, octaves tuned by fp.spectrum)# sharp ridgelines
  relief_amp = amplitude * f(fp.slope_p95)                 # tall, from real slope
  massif   = envelope * ridges * relief_amp                # ranges only where envelope high
  valley   = (1 - envelope)                                # lowlands between
  carve    = valley_carve(massif, valley, depth)           # basins pressed down
  height   = continental_base + massif - carve + small_detail
```
The **envelope × ridges** is what creates discrete ranges with valleys between —
the structural fix. relief_amp from slope_p95 makes mountains genuinely tall;
plains (low slope_p95, envelope off) stay flat.

## Gated build sequence

- **M2.4a** — composition machine (primitives) + **mountain recipe** + fallback for
  the rest. GATE (test): determinism; range-structure (high-envelope cells reach
  high relief, low-envelope cells stay near-flat — a within-region relief spread,
  not uniform); no cliffs (max step bounded). GATE (visual, human): fly low over a
  mountain region — reads as real ranges and valleys, not oatmeal/uniform. **This
  is the make-or-break visual.**
- **PROVE-WITH-3 (decided 2026-06-06):** build only **3 recipes first** —
  **mountain (M2.4a), grassland (M2.4b), desert (M2.4c)** — the clearest landform
  contrast (rugged ranges / flat plains / dunes). Get all three beautiful +
  flythrough-accepted to PROVE the machine + recipe pattern works end-to-end before
  committing to the rest. Other biomes use the fallback recipe meanwhile.
- **M2.4d … (later, only after the 3 prove out)** — the remaining recipes
  (savanna, badlands, karst, volcanic, glacial, coast, wetland, rainforest,
  temperate, tundra), each its OWN gated step: build → DEM-tune → flythrough-accept
  → commit. One at a time. Not scheduled until the pattern is proven.
- **M2.5** — border blending: refine the recipe-blend if the natural blend needs it.
- **M2.6** — performance pass (LAST; profile the real composed field, M1.9-style).
- **M2.x** — milestone gate, tag `m2-complete`.

## What's reused vs replaced

- **Reused:** M2.1 climate, M2.2 biome selection, M2.3 distill tool + fingerprints,
  the runtime fingerprint loader + per-biome GPU table (field_gpu/page_pool/
  field_compute), the m2_4 gate's checks (adapted), the spawn-clearance fix.
- **Replaced:** `spectral_height()` octave-sum → the composition machine + recipes.
- **The biome GPU row** already carries slope_p95 + spectrum (BIOME_STRIDE=16) — the
  recipes read those. No Rust change needed for the mountain recipe beyond what's
  committed.

## Risks / watch-outs

- **Scope honesty:** 12 recipes is a real, large effort. Mitigated by gating each
  separately + a fallback recipe so the world is always shippable-green. Do NOT
  attempt multiple recipes in one step.
- **Envelope tuning:** the threshold/frequency that makes ranges "read" is visual —
  iterate with low-altitude captures + the human, not metrics alone (the repeated
  lesson). Land it on the mountain recipe before cloning the pattern.
- **Border blend cost/continuity:** sampling 2 recipes at borders ~doubles cost
  there; acceptable now (perf is M2.6). Must stay continuous (no cliffs) — the
  shared continental_base guarantees the floor; recipes blend on top.
- **Don't over-build the machine:** add a primitive only when a recipe needs it.
  Start with what the mountain recipe requires (warp, envelope, ridged, carve).
- **Determinism/contract:** world-space sampling only; one dispatch; height R32F.
  Biome chosen from macro-altitude (independent of recipe height) — no circularity.
- **Performance NOT now** (M2.6). If the machine is slow, note it; don't optimize.
