# M2.5c — Two-Tier Diversity & Scale (regional families × meso features)

**Status:** design approved (brainstorm 2026-06-07), spec under review
**Branch:** dem-grounded
**Supersedes for terrain shape:** extends the M2.5b regional-archetype BASELINE
(`docs/superpowers/plans/2026-06-07-m2-5b-regional-archetype-terrain.md`). M2.5b is
accepted as a proven *architecture*; this is the *diversity + scale* pass the M2.5b
verdict called for ("far greater diversity, better scale — its own brainstorm").

---

## 1. Problem & goal

The M2.5b world picks one of 6 hardcoded archetypes from a single continental-scale
field and soft-blends them. Human verdict: architecture good, look is a first pass —
**not diverse enough**, and **scale feels off** (you can travel a long way with the
land never resolving into anything new; "1000s of km of no changes aren't fun").

Goal: a world that reads as a **layered journey** — big coherent macro regions, with
**distinct sub-regions nested inside them**, so something is always resolving as you
travel, and genuine contrast (a green basin in the desert) appears where wanted. All
**tunable** without a rebuild, and **engine-clean**: a future game gets new terrain by
editing *data rows + assets*, never core GLSL (`02_WORKFLOW §9`).

### Decisions locked in the brainstorm (human-approved)
- **Layered diversity (C):** two scales of variation at once — big macro regions with
  smaller distinct sub-regions inside.
- **Deviation is a knob (C):** per-region "how much can a sub-region deviate from its
  parent" — 0 = flavor of the parent (coherent), 1 = genuine intrusions (contrast).
  Default sits toward the diverse end; pull specific regions back for vast signatures.
- **Two-tier roster (B):** a small set of macro **families** × a library of meso
  **features**. Diversity *multiplies* (families × features) instead of *adding*.
- **Data-driven recipes (A / pillars):** core ships a fixed GPU **primitive
  vocabulary**; families and features are **data rows** that select + weight
  primitives. New game = new rows + assets. New *primitive* = rare gated core change.
- **Shape and color deviate together:** when a feature intrudes, it pulls its own
  color skin (the wet basin *looks* wet) — diversity reads at a glance (the user
  judges by SHAPE + COLOR; color alone is unreliable for them — deuteranopia).

### Non-goals (YAGNI / deferred, hooks left)
- Full feature catalog — only the meso layer + 5 families + the *first* 1–2 features
  ship here; more features are later one-gate-each steps.
- Water (M5) — but basins/wetlands are explicitly where water will settle later.
- Erosion (M6) — but the macro relief produced here is what M6 will carve.
- Coastal/shore family — reserved as a slot, activated with M5.
- A fully data-driven recipe *language* (interpreter in GLSL) — rejected on pillars;
  parameters-over-fixed-vocabulary is the modular boundary.

---

## 2. Architecture — three frequency tiers

`composition_height(world_xz, seed)` (and its color twin `dominant_biome`) evaluate
three tiers per cell, all **pure world functions of `(world_xz, seed)`** (preserves the
seam-free invariant and the no-circular-dependency rule — the meso/feature tiers read
**macro climate**, never detailed height):

1. **Macro (continental, ~tens of km).** `macro_altitude` + `macro_climate` select the
   **family** as a weighted blend (as M2.5b does today). Sets the parent identity of a
   huge area.
2. **Meso (sub-region, ~single-digit km).** A NEW middle-frequency field. Two jobs:
   - **(always-on) family modulation** — varies the parent family's own shape sub-region
     to sub-region (a mountain region gets tall sub-ranges and lower saddles; plains get
     swells and flats). This is the missing middle that fixes "scale feels off".
   - **(deviation-gated) feature stamping** — where the meso deviation noise exceeds the
     family's deviation threshold, a **feature** is stamped (canyon, lake-basin, dune-
     field…), pulling its own shape *and* color.
3. **Detail (per-cell fbm/ridged, sub-km).** The existing fine surface texture, on top.

Families and features are **data tables** pushed from Rust as storage buffers (mirroring
the existing `BiomeTable` mechanism in `field_height.glsl`), over a **fixed GLSL
primitive vocabulary**.

---

## 3. Data schemas (the engine boundary)

Two new tables + a shared primitive vocabulary. This is the `§9` seam: **new game = new
rows + assets; new primitive = rare gated core change.**

