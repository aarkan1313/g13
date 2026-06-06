# WG10 Mountain Deep Dive For WG13

Date: 2026-06-06
Scope: WG10 mountain/runtime work from the first visual proof through chunk/network/world-layer integration. This is a learning artifact for a fresh WG13 overhaul, not a direct-port checklist.

## Archive Status

Heavy data was moved into this archive:

- `D:\workflows\worldgen9\dems` moved to `D:\world gen 13\archive\from_workflows_worldgen9\dems`.
- `D:\workflows\worldgen10\wg-10\worldgen_terrain\generated` moved to `D:\world gen 13\archive\from_workflows_worldgen10_wg10\worldgen_terrain\generated`.
- `D:\workflows\worldgen10\wg-10\worldgen_terrain\packs` moved to `D:\world gen 13\archive\from_workflows_worldgen10_wg10\worldgen_terrain\packs`.
- `D:\workflows\worldgen10\wg-10\worldgen_terrain\fixtures` moved to `D:\world gen 13\archive\from_workflows_worldgen10_wg10\worldgen_terrain\fixtures`.
- WG10 temp/check/review dirs under `D:\tmp\wg10*` moved to `D:\world gen 13\archive\from_D_tmp\...`.

Move manifest: `D:\world gen 13\_manifest\move_manifest_completed.csv` and `.json`.
Moved total: 97.26 GB across 38 directories.

Git note: because the WG10 generated/pack/fixture directories were actually moved, `D:\workflows\worldgen10` now reports those files as deleted. That is expected from the archive operation, not a code cleanup.

## Executive Read

The gold mine is not one file. It is the progression discipline:

1. Prove one windowed GPU height page and one screenshot.
2. Put that page producer behind a bounded page pool, streamer, clipmap rings, and read-only terrain view.
3. Fly the same renderer forever before trusting new worldgen content.
4. Review rough/static generated worlds before runtime integration.
5. Add chunks and seams as explicit review modes.
6. Add pass-network carving as a baked world-layer fact, not as a paint overlay.
7. Keep accepted reference, live candidate, world diagnostic, and legacy regression as separate runtime modes.
8. Promote only through visual review plus manifest/snapshot evidence.

WG13 should copy that structure and discipline. It should not blindly copy every WG10 terrain feature.

## Acceptance Ladder In WG10

### 1. First GPU page proof

Key files:

- `worldgen_terrain/m3/m3_slice1.gd`
- `worldgen_terrain/tests/m3_slice1_check.gd`
- `worldgen_terrain/tests/m3_slice1.png`
- `worldgen_terrain/shaders/height_page.glsl`
- `worldgen_terrain/shaders/ring_displace.gdshader`

What happened:

- Windowed-only RenderingDevice gate.
- Instantiate `Wg10PagePool`.
- Configure legacy DEM pack + `height_page.glsl`.
- Acquire exactly one page at `(level=0, origin=0,0)`.
- Put it on a subdivided `PlaneMesh` through `ring_displace.gdshader`.
- Set a camera/environment/light and capture a PNG.

WG13 lesson:

- First visual proof should be tiny and real: one GPU-produced page, one mesh, one capture.
- No full runtime, no biome framework, no giant plan before visible output.

### 2. Flyable M3 runtime shell

Key files:

- `worldgen_terrain/harness/m3_review.gd`
- `rust/src/page_pool/*`
- `rust/src/streamer.rs`
- `rust/src/schedule_policy.rs`
- `rust/src/page_policy.rs`
- `rust/src/clipmap_rings.rs`
- `rust/src/terrain_view.rs`

What worked:

- GDScript is only assembly: pool, streamer, rings, view, camera, profiler, overlay.
- Rust owns page policy, streamer, ring geometry, residency, and terrain view.
- `Wg10TerrainView.update` calls `streamer.update`, then binds resident pages only.
- The view uses `get_resident_page`; it does not trigger compute in the render binding path.
- Full 3x3 rings are drawn at every level. Coarser levels remain under finer levels as a never-black blanket.
- Missing fine pages hide, letting the coarse blanket show through.
- Missing coarsest pages hold last-good and pin displayed pages to avoid recycled textures.
- Display pins are cleared and rebuilt every frame so visible pages cannot be evicted/reused underneath the mesh.

Important constants from M3/mountain runtime:

- `NUM_LEVELS = 5`
- `BASE_SPAN = 8192.0`
- radius 1, so 3x3 pages per level
- velocity lead around 0.5 seconds, clamped by schedule policy
- max new pages per frame is bounded; mountain owner review used `MAX_PER_FRAME = 1`
- camera far/fog is matched to loaded/accepted visual extent so the edge is not visible

WG13 lesson:

- Build the infinite shell as its own milestone before complex mountains.
- Keep page acquisition bounded and observable.
- Treat no-black coverage as structural design: coarse blanket, pins, hold-last-good, read-only view.

### 3. Rough/highland static review before runtime complexity

Key files:

- `worldgen_terrain/harness/rough_world_review.gd`
- `worldgen_terrain/harness/rough_world_chunks_review.gd`
- `worldgen_terrain/harness/rough_world_review.tscn`
- `worldgen_terrain/harness/rough_world_chunks_review.tscn`
- `worldgen_terrain/harness/rough_world_infinite_review.tscn`
- `worldgen_terrain/tests/rough_world_*_check.gd`
- `tools/dem_pack/export_godot_rough_world_chunks.py` from the parent WG10 tooling area

What happened:

- Static JSON payloads were loaded into Godot meshes.
- Review controls exposed scale, relief, slope overlay, corridor overlay, seam guides, and lighting modes.
- Chunk review used explicit `chunk_x/chunk_z`, `display_origin_*`, apron heights, and seam guide lines.
- This stage was not a final runtime, but it created visual language and acceptance evidence.

WG13 lesson:

- Static review modes are useful when they are not mistaken for runtime acceptance.
- If a layer is visually hard to judge, give it an overlay mode and a seam-specific review mode.

### 4. Mountain/corridor/network chunk review

Key files:

- `worldgen_terrain/harness/mountain_corridor_review.tscn`
- `worldgen_terrain/harness/mountain_network_review.tscn`
- `worldgen_terrain/harness/mountain_network_chunks_review.tscn`
- `worldgen_terrain/harness/mountain_world_chunks_review.gd`
- `worldgen_terrain/harness/mountain_world_chunks_review.tscn`
- `worldgen_terrain/tests/mountain_network_visual_capture.gd`
- `worldgen_terrain/tests/mountain_network_chunks_review_check.gd`
- `worldgen_terrain/tests/mountain_world_chunks_review_check.gd`

What happened:

- The 9x9 chunk review became a walk/fly visual target for mountain network continuity.
- It used `apron_height` for normals/slope at chunk borders.
- It exposed terrain, slope, and corridor overlays.
- It had seam guides and seam focus controls.
- It added optional chunk collision and a player-eye review mode.

WG13 lesson:

- Chunk continuity needs its own visual mode. Do not rely on normal fly view to expose seam problems.
- Player-eye review is valuable because aerial screenshots hide scale/readability mistakes.

### 5. Mountain live fly taxonomy

Key files:

- `worldgen_terrain/harness/mountain_fly_review.gd`
- `worldgen_terrain/harness/mountain_fly_producers.gd`
- `worldgen_terrain/harness/mountain_fly_runtime_config.gd`
- `worldgen_terrain/harness/mountain_fly_snapshot.gd`
- `worldgen_terrain/tests/mountain_fly_*_check.gd`

Producer modes:

- `REFERENCE`: accepted static mountain-network baseline. Starts here.
- `MOUNTAIN`: live single-biome producer. In network preset it can bind the accepted world-layer reference as a bridge.
- `WORLD`: grammar/world route diagnostic. It can preview accepted reference height, but is not accepted default terrain.
- `LEGACY`: old DEM/kernel atlas regression path. Not accepted as target terrain.

Critical behavior:

- Mode switches call `unbind_all`, `free_all`, then reconfigure the same pool path.
- Debug state resets on mode switch so heatmaps/tints do not leak into visual comparison.
- Reference mode opens first so owner review starts from the known accepted mountain baseline.
- WORLD mode remains diagnostic because full world composition caused hitches/artifacts.

WG13 lesson:

- Runtime modes need explicit role/acceptance labels in code and HUD.
- A diagnostic mode must never become default terrain by convenience.

### 6. Progression harness

Key files:

- `worldgen_terrain/harness/wg10_progression_review.gd`
- `worldgen_terrain/harness/wg10_progression_review.tscn`
- `worldgen_terrain/tests/wg10_progression_review_check.gd`
- `worldgen_terrain/tests/wg10_progression_motion_check.gd`
- `worldgen_terrain/tests/wg10_progression_repage_visual_check.gd`

Active steps in WG10:

- `reference_baseline`: accepted static mountain-network baseline.
- `mountain_network_bridge`: single producer with accepted facts/reference bound beside it.
- `mountain_close_debug_candidate`: raw live seam-safe mountain page synthesis.
- `world_reference_preview`: WORLD route/weight diagnostics over accepted reference height.

Future/overlay concepts already encoded:

- source/display mapping overlay
- material fact layers
- pass-network facts
- procedural mountain world layer
- facts/collision parity

