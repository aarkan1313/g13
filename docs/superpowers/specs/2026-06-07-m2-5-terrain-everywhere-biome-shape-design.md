# M2.5 — Terrain everywhere + biomes-are-terrain — design

**Date:** 2026-06-07
**Branch:** dem-grounded
**Status:** design, macro feel approved via live captures; implement gated.

## The problem (proven from pixels, not theory)

Vista captures of the current M2.3 terrain showed the real defect behind "view
isn't far enough / not Skyrim": the world is **~95% flat lowland with rare isolated
mountain ranges** (M2.3's uplift window is deliberately wide -> mostly lowland). So
from any vantage you see one local range then empty flat horizon. This is NOT a
reach/fog/streaming problem — captures at 49km vs 779km reach were pixel-identical.
It is **terrain composition**: there is nothing distant to see because distant
landforms barely exist.

Two separate axes were identified (keep them separate — conflating them is how the
4 failed M2.4 attempts died):
1. **Macro structure** — how often/how tall landforms are (why it's mostly flat).
   THIS spec. Confirmed by live A/B captures.
2. **Detail/character quality** — whether close-up terrain reads as real rock vs
   smooth blobs (the M2.4 hard problem: macro-resolution x LOD x viewing scale).
   Explicitly DEFERRED — see Non-goals.

The user's framing: "biomes have to drive shape, but moisture/temp/elevation drive
biomes — it's circular." Resolved below.

## Breaking the circular dependency (the key architecture)

elevation -> biome (classifier) and biome -> shape -> elevation is a cycle. Break
it with a one-directional LAYERED pipeline, exploiting that M2.2 already classifies
from a SEPARATE continental `macro_altitude`, not the render height:

1. **macro_elevation** — low-freq continental landform (the uplift composition).
   Depends only on position. This is the BIG height (ranges/valleys/lowland).
2. **climate** — temp/moisture from latitude + macro_elevation + position.
3. **biome** — classified from (macro_altitude, temp, moisture). M2.2, unchanged.
4. **biome detail relief** — each biome adds its OWN landform CHARACTER on top of
   the macro (dunes/ridges/rolling/hummocks), amplitude+style per biome.

The cycle is broken because **biome reads the smooth MACRO base (step 1/3) but only
shapes the DETAIL layer (step 4).** Macro-elevation and detail-relief are different
layers. "Mountain biome" doesn't create height — it's placed where macro is already
high, and adds rocky ridged detail there. Desert is placed where dry+low, adds
dunes. No feedback.

## This milestone is in TWO gated sub-steps

Per "foundation first": land the MACRO everywhere-relief first (the big visual win,
low risk), THEN the per-biome character layer (each biome recipe = its own visual
gate). They are independent and individually revertable.

### M2.5a — Macro relief everywhere (APPROVED FEEL via captures)

Retune the existing `composition_height` uplift so landforms are everywhere with
valleys flowing up into ranges and generous-but-not-dominant lowland (the user
picked "between P1.3 and P1.6" from live vista captures). Concrete starting knobs
(tunable during build; the FEEL is what's locked):
- `UPLIFT_FREQ` 0.000025 -> ~0.000075 (range regions ~13 km, was ~40 km)
- `UPLIFT_LO` 0.45 -> ~0.25, `UPLIFT_HI` 0.70 -> ~0.59 (much more land stands up;
  narrower flat gap)
- `RELIEF_AMP` 1600 -> ~1975 (taller peaks)
- `BASE_AMP` 180 -> ~300 (more rolling everywhere, even in lowland)

Pure constant retune in `field_height.glsl` `composition_height` — no new channels,
no Rust change, no contract change. Heights stay analytic + continuous (the M2.4
seam fix's analytic normal still derives correctly).

Acceptance:
- Gate `m2_3_composition_check` still PASS (determinism; structure-not-uniform
  spread; no-cliff max-step within tolerance — NOTE: taller/steeper terrain may
  raise the max-step; if it trips, the gate's cliff threshold is re-evaluated as a
  deliberate decision, not silently loosened).
- Climate/biome gates still PASS (height is still additive into climate's alt term;
  re-confirm the alt_cool normalization still spans the new height range — may need
  the `climate` alt_norm window widened so high ground still reads cold).
- Collision (m1_7a/c) PASS — steeper terrain must still be stood on; if walkability
  breaks it's M2.7 character work, logged, NOT a terrain rollback.
- HUMAN vista + walk: landforms everywhere, believable, "something always on the
  horizon." The real gate.

### M2.5b — Biomes are terrain (per-biome detail character)

On top of the M2.5a macro, add a per-biome DETAIL relief blended by biome weight so
each region reads as its own landform. Design choices to settle at M2.5b brainstorm
time (NOT now — needs its own captures):
- A small set of detail "recipes" (functions of world_xz): e.g. dune (directional
  smooth waves), ridged (rocky), rolling (gentle fbm), hummock (low bumps), flat.
- Blend by biome membership WEIGHT (soft, not hard id) so borders don't crack —
  reuse the classifier's distances as weights, or a smooth biome-weight field.
- Amplitude per biome scales the detail; macro still carries the big height.
- Keep it analytic/continuous so the M2.4 analytic normal stays seam-free.
- Watch the M2.4 LESSON: detail must read smooth at the LOD/altitude actually
  viewed — favor a high-freq detail layer over macro-grid character; gate at the
  real viewing scale, not just up close.

Acceptance: per-biome vista + walk captures show distinct landforms (desert reads
as dunes, mountains as rock, plains as rolling) with smooth borders; all gates green.

## Non-goals (explicit, to avoid the M2.4 trap)

- NOT chasing DEM-grounded character or "where does character come from" — that's
  the proven trap (M2_4_POSTMORTEM). Character here is procedural per-biome recipes.
- NOT erosion/hydrology (M6).
- NOT textures/materials (M3) — still flat-color skin.
- NOT fixing close-up "rock realism" beyond believable procedural detail; AAA rock
  detail is M3/M6 territory.

## Risk notes

- Taller/steeper terrain stresses: (a) the no-cliff gate threshold, (b) climate
  alt-cooling window, (c) walkability/collision feel. Each is a KNOWN checkpoint
  above, handled deliberately (re-tune the dependent param or log as M2.7), never a
  silent loosen or a terrain rollback.
- AABB_HALF_HEIGHT (4000/6000) must still exceed peak height (~2km here — fine).
- Determinism unchanged (constant retune; world math still pure function of pos+seed).

## Build sequence (gated)

1. M2.5a: retune uplift knobs in composition_height. Re-run m2_3 + m2_1 + m2_2 +
   m1_7a/c gates; fix any dependent param (cliff threshold / climate window) as a
   stated decision. Human vista+walk gate. Commit at green.
2. M2.5b: brainstorm the per-biome detail recipes (own captures), then implement
   blended detail, gated per the acceptance above. Commit at green.