### FamilyTable — one row per macro family (default data = the 5)
| field | meaning |
|---|---|
| `climate_centroid` (alt, temp, moist) | where this family lives in macro-climate space; selection = weighted band/distance (as today) |
| `base_offset`, `base_amp` | elevation seat + vertical scale |
| `prim_id`, `prim_freq`, `prim_amp`, `prim_gain`, `prim_warp` | the recipe-as-numbers: which primitive + how it's shaped |
| `meso_strength` | how strongly the meso layer modulates this family's shape |
| `deviation` | 0 → coherent, 1 → readily admits intruding features |
| `color_id` | biome-color index when this family dominates |

Default families (active now): **Lowland, Upland, Mountain, Wetland, Arid.**
Reserved (activated with M5): **Coastal/shore.**

### FeatureTable — one row per meso feature (default = the first 1–2; grows later)
| field | meaning |
|---|---|
| `prim_id` + shape params | the feature's own shape recipe |
| `climate_affinity` | which families/climates it prefers to intrude into (lake-basin → wet+low; dunes → arid) |
| `rarity` | how often it stamps where deviation permits |
| `blend_radius` | how softly it merges into the parent (smooth weight, never a hard cut) |
| `color_id` | the feature's own color skin (shape + color deviate together) |

First features to ship (2d): **lake-basin** (wet+low affinity) and **canyon** (arid/upland
affinity) — chosen to demonstrate both a contrast-intrusion and a parent-flavor feature.

### Primitive vocabulary (core GLSL — the only thing a new game can't add without a gated core change)
- Exist today: `value_fbm`, `ridged_fbm`, `domain_warp`.
- Added gated, one at a time, when a family/feature first needs them: `terrace`,
  `dune`, `carve`, `plateau`.
- `prim_id` indexes a `switch` over these.

**Incremental schema note:** the tables above are the *target*. 2b ports today's 6
recipes into `FamilyTable` form first (proving the schema with known-good data);
`FeatureTable` arrives at 2d. Early steps may carry fewer columns and grow them as
features demand. Any column that turns out unused gets flagged, not shipped as dead data.

---

## 4. Data flow — meso layer & deviation mechanics

Per cell, in world space:

1. **Meso field.** Sample a mid-frequency noise (`meso_freq`, ~1/several-km) → a smooth
   sub-region coordinate. Two decorrelated channels: `meso_mod` (parent-shape nudge) and
   `meso_dev` (deviation noise, separate hashed seed).
2. **Family modulation (always-on — 2a).** The selected family's shape is scaled/varied by
   `meso_mod × family.meso_strength`. Even with zero features, travel always resolves new
   sub-regions.
