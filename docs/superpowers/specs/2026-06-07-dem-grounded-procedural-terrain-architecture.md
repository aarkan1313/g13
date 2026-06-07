# DEM-grounded procedural terrain architecture

**Date:** 2026-06-07
**Status:** explanation + prototype direction, not yet an approved runtime plan
**Context:** WG13 is an infinite GPU-first Godot/Rust/GLSL world generator. The
live runtime is back on the M2.3 composition-machine terrain baseline after M2.4
DEM attempts were rolled back.

## The framing

WG13 should use real DEMs as an offline teacher, not as raw runtime terrain.
The runtime contract remains:

- GLSL field is the source of truth for height.
- Runtime never loads raw `.tif` DEM files.
- The world remains infinite, deterministic, seamless, and GPU-conscious.
- Climate and biome id stay field-owned skins for now; terrain shape is not
  hardcoded per biome yet.

The M2.4 postmortem controls this design: the failed attempts did not fail
because DEM character was absent. DEM character reached the screen, but a cached
256 m/texel macro surface viewed from altitude still read as blocky/stair-step
terrain. Therefore the next architecture must decide which visible frequency
lives in which layer before asking where the character data comes from.

The recommended target is:

```text
height(p) =
  macro_uplift_scaffold(p)
+ ridge_profile_from_feature_graph(p)
- drainage_valley_carve_from_feature_graph(p)
+ dem_derived_residual_detail(p)
+ close_range_micro_detail(p)
```

Noise becomes residual/detail. DEMs train the scaffold statistics, feature
profiles, and residuals. They do not replace the structural scaffold.

## Offline DEM preprocessing

Raw DEMs should pass through a strict offline distillation pipeline before
anything reaches runtime.

### 1. Reproject to metric grids

Input tiles may arrive as EPSG:4326 degree grids. Before any slope, curvature,
or flow measurement, convert spacing to metres or reproject each tile to a local
metric projection such as UTM or a local equal-distance grid.

Store for each processed tile:

- horizontal cell spacing in metres,
- vertical unit and vertical scale,
- original bounds and source DEM type,
- valid/no-data mask,
- sea/water/flat masks,
- projection metadata,
- quality flags.

Do not compute slope or drainage on degree-space pixels as if they were square
metres. That corrupts latitude-dependent measurements.

### 2. No-data handling

No-data should be fixed differently by scale:

- Small holes: fill by local interpolation or constrained inpainting.
- Large holes: mask out of measurement windows and reject if they intersect the
  intended sample patch.
- Sea/water areas: preserve as explicit masks instead of forcing them into the
  land height distribution.
- Border artifacts: crop or apron-pad before feature extraction.

The output should carry both the repaired height and a confidence mask so later
steps can reject weak samples.

### 3. Detrending and normalization

DEM terrain has broad regional tilt/uplift plus local landform structure. The
offline tool should keep both, separately:

- physical height in metres,
- broad trend: plane / low-order polynomial / large-radius blur,
- detrended residual height,
- normalized residual by local relief,
- relief envelope at multiple physical radii.

Avoid one global z-score as the only product. It erases the physical cues needed
for slope, channel profiles, relief ceilings, and LOD scale choices.

### 4. Sea and flat masks

Flatness is not a single meaning. Separate:

- sea/ocean,
- lakes/wetlands,
- floodplains,
- true low-relief plains,
- plateaus,
- bad no-data flats,
- resolution-limited smooth areas.

Runtime may eventually use these masks as morphology priors, but first they are
needed so the offline metrics are honest.

### 5. Multi-scale sampling

Every useful feature must be measured at real physical scales, not only at
source pixel size. Suggested radii/bands:

- 16 m / 32 m / 64 m: close surface roughness and micro relief.
- 128 m / 256 m: visible walking and low-fly detail.
- 512 m / 1 km: ridge-valley spacing and local relief.
- 2 km / 4 km / 8 km+: basin, range, plateau, and lowland structure.

The runtime should then know which distilled signals are valid for which viewing
scale.

## Features to extract

Slope and roughness are necessary but not sufficient. They describe texture more
than structure. WG13 needs features that encode phase, topology, and drainage.

### Height distribution and relief

- hypsometric curve and hypsometric integral,
- elevation quantiles,
- skew and kurtosis of height,
- local relief distributions at multiple radii,
- topographic position index (TPI),
- relative elevation above local base level,
- plateau/flat/floodplain fraction.

### Derivatives and curvature

- slope distribution in physical units,
- aspect distribution,
- profile curvature,
- plan curvature,
- mean/Gaussian curvature approximations,
- convex ridge masks,
- concave valley masks,
- cliff/step candidates.

### Ridge and valley structure

- ridge skeletons,
- valley/channel skeletons,
- distance to ridge,
- distance to channel,
- ridge height above adjacent valleys,
- valley depth below adjacent ridges,
- ridge-valley spacing distribution,
- valley width/depth/asymmetry,
- junction angles,
- orientation anisotropy and orientation dispersion.

