# M2.3b — Real macro-landform field (domain-warped ridged elevation)

**Date:** 2026-06-06
**Status:** design, pending implementation
**Type:** roadmap insertion (new gated step between M2.3 and M2.4) + redefinition of M2.5/M2.6

## Why this exists (the problem)

The terrain shape is plain value-noise fBM — isotropic "Perlin oatmeal." It has no
ridgelines, no connected valleys, no coherent landforms. This is the documented
attempt #1–12 failure mode (`00_ARCHITECTURE §1`, "no cloudy Perlin nebula").
Tuning per-biome amplitude/roughness harder cannot fix it — fBM is *structurally*
incapable of landforms — and would be **throwaway work** (`00 §1.1`): M6 erosion
would later replace fake high-frequency detail anyway.

The human judged the M2.3 shape "bad" on a live flyover and asked, correctly, to
build **non-deprecating infrastructure** rather than waste time tuning a placeholder.

## The reasoning (what is and isn't permanent)

Reading the full roadmap: **M6 erosion is the roadmap's real answer to "looks like
real terrain"** (hydraulic carving of valleys/ridges). DEMs (M2.5/6) provide
*statistics* that tune terrain; textures (M3) drape it; scatter (M4) reads its slope.

Therefore:
- **PERMANENT (build now, right):** a macro-elevation field with real continental
  structure — **domain warping** (kills the isotropic-blob signature) + **ridged
  noise** (sharp ridgelines, carved valleys). Erosion *carves into* this; DEMs
  *tune* it; textures/scatter *consume* it. Nothing downstream replaces it.
- **THROWAWAY (do NOT build now):** elaborate high-frequency detail — that is
  exactly what M6 erosion supplies for real. Building fake detail now is the
  throwaway-direction trap.
- **DEFERRED (unchanged sequence):** DEM plumbing (M2.5/6 — tunes this field once it
  exists), textures (M3).

## Scope

**In scope:**
1. Replace `base_landform` (currently 2 octaves of plain value-noise) with a
   **domain-warped ridged** macro-elevation field. This is the field's permanent
   base shape: large-scale ranges, basins, ridgelines, valleys, organic (non-blobby).
2. Per-biome **ridge-intensity modulation** on the shared macro field (mountains =
   full sharp ridges; plains = ridges flattened toward smooth; hills = partial),
   replacing the M2.3 per-biome `detail_amp/detail_rough` as the *primary* biome
   shape knob. Keep a small, cheap residual detail layer (erosion adds the real
   detail later).
3. New gate `m2_3b_landform_check.gd` proving the macro field's properties.

**Out of scope (explicitly, to avoid over-building per `00 §1.1`):**
- Hydraulic/thermal erosion (that is M6).
- DEM loading or DEM-stat plumbing (that is M2.5/6, which this step *redefines* as
  "tune this field," not "rescue placeholder noise").
- Textures, scatter, water.
- Heavy multi-octave high-frequency detail.

## Design

### The macro-elevation field (the permanent infra)

Computed in `field_height.glsl`, world-space, deterministic (`00 §5`), in the SAME
single GPU dispatch as climate/biome (one source of truth, `00 §2.1`).

**Ingredient 1 — Domain warp.** Before sampling the landform noise at `world_xz`,
offset the sample position by a low-frequency noise vector:
```
warp = warp_amp * (noiseVec(world_xz * warp_freq) - 0.5)
p = world_xz + warp
```
This bends otherwise-isotropic noise into organic flowing shapes (winding ranges,
irregular features). Cheap (2 extra noise samples), never deprecated.

**Ingredient 2 — Ridged noise.** Layer ridged octaves instead of plain value noise:
```
ridge(p) = 1.0 - abs(2.0*value_noise(p) - 1.0)   // creases -> ridgelines
ridged_fbm = sum over octaves of amp * ridge(p*freq)^sharpness, with gain/lacunarity
```
`ridge()^sharpness` controls how knife-edged the ridges are. This produces the
ridgeline/valley skeleton erosion will later carve.

**Macro elevation** = ridged_fbm over `BASE_OCTAVES`-ish low octaves of the warped
coordinate, scaled to world height units. This stays low-frequency enough to:
- be the shared, continuous base (no border cliffs — the M2.3 decision holds),
- drive biome selection via `macro_altitude` without LOD confetti (the M2.2 fix),
- remain deterministic and seamless (world-sampled).