WG13 lesson:

- A progression harness should be built early, not after things go wrong.
- It should encode the promotion rules and expose contract snapshots programmatically.

## Mountain Runtime Architecture

### Rust recipe oracle

Key files:

- `rust/src/recipes/mountain.rs`
- `worldgen_terrain/shaders/biome_mountain.glsl`
- `rust/src/biome_page_compute/schedule_mountain.rs`
- `worldgen_terrain/shaders/biome_page.glsl`
- `worldgen_terrain/shaders/recipe_primitives.glsl`

Pipeline:

1. Build world-coordinate meshgrid over an apron-padded page.
2. Domain warp world coordinates.
3. Produce regional/ranges/ridge detail/near detail fields.
4. Blur ranges into range envelope and lowland masks.
5. Build massif and base fields.
6. If `flow_on`, compute primary and tributary masks. If not, explicitly zero masks so cached buffers do not leak old flow.
7. Build high/valley masks.
8. Assemble height from base + ridge/detail - carve/branch.
9. Blend valley floor.
10. Final blur/remap.
11. Crop apron core to output page.

Important note:

- `biome_mountain.glsl` currently has a WG11 spike-tune comment changing threshold/gain constants from the Rust oracle values. That is a visual-risk area. For WG13, either restore strict parity or deliberately version that as a separate candidate mode.

WG13 lesson:

- Keep Rust oracle and GLSL fragment side by side.
- Keep a generic compute machine and per-biome fragments separate.
- The render shader is not the terrain generator; it only presents generated height/facts.

### Page pool producer split

Key files:

- `rust/src/page_pool/config_api.rs`
- `rust/src/page_pool/configure.rs`
- `rust/src/page_pool/producer.rs`
- `rust/src/page_pool/acquire.rs`
- `rust/src/page_pool/state_api.rs`
- `rust/src/page_pool/world_layer_bindings.rs`
- `rust/src/page_pool/world_layer_contract.rs`
- `rust/src/page_pool/static_reference.rs`
- `rust/src/page_pool/static_reports.rs`

Producer kinds:

- Legacy DEM/kernel atlas
- Single biome GPU producer
- World biome producer
- Static reference producer
- Analytic proving producer
- RegionFact baked producer

Good modular pattern:

- `config_api.rs` owns Godot-callable setup.
- `producer.rs` owns active producer classification and dispatch.
- `acquire.rs` owns slot allocation/compute/rollback.
- `state_api.rs` owns read-only/debug/pinning APIs.
- contract/report modules own acceptance facts.

WG13 lesson:

- A central pool object is okay if the implementation is split by concern.
- Do not mix setup, dispatch, policy, reports, and lifecycle in one god file.

### RegionFact baked path

Key files:

- `rust/src/region_bake/mod.rs`
- `rust/src/region_bake/gpu_macro.rs`
- `rust/src/region_bake/worker.rs`
- `rust/src/region_bake/percentile_provider.rs`
- `rust/src/page_pool/region_producer.rs`
- `rust/src/page_pool/region_fact.rs`

Pipeline:

1. Worker owns a local RenderingDevice.
2. Worker runs GPU macro page compute over a whole super-region with apron.
3. Readback produces the raw macro field off-frame.
4. Pass-network routes and carve run on raw height.
5. Conditioning runs after carving.
6. Smooth percentile fields provide seam-exact cross-region conditioning.
7. The baked super-region is sliced into overlapping region facts.
8. The page pool drains completed facts into a region cache.
9. If a page asks for an unbaked region, the pool enqueues the super-region once and writes a flat fallback page.
10. Later acquisition upgrades the page from fallback to baked height.

WG13 lesson:

- This is the serious baked-mountain path to learn from.
- Expensive GPU readback is allowed only off-frame/worker.
- Runtime pages sample cached facts; they do not block rendering on the full bake.

### Pass network

Key files:

- `rust/src/pass_network/mod.rs`
- `rust/src/pass_network/cost.rs`
- `rust/src/pass_network/routes.rs`
- `rust/src/pass_network/dijkstra.rs`
- `rust/src/pass_network/edt.rs`
- `rust/src/pass_network/carve.rs`
- `rust/src/pass_network/tests.rs`

Behavior:

- Downsample to a coarse grid.
- Compute slope cost.
- Route west-east and north-south crossings with Dijkstra.
- Map paths back to full resolution.
- Build a graded route floor with slope budget.
- Use EDT nearest-route fields to carve a corridor band.
- Deepest carve wins where routes overlap.

WG13 lesson:

- Passes are facts. They should affect height, material hints, overlays, and eventually collision/query.
- Do not make routes a visual decal only.

## Scene File Map

