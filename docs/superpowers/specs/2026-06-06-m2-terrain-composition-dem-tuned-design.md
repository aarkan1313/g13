# M2 terrain shape — DEM-tuned composition machine + biome-as-skin (redesign)

**Date:** 2026-06-06
**Status:** partially superseded after M2.4a visual failure. M2.3's composition
machine remains accepted; the continuous DEM-character field is abandoned as the
M2.4 path. See `docs/superpowers/plans/2026-06-06-m2-4b-dem-structural-scaffold.md`.
**Type:** M2 terrain-shape architecture (the foundation for M2.3 → M2.end)
**Supersedes:** all prior M2-shape designs — the hand-tuned-noise spec, the
DEM-spectral spec, and the per-biome composition-recipe spec
(`2026-06-06-m2-terrain-composition-machine-design.md`). Those are abandoned;
this is the clean restart after rolling `main` back to M2.2 (`c83da21`).

## Why this redesign (the history that shaped it)

Terrain shape is the hard problem that killed attempts #1–12 and thrashed across
M2.3/M2.3b/M2.4 this project. The decisive lessons, paid for in ~12+ iterations:

1. **A global noise/octave-sum cannot make believable landforms.** Hand-tuned fBM
   ("Perlin oatmeal"), domain-warped ridged macro ("mesa cliffs"), and a
   DEM-amplitude-spectrum octave-sum (uniform terrain) all failed the same way: a
   global statistical texture is the SAME everywhere — nothing says "a range
   stands HERE with a valley THERE."
2. **Statistics describe TEXTURE, not STRUCTURE.** Distilling DEMs into a spectrum
   and matching it globally inherits failure #1. DEM stats are valuable as
   *character tuning*, never as the *source of structure*.
3. **Layered composition works.** The one approach that produced believable
   mountains (this session, before unrelated churn) was WG10's model: a
   low-frequency ENVELOPE places where relief stands up, ridged detail rides it,
   valleys carve between. Structure comes from composition; the envelope is the
   missing ingredient an octave-sum lacks.
4. **Terrain is a VISUAL problem — gate it with eyes EARLY.** Every failure passed
   a green test gate while looking bad. The test gate is a guardrail; the visual
   gate (low-altitude capture + walking the world) is the real judge.

The earlier "per-biome shape recipe" framing (each biome sculpts its own
landform: mountain=ranges, desert=dunes) is ALSO set aside as the *primary*
structure. It conflated two independent things and made scope unbounded (~12
recipes). The human's Factorio-informed reframing fixes this.

## The architecture: two independent axes

Terrain has **two axes that do not constrain each other**, combined in the one
GPU dispatch:

### Axis 1 — SHAPE: one DEM-tuned composition machine (geological)
A single elevation system produces the macro heightfield everywhere. It cares
about real-terrain STRUCTURE (from the DEMs), **not** about biomes. Its job is to
place believable landforms — large flat/rolling lowlands (most of the world),
hill country, and distinct mountain ranges with valleys between — and to vary
their *character* (relief, steepness, ridge-ness, scale) richly across the world,
informed by the DEM library.

### Axis 2 — BIOME: stats-based classifier (ecological), unchanged from M2.2
Biome is classified from **stats** (temperature, moisture, elevation) exactly as
M2.2 does. It is a **SKIN**: color now, textures/decorations/vegetation later. It
does **NOT** affect shape. The same terrain reads as snowy peak / forested slope /
barren rock depending on climate — like the real world and like Factorio (where
elevation is one field and the biome tile is a climate-driven lookup over it).

**Why this is right (pillars):** it untangles the two things the thrash tangled.
Shape becomes ONE well-tuned system (not N recipes); biomes become a pure
data-driven skin layer. Simpler long-term, more flexible, and it matches how AAA
/ real engines separate geology from ecology. "Biome cares about stats and its
textures; terrain cares about the DEMs" — clean separation of concerns.

### The clean interface (contract preserved, 00 §2.1)
- One dispatch fills the page: `[height, temp, moisture, biome_id]`.
- The composition machine writes `height`; the M2.2 classifier writes `biome_id`;
  climate writes `temp/moisture`. **Height never feeds biome/climate** (no
  circularity — biome uses macro-altitude, independent of composed height).
- Height channel stays **R32F** for collision (M1.7). No Rust contract change to
  the page layout.
- **Erosion (M6) consumes this macro heightfield later.** The composition machine
  outputs a clean macro shape; erosion is a separate transform applied on top. No
  wasted infra — we build what erosion needs, nothing erosion replaces.

## Axis 1 in detail: the composition machine

