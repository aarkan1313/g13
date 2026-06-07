# M2.4d — DEM-driven terrain design (real-DEM surface character + procedural composition)

**Date:** 2026-06-07
**Status:** DESIGN (brainstormed; pending user review → writing-plans)
**Supersedes for terrain CHARACTER:** the single-alpine-style macro bake (M2.4c step 1). Does NOT
change the M2.4c GPU bridge (step 2) — that is reused verbatim.

---

## 1. Why this exists (the problem, root-caused)

M2.4c built a working two-layer field: a cached, smoothed MACRO layer (GPU-bridged, sampled by
`field_height.glsl` under `terrain_mode == 2`) + per-cell detail. The GPU bridge is mechanically
correct — the live walk-test confirmed it **fixed the per-cell oracle's ~1 km coarse-LOD walls**
(human: "the only thing macro cache has better is there's not weird walls that are straight
drop-offs"). But the terrain reads as a **"noise fest, holes and weird terrain all over."**

Root cause (confirmed three ways — code trace, the `m2_4b_scaffold_review.png` sheet, and an
independent review):

1. **The live runtime has never contained real DEM character.** `wg-13/data/dem_fingerprints.json`
   exists but **nothing consumes it**; every region bakes through ONE WG10-inspired alpine
   procedural style (`MacroBake` → `ALPINE_BRANCHING`). So we have *DEM-informed architecture*, not
   *DEM-calibrated terrain*. There is no real-terrain signal in the pipe to tune toward.
2. **The procedural synthesis is intrinsically high-frequency** (`generate_seamsafe_fields` was
   designed as a detailed mountain massif viewed at native dense resolution). Its `ridge_detail`
   (~1.3 km) and `near_detail` (~600 m) bands are near-Nyquist at the 256 m macro-texel grid, so
   they alias into the noise/holes at coarse LOD.
3. **Eval-surface rot makes it worse and harder to judge:** the per-cell detail (±70 m fBm) is
   painted UNIFORMLY everywhere (valley floors, slopes, peaks) — it reads as "busy/melted"; and the
   normal-view color ramp (`ring_displace.gdshader`) maps 60–360 m while the terrain is
   kilometre-scale, so almost everything clamps to pale highland and the shape is unreadable.

The fix is not more gain-tuning of single-style procedural noise. It is to make the macro
**DEM-driven**: real-world terrain character (from ALL the labeled DEMs, offline-distilled), placed
by the procedural composition machine, with structure-aware detail and a correct presentation.

## 2. Goal & non-goals

**Goal:** terrain whose CHARACTER comes from the real DEMs — believable rock, ridgelines, drainage,
badland fluting — woven with procedural composition so the world stays infinite, seamless, and
non-repeating. AAA-ish. Pillar-ordered (Quality > Survivability > Modularity > Performance).

**Non-goals (this milestone):**
- Not all 12 archetypes — **first cut = mountain + grassland** (proves the blend, biome routing, and
  the transition between two contrasting terrain types).
- Not erosion (M6).
- Not materials/textures (M3) — terrain is still untextured; color is debug-tint only.
- Not changing the M2.4c GPU bridge, the macro-cache (RegionCache/upload/sample), or the clipmap.

## 3. The hard invariant (00_ARCHITECTURE §6)

**The runtime NEVER opens a `.tif`.** DEMs live offline. "Use all the DEMs" = an OFFLINE tool
distills them into a compact runtime asset; the runtime synthesizes from that asset. Loading a
`.tif` at runtime is an architecture violation — STOP and log. This invariant SHAPES the design: the
expensive "use real terrain data" work is **offline / bake-time**, never per-frame.

## 4. Pillar-driven architecture decision (the DEM role)

**Procedural owns STRUCTURE/LAYOUT; real DEMs own SURFACE CHARACTER; DEM fingerprints CALIBRATE the
procedural structure.** Reasoning (pillars):

- **Survivability:** procedural composition is natively infinite + non-repeating; real-DEM *structure*
  is natively finite — lifting whole real ranges into an infinite world is the repetition/seam/tiling
  trap that killed attempts #1–12. So procedural MUST own the large-scale layout.
- **Quality:** what's been missing is real-terrain SURFACE character, not procedural structure (the
  M2.3 composition machine visual-passed: "looks really good"). Real DEM patches supply the surface
  believability that analytic noise cannot fake (and that the spectral/scalar approaches — M2.3b,
  M2.4a — failed to fake, twice).