Use these as the WG10 mountain study set:

- `worldgen_terrain/m3/m3_slice1.gd`: first visual GPU page proof.
- `worldgen_terrain/harness/m3_review.gd/.tscn`: first accepted flyable infinite shell.
- `worldgen_terrain/harness/rough_world_review.gd/.tscn`: generated rough-highlands single-window review.
- `worldgen_terrain/harness/rough_world_chunks_review.gd/.tscn`: chunk continuity and seam review.
- `worldgen_terrain/harness/rough_world_travel_review.tscn`: scale/travel read.
- `worldgen_terrain/harness/rough_world_infinite_review.tscn`: static infinite/world framing review.
- `worldgen_terrain/harness/mountain_corridor_review.tscn`: corridor/pass readability scene.
- `worldgen_terrain/harness/mountain_network_review.tscn`: network visual scene.
- `worldgen_terrain/harness/mountain_network_chunks_review.tscn`: network chunks visual gate.
- `worldgen_terrain/harness/mountain_world_chunks_review.gd/.tscn`: 9x9 mountain world/chunk/collision/player-eye review.
- `worldgen_terrain/harness/mountain_fly_review.gd/.tscn`: live mountain/reference/world/legacy runtime fly review.
- `worldgen_terrain/harness/mountain_fly_producers.gd`: mode taxonomy and producer configuration.
- `worldgen_terrain/harness/mountain_fly_runtime_config.gd`: shared runtime constants.
- `worldgen_terrain/harness/wg10_progression_review.gd/.tscn`: ordered promotion harness.

## Test/Gate Map

Study these because they encode the failure modes:

- `worldgen_terrain/tests/m3_*_check.gd`: pool, stream, view, continuity, capacity, acceptance.
- `worldgen_terrain/tests/mountain_network_visual_capture.gd`: visual capture around mountain network.
- `worldgen_terrain/tests/mountain_network_chunks_review_check.gd`: chunk/network review state.
- `worldgen_terrain/tests/mountain_world_chunks_review_check.gd`: mountain world chunk payload and view logic.
- `worldgen_terrain/tests/mountain_runtime_reference_static_compare.gd`: runtime reference comparison.
- `worldgen_terrain/tests/mountain_fly_*_check.gd`: fly modes, producer config, visibility churn, perf.
- `worldgen_terrain/tests/wg10_progression_*_check.gd`: progression state, motion, visual repage.
- `rust/src/pass_network/tests.rs`: pure route/carve invariants.
- `rust/src/region_bake/*_tests.rs`: macro/readback, super-region slicing, percentile seam exactness, outer seams.
- `rust/src/page_policy_tests.rs` and `rust/src/schedule_policy_tests.rs`: bounded work, no eviction of displayed pages, coverage/fallback rules.

## What WG13 Should Keep

- Rust owns deterministic policy and terrain/runtime core.
- GPU compute owns page/macro production where it is performance-critical.
- GDScript owns thin assembly and review harnesses only.
- Page pool, streamer, rings, terrain view, producer dispatch, contracts, and reports stay separate modules.
- Accepted reference, candidate, diagnostic, and legacy lanes stay visibly separate.
- Visual gates are first-class. Tests alone do not promote terrain.
- Region/world-layer facts should be explicit, sampled, reportable, and eventually shared by visual/collision/query.

## What WG13 Should Avoid

- Do not make WORLD composition default just because it compiles.
- Do not collapse reference and candidate paths into one mode.
- Do not let debug material/route tint leak into accepted material review.
- Do not rely on Python-generated authority loops for final runtime truth.
- Do not put scheduling, rendering, producer setup, acceptance reports, and review controls in one god file.
- Do not keep adding post-mountain layers without visual confirmation after each layer.

## Suggested WG13 Mountain Roadmap

1. Rebuild M3 shell cleanly: one page proof, then flyable flat/debug clipmap, then no-black sprint review.
2. Bring over mountain recipe as a Rust oracle plus GLSL compute fragment. Keep parity strict before visual tuning.
3. Add mountain reference mode using archived accepted payloads only as review baseline.
4. Add live single-mountain candidate mode separately from reference.
5. Add pass-network facts in Rust, then visual overlay, then height carve.
6. Add RegionFact-style baked super-region worker for carved/conditioned mountain world-layer.
7. Add material facts and source/display mapping as separate overlays.
8. Only after mountain is accepted again, start post-mountain biome/world composition one layer at a time.

## Bottom Line

The strongest WG10 mountain idea is the contract boundary:

`GPU macro/page producer -> Rust route/carve/condition/facts -> bounded page pool residency -> read-only terrain view -> explicit review modes -> visual promotion gate`.

That should be the WG13 spine.