One shader (`wg-13/shaders/field_height.glsl`), shared world-space deterministic
primitives composed into the macro height. Current build approach: **layered
envelope composition (the accepted M2.3 result) + M2.4b structural-scaffold
facts**. The former continuous DEM character field is documented below only as
the abandoned M2.4a path.

### Primitives (the machine)
- `domain_warp(p, seed, amount, freq)` — bends coordinates for organic, non-grid
  landforms.
- `uplift_field(p, seed)` — a low-frequency, domain-warped field in [0,1]: the
  GEOLOGICAL "where does terrain stand up" signal (the envelope, generalized from
  a single mountain envelope to a world-wide ruggedness field). This is the
  STRUCTURE PLACER — the ingredient an octave-sum lacks. Most of the world is low
  (lowlands); uplift rises in bands/regions where ranges and hills stand.
- `ridged_fbm(p, seed, oct, lac, gain)` — sharp ridgelines (`1-|2n-1|`, crest
  rounded so ridges have body, not tent-poles — the fix proven this session).
- `value_fbm(p, seed, oct, lac, gain)` — smooth rolling undulation.
- `valley_carve(uplift, depth)` — presses inter-range basins down where uplift is
  low.

### Superseded: the continuous DEM CHARACTER field

This section describes the idea that failed in M2.4a. It is kept for historical
context only. The attempted implementation mapped DEM fingerprint scalars into
ridge/detail/relief parameters and passed numeric gates, but failed live visual
review twice with corduroy grooves / harsh parallel walls.

M2.4b now uses the WG10 mountain synthesis lesson instead: DEMs should inform
explicit structural facts (range/ridge/channel/pass/material hints) generated
procedurally per region, not per-cell scalar knob modulation.

`character(p)` returns the local terrain character — **relief amount, slope
ceiling, ridge-ness, feature scale** — by **continuously blending across the DEM
library's measured character**, driven by the uplift/region fields (and richly
sampled so ALL the DEM data is represented, not just a few archetype averages).
- High-uplift regions pull toward steep/ridged DEM character (mountain-like:
  slope_p95 ~0.89); low-uplift toward gentle DEM character (plains-like:
  slope_p95 ~0.18). The blend is CONTINUOUS — infinite smooth variety, no hard
  archetype switching, no uniform texture.
- This is TUNING layered on STRUCTURE: the composition provides where-relief-is;
  the character field provides how-that-relief-looks, grounded in real data.

### Composition (per cell)
```
warp     = domain_warp(world_xz)
uplift   = uplift_field(warp)                  # 0..1, where terrain stands up
facts    = region_facts(seed, region_id)       # M2.4b candidate: ranges/ridges/channels/passes
base     = continental_base(world_xz)          # gentle continental undulation
relief   = scaffolded_range_relief(warp, uplift, facts)
carve    = scaffolded_channel_pass_carve(warp, uplift, facts)
detail   = subordinate_residual_detail(world_xz, facts)
height   = base + relief - carve + detail
```
Exact shader/API shape belongs to the M2.4b plan. The important contract is that
facts place/cohere structure and residual detail stays subordinate; scalar
per-cell DEM knobs are not the current path.

## Axis 2 in detail: biome (unchanged)
The M2.2 nearest-centroid Whittaker classifier over (temp, moisture,
macro-altitude) stays exactly as built and gated. 10-biome data-driven roster.
Outputs `biome_id`; the display shader owns the debug color table. Future
textures/decorations key off `biome_id` (later milestones, not M2). **No change
in this redesign.**

## DEM data: the offline tool (restored + extended)
The offline `rust/dem_distill` tool + `wg-13/data/dem_fingerprints.json` are
RESTORED (solid, gated infra — 10/10 tests pass; reads 135 labeled DEM tiles →
per-archetype radial amplitude spectrum + slope_p95 + ridge character; offline
only, runtime never opens a .tif). The structural scaffold may use this data for
style targets/reference checks, but it must not regress to global scalar
stats-matching.

**Extension (for representation):** ensure the distilled output captures the
library's structural and character distribution well enough to validate/bias the
scaffold — including the non-curated examples. Exact form is an implementation
detail decided in the plan; the principle is GOOD REPRESENTATION ACROSS THE DEM
DATA without pretending that statistics alone create landforms.

How the runtime READS structural facts (Rust cache, GPU macro field, page-sampled
fact textures, or a hybrid) is M2.4b plan territory. The per-biome-row character
wiring from the abandoned approach is NOT assumed.

## Scope & gated build sequence (the anti-thrash plan)

**Bite order (decided): general terrain first, biomes' SHAPE distinctions later,
one at a time, only after the general world looks good.**