- **Build it right once:** this split is the correct, survivable foundation; later mid-scale DEM
  character layers cleanly on top of it without a rewrite.

So: the composition machine places ranges/basins/valleys (calibrated by per-archetype DEM
fingerprints — slope ceiling, ridge character, spectrum), and **real DEM-derived surface patches
modulate the height within that structure** to give it real character.

## 5. Architecture — three layers

```
LIVE HEIGHT (terrain_mode 2, per page, per cell)  =
      MACRO base            (cached R32F, smooth, off-frame bake)   ── §5.2
    + structure-gated DETAIL (per-cell, gated by macro range/channel) ── §5.3
    [ fallback: composition_height where macro not present — never-black, unchanged ]

MACRO base (baked per ~30 km region, off-frame, cached) =
      procedural COMPOSITION structure   (where ranges/basins/valleys are; fingerprint-calibrated)
    × real DEM SURFACE character          (blended patches from the offline DEM kernel library)   ── §5.2
```

### 5.1 Offline: the DEM kernel library (extend `dem_distill`)

`dem_distill` already reads `.tif` → f32 heightfields, converts geographic→metric spacing, and emits
per-archetype fingerprints (spectrum/slope_p95/ridge). EXTEND it to ALSO emit a **per-archetype
surface-kernel bank**:

- For each archetype's tiles, extract **detrended, normalized, tileable height patches** — drop the
  continental trend (so we keep the *texture*: ridge structure, drainage, fluting — not the absolute
  elevation), normalize, and store a bank of patches per archetype. "All the DEMs": every labeled
  tile contributes.
- Emit a compact **binary runtime asset** (e.g. `wg-13/data/dem_kernels.bin` + a small JSON index)
  alongside the existing `dem_fingerprints.json`. This is NOT a `.tif`; it is the distilled asset the
  runtime is allowed to read. (Gitignore the source `.tif`s as today; the baked asset is small enough
  to track or regenerate — decided in planning.)
- Exact kernel representation (raw patch atlas vs. a spectral/exemplar form for non-repeating
  synthesis) is the **#1 technical risk** and is resolved in the plan's first task as a measured
  spike, not assumed here. The requirement: enough real character to read as "real terrain," small
  enough to ship, and synthesizable without visible tiling.

### 5.2 Bake-time: DEM-driven macro (extend `MacroBake`)