### Hydrology and basin hierarchy

- flow direction,
- flow accumulation,
- channel initiation threshold,
- drainage density,
- Strahler or similar stream order,
- basin/watershed hierarchy,
- basin area and length,
- branching ratio,
- slope-area relation,
- channel concavity,
- longitudinal channel profiles,
- stream-power proxy.

### Landform-specific signatures

These should be extracted as reference labels, not hardwired into biome shape
yet:

- glacial U-valleys, cirques, hanging valleys,
- volcanic cones, calderas, radial drainage,
- badlands high drainage density and sharp divides,
- karst depressions and tower/mogote forms,
- desert yardangs, dune-like residuals, broad pediments,
- wetlands/deltas with low HAND and dense low-relief channels,
- coastal cliffs, fjords, and terrace benches.

## Runtime generator

The runtime should evaluate compact, deterministic terrain math in GLSL. Rust may
load compact tables/kernels and bind them, but it must not become a second height
authority.

### 1. Explicit macro scaffold

The macro scaffold answers "where does terrain stand up?"

It should produce:

- continental lowlands and highlands,
- range/plateau/hill regions,
- relief envelope,
- broad base elevation,
- morphology blend weights,
- coarse orientation bias.

This can be built from deterministic warped low-frequency fields and/or bounded
hashed macro-cell feature placement. It must be continuous across pages.

Important: the scaffold is not a 256 m baked texture that carries all visible
shape. It is an analytic or sufficiently high-resolution signal that survives
the actual view scale.

### 2. Ridge, valley, and drainage structure

The runtime needs a bounded local feature-query model:

1. Hash nearby macro cells from world position and seed.
2. Generate a small set of deterministic ridge and channel segments/splines.
3. Query distance, order, orientation, and side of feature.
4. Evaluate DEM-fit profiles for ridges and valleys.
5. Blend across cell boundaries by querying neighbor cells with aprons.

This gives topology without a global simulation. Nearby cells define enough
context for seams to agree while preserving infinite evaluation.

A point should be able to derive signals like:

- distance to nearest channel,
- distance to nearest ridge,
- channel order proxy,
- basin position proxy,
- ridge/valley orientation,
- local relief envelope,
- flow direction proxy.

### 3. DEM-derived residual/detail

After the macro scaffold and feature graph place landforms, DEM residuals add
real character:

- slope-aligned roughness,
- ridge breakup,
- channel-side incision texture,
- talus/fan hints,
- terrace and bench hints,
- small gullies,
- plateau edge erosion detail.

Residuals should be residuals: detrended and normalized offline, then restored
under the runtime relief envelope. They should not independently place whole
mountain ranges or basins.

### 4. Compact runtime data

Good runtime products include:

- small lookup tables for ridge and valley cross-section profiles,
- splines for channel longitudinal profiles,
- histograms/quantiles for slope, relief, drainage density, and spacing,
- small residual kernel atlases,
- PCA/latent vectors for residual families,
- blue-noise/archetype tables for non-repeating selection,
- thresholds and coefficients for morphology blends.

Bad runtime products include:

- raw DEM `.tif` files,
- huge patch atlases,
- per-world baked terrain databases,
- CPU-only terrain logic that diverges from the GLSL field.

### 5. Deterministic sampling

All choices must derive from stable keys:

```text
world_seed
macro_cell_id
feature_id
morphology_family
world_position
```

The same seed and world position must always produce the same height, normal,
feature ids, and biome id. Page boundaries must not affect the answer.

## Direct DEM patch assembly

Direct DEM patch assembly is viable as a prototype and possibly as a residual
layer. It is less robust as the primary infinite-world terrain architecture.

### What could work

Offline:

- curate a small patch atlas from real DEMs,
- detrend patches into residuals,
- tag each patch with relief, drainage density, orientation, slope distribution,
  edge signatures, and masks,
- compress to fixed-size runtime-safe assets.

Runtime:

- select patches deterministically from macro context,
- rotate/scale/warp within allowed metadata bounds,
- restore relief under the scaffold envelope,
- blend with wide aprons,
- avoid immediate repeats by hashed neighborhood selection.

### What is hard

Patch seams are not just height seams. They are structure seams:

- channels must enter/exit coherently,
- ridges must continue or terminate plausibly,
- valley floors must not climb into divides,
- flow direction must not contradict surrounding terrain,
- repeated distinctive shapes become obvious,
- edge blending can blur hydrology into mush.

A patch atlas can make local detail look real, but arbitrary patch adjacency is a
poor substitute for a generated drainage/ridge graph.

### Recommendation

Use direct DEM patches in this order:

1. Reference oracle for visual comparison.
2. Detrended residual/detail atlas.
3. Local meso-detail under an existing scaffold.
4. Only later, if proven, direct patch assembly for larger landform chunks.

