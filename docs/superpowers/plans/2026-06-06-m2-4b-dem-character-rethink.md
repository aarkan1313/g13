# M2.4b - DEM Character Rethink

## Status

Planning after M2.4a visual failure. Do not implement more scalar tuning until
this plan is accepted.

## Diagnosis

M2.3 is the accepted baseline: one composition machine places macro structure
with uplift, ridges, base relief, valley carve, and detail.

M2.4a failed because it wired DEM fingerprint scalars directly into local ridge
and detail knobs. The result passed numeric gates but looked bad in the live
scene: corduroy grooves and harsh parallel walls, especially around far-world
range/lowland transitions. Softening the ranges reduced the numbers but did not
remove the bad visual character.

The lesson is that DEM fingerprints are useful as targets, not as per-sample
controls for high-frequency primitives.

## M2.4b Direction

Keep the M2.3 height function as the baseline. Use DEM data offline to define a
small set of terrain character families, then place those families with a
low-frequency region field.

Candidate families:

- `plain`: accepted M2.3 lowland behavior, low detail, no extra ridge emphasis.
- `rolling`: broader hills and softened ridges, still readable as traversable
  terrain.
- `rugged`: stronger relief and ridge presence, but with ridge scale held within
  an approved visual range.

Runtime should choose/blend families at region scale. It should not continuously
drive ridge scale, ridge gain, or detail amplitude from DEM scalar rows at cell
scale.

DEM data still matters:

- use fingerprints to set allowed family envelopes;
- use DEM library captures as visual references;
- use slope/roughness/relief only as guardrails, not as the source of the final
  look.

## Gate Changes

Numerics stay as guardrails, but they cannot certify the look alone.

Required gates:

- M2.3 regression: accepted structure remains present.
- M2.1/M2.2/M1.7c regressions remain green.
- Hotspot scan includes the two failed live-review positions:
  `(-164530, -62330)` and `(-175629, -26099)`.
- Capture tool produces a fixed gallery from origin, M2.3 accepted mountain
  region, and the failed M2.4a hotspots.
- Human visual pass is required before M2.4 is marked complete.

## Explicit Non-Goals

- No per-biome shape recipe yet.
- No erosion pass yet.
- No direct DEM file sampling at runtime.
- No further "just tweak the scalar ranges" pass.