When a region bakes (already OFF-FRAME, the macro-cache's job), replace the single-alpine-style call
with a DEM-driven synthesis:

1. **Structure (procedural, fingerprint-calibrated):** the composition machine places the region's
   ranges/basins/valleys + flow-routed drainage. Its character knobs (relief amplitude, ridge
   sharpness, valley spacing, slope ceiling) are CALIBRATED from the region's archetype fingerprint
   (mountain vs grassland → very different structure). Drop the jagged near-Nyquist procedural detail
   bands (they're replaced by real DEM character).
2. **Surface character (real DEM kernels):** modulate the structured height with blended DEM patches
   for the region's archetype — domain-warped, multi-patch-mixed, faded across archetype boundaries —
   so the surface reads like real rock/drainage and never visibly repeats. Amplitude scales with the
   structure (ridges carry more character, basins less).
3. **Archetype/biome routing:** the region's archetype comes from the existing biome/climate field
   (mountain where high+steep, grassland where low+moderate), selecting which kernel bank +
   fingerprint to use. Transition regions blend two banks.

Output is the SAME `RegionMacro` (height + range/channel/material masks) the GPU bridge already
uploads and samples — **the bridge, cache, and shader sampling are unchanged.**

### 5.3 Live: structure-gated detail + correct presentation (the eval-surface fixes, now foundational)

- **Structure-gated detail:** the shader already carries the macro's `range` and `channel` masks but
  ignores them for height. Make per-cell detail STRUCTURE-AWARE: **suppress roughness on valley/
  channel floors, carry more on ranges.** (Fixes the "busy/melted everywhere" look; correct in the
  DEM world too.)
- **Km-scale color ramp:** retune `ring_displace.gdshader`'s normal-view height ramp from 60–360 m to
  the macro's real kilometre-scale range so shape is readable. (Visual-only, but it currently corrupts
  judgment — and we are relying on the human visual gate.)
- **Visual lanes (debug):** a way to view macro-height-only vs macro+detail vs the range/channel mask
  overlay, so each layer is judged in isolation during tuning (per the review's recommendation; debug
  toggles, default off).

## 6. What is reused unchanged (de-risking)

- The entire M2.4c GPU macro bridge (Tasks 2–6): `GpuRegionMacro`, the resident map, `dispatch_page`
  binding, `macro_sample`, `terrain_mode == 2`, `ensure_macro_neighborhood`. The macro is still a
  cached R32F field sampled with hardware bilinear; only WHAT goes into it changes.
- `RegionMacro` / `MacroBakeConfig` / `RegionCache` (step 1).
- The clipmap, streaming, collision contract, climate, biome classifier.
- The composition machine (M2.3) as the structure placer — calibrated, not replaced.

## 7. Build order (gated, bottom-up, foundation first — pillar mandate)

Each step ends in a gate; eval-surface fixes come EARLY so DEM terrain is judgeable as it lands.
Detailed tasks are the plan's job; the intended sequence:

1. **Eval-surface foundation** (cheap, correct regardless): km-scale color ramp + structure-gated
   detail (gate by range/channel) + visual lanes. Re-judge the CURRENT macro once readable + not
   uniformly busy. (May already be a big step up; informs the rest.)
2. **Offline kernel-library spike + tool:** extend `dem_distill` to extract DEM surface kernels;
   resolve the kernel representation by measurement (the #1 risk). Output the runtime asset.
3. **DEM-driven `MacroBake` for ONE archetype (mountain):** structure + real-kernel surface; fingerprint
   calibration; live render; walk-test mountains alone.
4. **Add grassland + archetype routing/transition:** prove the blend between two contrasting types and
   the biome routing. Walk-test the contrast + transition.
5. **Tune to AAA-ish by eye** (amplitudes, kernel mix, gating) over iterations; human visual gate.

## 8. Verification

- Output gates (per step): determinism, finite, seam-bounded (<1 m region borders), mode 0/1
  bit-identical (the DEM bake only changes `terrain_mode == 2`). The macro live gate stays as a
  guardrail (NOT the success criterion — it green-lit bad terrain once; documented).
- **The real gate is the human walk-test** (user decision): fly + walk mountain and grassland, judge
  believability, drainage readability, traversability, and the transition. Agent parks; does not
  self-certify the look.
- No `.tif` opened at runtime (architecture check; grep/assert the runtime never links the tif reader).

## 9. Risks & mitigations

- **(#1) Seamless, non-repeating blend of finite real patches → infinity.** Mitigation: procedural
  owns layout (patches modulate, don't place); domain-warp + multi-patch mixing; resolved by a
  measured spike before committing the representation (step 2).
- **Kernel asset size.** Mitigation: detrended/normalized patches are compact; measure in the spike;
  regenerate-offline if too big to track.
- **Archetype boundary seams** (mountain↔grassland). Mitigation: fingerprint + kernel blend across the
  transition; the composition machine already produces continuous structure.
- **Over-smoothing (iteration-1's lesson) vs noise (the original).** Mitigation: structure-gated
  detail + real DEM character target the middle; tuned by eye with the visual lanes.
- **Green-gate-on-bad-terrain (the project's signature trap).** Mitigation: human visual gate is
  primary; automated gates are explicitly guardrails.

## 10. Open items resolved in planning (not ambiguities — deferred detail)

- Exact kernel representation (raw patch atlas vs exemplar/spectral synthesis) — spike-resolved.
- Whether the baked kernel asset is git-tracked or regenerated — size-dependent, decided in step 2.
- Calibration mapping (which fingerprint scalar → which composition knob) — step 3, by measurement.
- Visual-lane UI (keys/HUD) — step 1 detail.