3. **Deviation → feature stamp (2d).** Where `meso_dev > (1 − family.deviation ×
   world_diversity)`, the cell is a feature candidate. Score each feature by
   `climate_affinity(macro climate) × rarity` and take the **max-weight** feature (the
   same dominant-pick pattern `dominant_biome` already uses, so ties resolve
   deterministically and there's no overlap ambiguity). Its shape blends into the parent
   over `blend_radius` (smooth weight); its `color_id` overrides the family color there.
4. **Combine.**
   `height = family_base + family_shape × (1 + meso_mod) + feature_contribution + detail_fbm`.
   `color = feature.color_id if a feature is active here, else family.color_id`.
5. **Live tuning knobs (all data, no rebuild):** `world_diversity` (global one-number
   diversity dial — the "sameness isn't fun" knob), per-family `deviation` &
   `meso_strength`, per-feature `rarity`/`blend_radius`, and `meso_freq` (region size /
   scale).

**Top risk (named):** feature stamping must stay a *smooth* world function or it
reintroduces seams/popping at boundaries. **Mitigation:** features blend via smooth
weights (like today's `band()`), never hard `if` cutoffs — the same discipline that made
the M2.5b archetype blend seam-free. The `m1_4` seam gate guards every step.

---

## 5. Invariants (the guardrails — already-built gates)

Every step must preserve all of these; they are the "error handling" for terrain:
- **Seam-free (`m1_4`):** pure world function of `(world_xz, seed)`; smooth blends only,
  no hard `if` cutoffs in shape/feature stamping. Adjacent pages agree by construction.
- **No circular dependency:** meso + features read **macro climate**, never detailed
  height (same rule that keeps biomes contiguous).
- **Height/collision contract (`m1_7a/c`):** field-output channels 0–3 stay byte-
  identical in layout; collision reads height-only. New machinery changes the *value* of
  height, never the buffer contract.
- **Determinism (`m2_3`):** all new seeds derived by hashing the master seed; same input
  → same world, every session/GPU.
- **Perf budget (`m2_6_burst`):** the named top risk — more primitives + feature evals =
  more GPU math per cell, evaluated **5× per cell** (center + 4 neighbors) for the analytic
  normal (M2.4). Every step re-runs the burst gate; a step that blows budget *fails* and is
  optimized before proceeding. Pre-identified levers (M2.4 drift entry): analytic
  derivative in the recipe instead of re-evaluating neighbors, shared octave work across
  taps, or dropping detail octaves from the normal taps only — do NOT re-discover these.
- **Degenerate-data guard:** empty/zero tables fall back to a single default family
  (never NaN, never black) — mirrors today's `biome_count == 0` guard.

---

## 6. The gated ladder (build order & gates)

Two-track gates (`02_WORKFLOW §2`): test-gates self-certify from stdout; visual-gates
park for the human. Every rung leaves a **better, green** world. Meso-first (pillar call):
highest-value, lowest-risk change on the proven roster ships before any restructuring.

| Step | Ships | Gate |
|---|---|---|
| **2a** | Meso layer modulates the existing 6 archetypes (the missing middle). **+ N key = jump straight to biome view.** | **Test:** new `m2_5c_meso_check` (determinism, relief spread ↑ vs M2.5b, smoothness/no-cliff) + `m1_4`/`m2_3`/`m2_6_burst` green. **Visual (human):** flying one region, sub-regions resolve — "scale feels off" gone |
| **2b** | Refactor 6 hardcoded recipes → `FamilyTable` data rows, **no visual change** | **Test:** output bit-identical to 2a (golden compare) + all gates green. Pure structural |
| **2c** | Remap 6 → clean 5 families | **Visual (human):** 5 coherent parent identities read by shape + color |
| **2d** | `FeatureTable` + deviation knob; first 1–2 features (lake-basin, canyon) | **Test:** seam/perf green, features deterministic. **Visual (human):** nested intrusions appear & read |
| **2e…** | Grow features one at a time + tune scale | One visual gate each |

Per step: explain → implement → verify with evidence → record
(`PROGRESS`/`DRIFT_LOG`/`04_CODE_MAP`) → commit at green → continue. New per-step
micro-gates (the `m2_5c_meso_check` for 2a, the golden-image compare for 2b) are written
*as part of* the step. A failed visual gate → `git reset` to the prior green rung (lose
one step, never the world).

### Two folded-in asks (from the brainstorm)
- **N-key → biome view (2a).** Today the only view cycle is **V**
  (`normal → temperature → moisture → biome`, `dem_grounded_world_view.gd:243`); biome is
  the 4th press. Since shape↔color agreement is the thing constantly checked during this
  work, add a dedicated **N** key that jumps straight to biome view. GDScript-only, ~3-line
  input branch, no gate risk.
- **Per-step isolated profiling.** The codebase already times GPU page production in Rust
  (`produce_us_this_frame()`, surfaced on the perf HUD `perf_hud.gd:131` and the SPIKE
  log). The aggregate burst gate (`m2_6_burst`) stays the budget authority. ADD a targeted
  micro-timer (GDScript `Time.get_ticks_usec()` around just the new diversity math, or its
  Rust `produce_us` equivalent) inside `m2_5c_meso_check` so **each ladder step reports its
  own added cost in isolation** — catching a regression at the step that caused it, not
  only in the aggregate.

---

## 7. Modularity check (the §9 seam test)

Could this generator drop into a *different* game by changing only config + assets?
**Yes:** families and features are data rows; their colors/affinities/recipes are numbers;
a new game's biomes are new rows + new texture assets (M3). Core ships only the reusable
primitive *verbs* of terrain. The single core-coupling is "a genuinely new shape math no
primitive can express" — which is correctly a rare, deliberate, gated engine change, not a
runtime feature. Pillars satisfied: Quality (fixed, testable primitives vs a slop-prone
GLSL interpreter), Survivability (incremental, gateable rung-by-rung), Modularity (data
rows, not code paths).