Do not start by building a giant real-DEM tiler. It fights the infinite contract
and does not solve ridge/drainage continuity by itself.

## LOD and viewing scale

The terrain must be designed by visible frequency band.

### Required layer split

- 4 km+ band: broad uplift, continents, mountain belts, lowlands.
- 500 m to 4 km band: basins, ridges, major valleys, plateau edges.
- 64 m to 500 m band: walking/flying detail, gullies, secondary ridges,
  residual DEM character.
- under 64 m band: close micro detail, normals/materials, later erosion/material
  support.

### Rule from M2.4

Never expect a low-resolution baked macro texture to carry high-altitude realism.
If the player can see the band, the runtime must either:

- evaluate it analytically,
- sample it at sufficient resolution for that view,
- or add a separate detail layer above the coarse cache.

The old failure was not "the wrong DEM." It was asking a 256 m/texel cached layer
to be the visible terrain surface from altitude.

### Practical LOD strategy

- Keep macro scaffold analytic or high enough resolution to avoid blockiness.
- Make residual/detail amplitude fade by screen/world scale, not by page accident.
- Use derivative-aware normals from the same field source.
- Validate at walk, low fly, and high fly heights.
- Include debug views for layer bands and cached-vs-analytic contribution.

## Proof gates

### Visual gates

- Human walk gate: terrain reads believable at low speed and eye height.
- Low fly gate: landforms remain continuous and not noisy.
- High fly gate: no blocky macro texels, stair steps, corduroy bands, or repeated
  stamps.
- Seam gate: page edges invisible in height, normal, material, and debug views.
- Comparison gate: side-by-side against held-out DEM references and current M2.3.

### Numeric gates

- Determinism: same seed/world position returns identical height/normal/id values.
- Boundary continuity: neighboring pages agree on shared-edge height and normal.
- Slope distribution matches held-out DEM references within accepted tolerances.
- Local relief distribution matches references by terrain family.
- Drainage density and ridge-valley spacing match references by family.
- Hypsometric curves are plausible for selected terrain families.
- Patch/residual repetition detector stays below a correlation threshold.
- Streaming production time, worst frame, and VRAM remain within budget.

## Staged WG13 plan

### Stage A: offline measurement spike

Use a small reference set first:

- mountain,
- grassland/temperate,
- optionally badlands as a high-drainage stress case.

Extract:

- hypsometry,
- local relief,
- slope/curvature,
- ridge/valley skeletons,
- drainage density,
- ridge-valley spacing,
- valley/ridge cross-section profiles,
- residual patches after detrending.

Output compact JSON/bin tables and a report. Do not wire runtime yet.

### Stage B: standalone visual prototype

Build a small offline/browser/Godot review prototype that renders:

- macro scaffold only,
- scaffold plus ridge/valley graph,
- residual detail only,
- combined terrain,
- intentionally coarse 256 m cache simulation as the failure comparison.

This proves the concept visually before touching the live field.

### Stage C: GLSL candidate lane

Port the smallest accepted math into `field_height.glsl` behind a candidate mode
or branch:

- same field source of truth,
- compact tables only,
- no raw DEM load,
- deterministic by seed and position,
- current M2.3 remains the fallback.

Gate with captures, page-edge probes, determinism tests, and performance probes.

### Stage D: tune scale before adding content

Before adding more DEM families, tune:

- macro band scale,
- ridge-valley spacing,
- altitude readability,
- residual amplitude by LOD,
- seam behavior,
- production time.

Only after this should more terrain families or biome-biased morphology be added.

## What not to build yet

- A giant runtime DEM tiler.
- Full global hydrology.
- Per-biome terrain recipes.
- A runtime neural model.
- Runtime hydraulic erosion.
- Raw `.tif` loading.
- A large patch atlas before seam/repetition gates exist.
- Any second CPU terrain path that can drift from GLSL.

## Failure modes to watch

- Local roughness matches DEMs but terrain still lacks ridge/drainage topology.
- Direct patches look good alone but fail at boundaries.
- A cache reintroduces blockiness at altitude.
- Residual detail fights LOD and becomes shimmer/corduroy.
- Drainage graph seams appear at macro-cell boundaries.
- Repetition detector catches distinctive DEM stamps.
- Numeric gates pass while the human visual gate fails.

## Companion demo

The Godot 3D review scene lives at:

`wg-13/scenes/dem_grounded_terrain_review.tscn`

It is a copy-shaped review scene with the normal fly/walk controls. It renders a
side-by-side 3D comparison: a 256 m cached macro surface versus a continuous
scaffold + drainage + residual candidate. It is intentionally not runtime
streaming code.

The earlier browser layer prototype lives at:

`docs/superpowers/prototypes/dem-grounded-terrain-demo.html`

It demonstrates the architecture's layer split and the previous 256 m
macro-cache failure mode in a browser canvas.