> **Note on `macro_altitude`:** M2.2 introduced a *separate* low-freq landform for
> the biome altitude axis. M2.3b unifies the concept: the new ridged macro field IS
> the landform. `macro_altitude` becomes a normalized read of this same macro
> elevation (still low-frequency, still LOD-stable). This removes a redundant noise
> and makes "where the mountains are" and "what biome" agree by construction.

### Per-biome ridge intensity (biome shape, on the permanent layer)

Biome rows carry a `ridge_strength` (and keep a small `detail_amp` for cheap
residual surface texture). The shared macro field is computed once; biome scales how
much of its ridging shows:
```
height = lerp(smoothed_macro, ridged_macro, biome.ridge_strength)
       + biome.detail_amp * small_detail   // minimal; erosion replaces real detail
```
- Mountains: `ridge_strength ≈ 1` → full sharp ridges.
- Plains/grassland: `ridge_strength ≈ 0` → flattened toward smooth.
- Hills/forest: partial.

This preserves the validated M2.3 structure — **shared base, continuous across
borders (no cliffs), no circularity** (biome chosen from macro elevation which does
NOT depend on biome). All 16 existing gates must stay green.

### Data (biome rows, `00 §6`)

Extend the biome table: replace/repurpose `detail_rough` with `ridge_strength`; keep
`detail_amp` (now small residual). BIOME_STRIDE unchanged (8). Tuning a biome's shape
is editing its row. M2.5/6 will later compute these values from DEM statistics.

### Determinism & contract

- World-space sampling only (`00 §5`); same seed+pos → same height, seams hold.
- Height texture/array stays R32F single-channel (collision/M1.7 unchanged).
- Field/renderer contract unchanged (this is all field-side "what").
- One GPU dispatch; page still `[h, t, m, biome]`.

## Gate (test) — `m2_3b_landform_check.gd`

Output-provable, on real GPU readback:
1. **Determinism** — same page+seed → identical heights.
2. **Ridge structure exists** — the height field has ridge-like creases, not smooth
   blobs: measure the distribution of the discrete Laplacian / second difference and
   assert a meaningful fraction of cells are ridge/valley crease points (a smooth fBM
   has near-zero crease density; ridged noise has clear creases). Concretely: count
   local maxima along rows/cols (ridge crossings) and assert ridge density exceeds a
   threshold that plain fBM cannot reach.
3. **Anisotropy / non-blobbiness from warp** — (optional, if cleanly measurable)
   directional structure differs from isotropic; otherwise covered by the ridge test.
4. **Per-biome ridge intensity differs** — rugged biome's ridge/crease density >>
   flat biome's (the biome modulation taking effect), analogous to the M2.3 roughness
   test but on ridge structure.
5. **Continuity / no cliff** — max adjacent step bounded (shared base, no border
   cliff) — carried from M2.3.

## Gate (visual) — human, low altitude

Fly low: mountains read as **real ridged terrain** (ridgelines, valleys), plains are
flat, shapes are organic not blobby, biome borders transition (no cliffs). This is
the "no longer Perlin oatmeal" confirmation. PARKED for the human.

## Roadmap change (must update docs — `02 §1`)

- **ROADMAP.md / MILESTONE_2 / M2_DESIGN / PROGRESS:** insert **M2.3b — real
  macro-landform field** between M2.3 and M2.4.
- **Redefine M2.5/M2.6:** from "rescue placeholder noise with DEM stats" to **"tune
  the M2.3b ridged macro field with DEM-measured statistics"** (slope distributions,
  ridge spacing → warp/ridge/octave params). The offline tool + params plumbing are
  unchanged in spirit; what they feed is now a noise that can actually use them.
- **Note the relationship to M6 erosion:** M2.3b builds the macro skeleton; M6
  erosion carves real detail into it. M2.3b deliberately keeps detail minimal so it
  is not throwaway.

## Risks / watch-outs

- **Performance:** ridged + warp adds noise samples per cell. Watch the HUD `prod`
  row; it's still low-frequency macro work (few octaves), so cost should stay small.
  Measure, don't assume (the M1.9 discipline).
- **Don't over-build:** resist adding erosion-grade detail here. If it starts looking
  like erosion work, STOP — that's M6.
- **Keep all 16 gates green:** the shared-base/no-cliff/no-circularity structure must
  be preserved; the seam (m1_4) and continuity (m1_2) and collision (m1_7) gates are
  the guardrails that the height restructure didn't break the foundation.
- **`macro_altitude` unification:** changing it must not regress the M2.2 biome
  contiguity gate (it stays low-frequency).
