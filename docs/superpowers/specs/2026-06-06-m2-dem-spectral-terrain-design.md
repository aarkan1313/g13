# M2 terrain shape — replanned: DEM-spectral-informed procedural synthesis

**Date:** 2026-06-06
**Status:** design, approved in brainstorming; pending spec review → implementation
**Type:** M2 strategy replan (supersedes the hand-tuned-noise M2.3/M2.3b approach)
**Supersedes:** `2026-06-06-m2-3b-macro-landform-field-design.md` (the ridged-noise attempt)

## Why this replan

M2.1 (climate) and M2.2 (biome selection) are done and good. But every attempt to
make the terrain SHAPE believable from hand-tuned procedural noise failed — ~10
iterations producing "Perlin oatmeal," then plateau-and-cliff "mesas." This is the
exact attempt #1–12 failure the project was built to avoid: **plain procedural noise
is structurally incapable of believable landforms** (no real ridgelines, connected
valleys, drainage structure). Tuning noise params cannot fix a shape that is
fundamentally wrong, and doing so is throwaway work (`00 §1.1`).

The project already owns the answer: **135 labeled real-world DEM tiles** across 12
archetypes that map ~1:1 onto the biomes (`03_DEM_CATALOG.md`). The original roadmap
sequenced them LAST and used them only for slope *statistics* to "tune the noise" —
but statistics tune a shape, and our shape was wrong, so there was nothing good to
tune. **The DEMs must inform the terrain SHAPE, and that must happen now, not last.**