- **M2.3 — composition machine: STRUCTURE.** Build the primitives + uplift field +
  composition with hand-set character constants (no DEM tuning yet). GATE (test):
  determinism, continuity (no cliffs, bounded step), structure-not-uniform
  (within-region relief spread). GATE (visual, EARLY): capture low + WALK it —
  reads as believable varied terrain (lowlands + hills + ranges with valleys),
  not oatmeal, not uniform. **Make-or-break visual.**
- **M2.4 — DEM structural scaffold.** Build explicit procedural region facts
  from DEM-informed mountain synthesis: range masks, ridge/channel/pass facts,
  style weights, and material hints. Start with a Rust oracle + static review
  sheet, then integrate a region-fact cache/runtime candidate lane. GATE (test):
  deterministic facts, seam/apron correctness, connected pass/channel structure,
  and M2.1/M2.2/M2.3 regressions green. GATE (visual): side-by-side/reference
  review proves the scaffold reads like organized real terrain, not local noise.
- **M2.5 — general-terrain visual acceptance + polish.** Fly + walk the whole
  general world; confirm it's believable and free of artifacts at the macro bar.
  Address terrain-steepness consequences HERE if they appear (see Known issues).
- **M2.6 — performance pass (LAST, the M1.9 way).** Profile the real composed
  field vs the frame budget on the RTX 3070 target.
- **M2.x — milestone gate, tag `m2-complete`.**
- **LATER (separate, individually-gated, NOT in M2):** per-biome SHAPE modulation
  — a biome may *modulate* the general terrain (e.g. desert adds dune ripples,
  alpine amplifies ruggedness) as an additive layer on the shared machine, one
  biome at a time, each build→DEM-tune→visual-accept→commit. Scheduled only after
  the general terrain is proven. This is the "biomes one at a time" the human
  wants, kept small and deferred.
- **LATER (M6):** erosion carves real hydraulic realism into the macro shape (the
  AAA realism pass). The composition machine's output is its input.

## Known issues to DESIGN FOR (not bandaid later)
These surfaced when terrain first got steep this session. They are real and must
be handled as terrain gains relief — by root cause, in the right layer, gated;
NOT by patching the player controller (that was the mistake that triggered the
rollback).
- **Render-vs-collision surface gap on steep terrain.** The displaced render mesh
  samples the height texture (bilinear, UV at vertex positions) while the
  `HeightMapShape3D` uses the raw cell grid; on steep slopes these can diverge by
  metres (measured ~4–5 m at a steep origin). Investigate properly when M2.3/M2.4
  terrain is steep: confirm the exact cause (UV/texel alignment, filtering),
  fix in the render/collision layer, gate it (render surface == collision surface
  within tolerance). Do NOT clamp the player to hide it.
- **Collision residency vs fast movement.** Collision bodies build async for a
  small radius (collision_radius=1) around the camera; fast traverse can reach a
  rendered-but-not-yet-collidable page. If on-foot exploration of large terrain
  is a requirement, revisit collision radius / build pacing as a gated M1.7
  follow-up — not a player hack.
- **A fast on-foot traverse control** (the human's "explore far on foot" need)
  belongs in the player/demo layer as a clean feature with its own small gate,
  decided separately — not bolted onto this terrain work.

## What's reused vs new
- **Reused (unchanged):** M2.1 climate, M2.2 biome classifier + roster, the M1
  streaming/LOD/collision foundation, the offline `dem_distill` tool + fingerprint
  data (restored).
- **New:** the M2.3 composition machine (primitives + uplift structure) remains.
  The next new piece is a procedural structural scaffold / region-fact path, not
  the abandoned continuous DEM-character field.
- **Explicitly deferred:** per-biome shape modulation (later, one at a time);
  erosion (M6); the steepness-driven render/collision + traverse items (handled
  when steep, in their own layers, gated).

## Risks / watch-outs
- **Don't let the scaffold regress to global stats-matching.** Structure MUST
  come from organized facts + composition; DEM measurements inform targets and
  residual character. If the output looks uniform or grooved, the scaffold is
  wrong, not the visual reviewer.
- **Visual gate EARLY and often** (the burned-in lesson). Capture low + walk;
  don't trust a green test gate on a bad picture.
- **Don't over-build the machine.** Add a primitive only when the composition
  needs it. Start with warp, uplift, ridged, value, carve.
- **Scope discipline.** General terrain is the M2 bite. Per-biome shape is later,
  individually gated. Do not start biome-shape recipes inside M2.3/2.4.
- **Determinism/contract.** World-space sampling only; one dispatch; height R32F;
  biome from macro-altitude (no circularity).
```
