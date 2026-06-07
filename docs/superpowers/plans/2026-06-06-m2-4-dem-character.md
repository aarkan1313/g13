# M2.4 - DEM Character Integration Plan

**Goal:** keep the M2.3 composition machine and tune its local character from the
committed DEM fingerprints. M2.4 should make the same good macro world read less
one-note by varying relief, ridge/detail scale, roughness, and carve strength from
real terrain measurements.

**Status 2026-06-06:** TEST-GREEN, PARKED-FOR-VISUAL after one visual failure.
The first mapping passed the numeric gate but looked bad (corduroy grooves / harsh
walls). The current mapping is deliberately subtle and the gate now includes the
far-world visual-fail hotspots.

**Scope lock:** DEM character tunes the existing machine. It does not replace the
uplift structure, does not introduce per-biome shape recipes, and does not start
erosion. Biomes remain the M2.2 classifier/skin.

## Design

The shader gets a small DEM-character table derived from
`wg-13/data/dem_fingerprints.json`. Each row is sorted by measured `slope_p95` and
contains:

- `slope_p95`: steepness ceiling / relief character.
- `ridge_character`: normalized Laplacian roughness.
- `spectrum centroid`: feature-scale bias from the DEM spectrum.
- `fine energy`: high-frequency content from the last spectrum bands.

`terrain_character(world_xz, uplift, seed)` blends continuously across this table.
The blend coordinate is mostly uplift (steep regions pull toward steep DEM
character) with a low-frequency region field so similar uplift regions can still
feel different. The output tunes existing M2.3 knobs, but only within a narrow
range centered near the visually accepted M2.3 constants:

- `relief_amp`
- `ridge_scale`
- `ridge_gain`
- `detail_amp`
- `carve_depth`

## Tasks

- [x] Add DEM-character helpers to `field_height.glsl`.
- [x] Route `composition_height()` through those helpers.
- [x] Add `wg-13/tests/m2_4_dem_character_check.gd`.
- [x] Run M2.4 + M2.3 + M2.2 + M2.1 + M1.7c gates.
- [x] Handle first visual fail by tightening the mapping and adding far-world
  hotspot samples to the gate.
- [x] Update `PROGRESS.md`, `DRIFT_LOG.md`, and `04_CODE_MAP.md`.
- [ ] Commit and push if green; launch live for human visual pass.

## Gate

`m2_4_dem_character_check.gd` must prove:

- deterministic height output for same seed/page;
- character variation across a wide world scan, not a one-note field;
- high-character/high-relief pages are measurably steeper than low-character pages;
- adjacent height steps stay bounded (no cliffs);
- M2.3 structure remains non-uniform.

The visual gate is the real success criterion: the world should still read like
the M2.3 terrain the human liked, but with more varied real-terrain personality.