User direction (verbatim intent): not pure noise (can't make landforms), not pasted
DEM tiles wholesale (a photo, not a generator, and repeats) — **distill the DEMs to
make the PROCEDURAL system produce believable terrain.** And: **do the hard
quality work first, take efficiency/performance "to live" after** (the M1.9 lesson:
don't optimize a placeholder; optimize the real workload).

## Strategy: spectral-informed synthesis

Distill each DEM archetype's **terrain fingerprint** offline, then synthesize
procedural terrain at runtime SHAPED to match that fingerprint. Output is fully
procedural (infinite, seamless, seedable, cheap) but its structure is borrowed from
real Earth — believability solved by data, not by guessing noise params.

The single biggest "looks real" lever is the **radial amplitude spectrum**: how a
terrain type distributes relief across spatial scales. Real mountains, deserts, and
plains each have a distinct spectral fingerprint; generic `0.5^octave` fBM matches
none of them. Matching the measured spectrum per archetype is what separates "CG
noise" from "looks like the Alps."

Pillar fit: Quality #1 (real structure, not slop; the permanent bridge real→generator,
build-it-right-once); Survivability #2 (runtime stays pure synthesis); Modularity #3
(fingerprints are swappable data, distilled offline — honors the no-`.tif`-at-runtime
hard rule); Performance #4 (optimized LAST, against the real field).

## Component 1 — Offline DEM distillation tool (the "hard stuff, done once")

A **separate offline Rust binary** in the workspace (e.g. `rust/dem_distill/`), NOT
linked into `wg13.dll` — so the runtime never opens a `.tif` (`03_DEM_CATALOG` hard
rule holds structurally). Crates: `tiff` (read), `rustfft` (spectrum).

For each of the 12 archetypes, aggregate its labeled tiles and compute:
1. **Radial amplitude spectrum** — 2D FFT per tile → radially-averaged power
   spectrum (amplitude vs spatial frequency). Convert degree→metre spacing with the
   cos(lat) correction (`03_DEM_CATALOG` flags this). Fit to ~8–10 **per-octave
   amplitude weights** spanning continental (~10 km) → fine (~10 m). This is the
   fingerprint.
2. **Slope distribution** — histogram of real slopes (mean, p95). Gives a *real*
   steepness ceiling so synthesis structurally cannot reproduce the vertical-cliff
   garbage (the data says how steep real terrain of this type actually gets).
3. **Ridge character** — a scalar for "ridged vs rounded" (from local-curvature /
   profile peakedness distribution) → drives the smooth↔ridged blend per archetype,
   from data not guesswork.

**Output:** a small committed params file (JSON, a few KB) — one row per archetype:
`{ name, octave_amplitudes[N], slope_p95, ridge_character }`. The `.tif`s stay on
disk (gitignored), never in the repo or runtime.

**GATE (test):** tool runs, emits the file; numbers sane — e.g. mountain spectrum
carries more mid/high-frequency energy than grassland; slope_p95 in plausible ranges;
all wired archetypes present.

## Component 2 — Runtime spectral-shaped field

The field GLSL synthesizes height as a domain-warped octave sum (organic low-octave
warp as before), but **each octave's amplitude = the biome archetype's measured
weight**, not `0.5^o`. Plus the per-archetype ridge-character blend and slope ceiling.

- The biome table (already pushed to the GLSL) gains each biome's octave-amplitude
  curve + slope ceiling + ridge character (from the distilled file, via Rust config).
- Shared continental base + per-biome spectral relief on top → continuous across
  borders (the validated no-cliff structure), now driven by real spectra.
- Biome selection (M2.2) chooses which archetype fingerprint applies (mountain biome
  → mountain spectrum). The archetypes already map ~1:1 to biomes.

**Why this fixes the failures:** every failure came from guessing octave
amplitudes/frequencies. Now they are measured from real Earth. A real mountain
spectrum produces real mountain relief distribution by construction.

**Performance:** deliberately NOT optimized first. Spend octaves/samples freely to
get it beautiful; confirm visually; then a dedicated efficiency pass (Component 4).

**GATE (test):** determinism (same world+seed → identical); per-biome synthesized
spectra match the measured fingerprints (differ as the data differs); no cliffs (max
adjacent step ≤ the archetype's data-derived slope ceiling). **GATE (visual, human):**
fly low — believable real-world landforms, mountains look like mountains, distinct
per biome.

## Revised M2 step sequence

- **M2.1 ✓** climate fields (done, kept).
- **M2.2 ✓** biome id, contiguous (done, kept) — biome now also selects the DEM
  archetype fingerprint.
- **M2.3** — Offline DEM distillation tool → per-archetype fingerprint file
  (Component 1). Gate: test (tool runs, sane numbers).
- **M2.4** — Spectral-shaped runtime field (Component 2). Start with **mountain +
  grassland + desert** (clearest contrast, catalog-recommended); gate test + visual;
  THEN expand to all 12 archetypes. Quality-first, not perf-tuned.
- **M2.5** — Border blending (blend spectral params + color across biome borders).
  Gate: visual, natural transitions.
- **M2.6** — Efficiency/performance pass: profile the REAL spectral field against the
  frame budget (HUD), optimize synthesis (octave count, sample reuse, async
  production if needed) the M1.9 way. Gate: test, frame budget held on the RTX 3070
  target.
- **M2.x** — milestone gate, tag `m2-complete`.

Erosion (M6) unchanged: later refinement of already-real terrain.

## What gets reverted

The uncommitted hand-tuned-noise field changes (the M2.3/M2.3b ridged/multifractal
experiments) are reverted to the M2.2 state (commit `c83da21`), keeping the good
climate + biome-selection work. The M2.3b spec is superseded by this doc. The
roadmap insertion commit (`948286d`) is superseded by the revised sequence here.

## Risks / watch-outs

- **Tiling/repetition:** synthesis is procedural (no pasted tiles), so no literal
  repeat; but a single spectrum applied everywhere could feel samey. Mitigated by
  domain warp + seed variation; revisit if visible.
- **Spectrum→synthesis fidelity:** matching a measured radial spectrum with a finite
  octave sum is approximate. Acceptable — the goal is "reads as real," confirmed by
  the human visual gate, not a perfect spectral reconstruction.
- **cos(lat) correction:** the distill tool MUST convert degree spacing → metres or
  slopes/spectra are wrong (`03_DEM_CATALOG` §sidecar).
- **Don't optimize early:** Component 4 (perf) is LAST, against the real field — not
  during M2.4. (M1.9 lesson, `01_TOOLCHAIN §6.1`.)
- **Offline/runtime boundary:** the distill tool is a separate binary; if any `.tif`
  read appears in `wg13.dll`, that's the architecture violation — STOP.
- **Don't over-build the distillation:** spectrum + slope + ridge-character only.
  Richer exemplar-synthesis is explicitly deferred (over-build for now, `00 §1.1`).
