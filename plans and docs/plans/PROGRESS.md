# PROGRESS — single source of truth for "where are we"

One line per step. Agent updates at every green gate. If this disagrees with reality, reality wins and the agent logs the discrepancy in DRIFT_LOG.md.

## Setup (pre-M1, 2026-06-06)
S.1 [x] toolchain verified (Godot 4.6.2-mono, Rust 1.94.1, git 2.52) — see 01_TOOLCHAIN.md
S.2 [x] project.godot fixed: Vulkan driver, [dotnet] stripped (no C#)
S.3 [x] git initialized at repo root; archive (97 GB) + _manifest gitignored
S.4 [x] DEM library inventoried: 135 labeled reference tiles — see 03_DEM_CATALOG.md
S.5 [x] docs set GPU-first: GPU field is source of truth (00 §2.1/§3/§4); M1 rebuilt as GPU ladder
S.6 [x] WG10 reclassified as reference-only (00 §3.1) — rebuild clean, copy no files

## Milestone 1 — Contiguous infinite land (GPU-first)
M1.1 [x] gdext skeleton loads; WorldRoot prints on _ready; edit→rebuild→new string verified (output-proven)
M1.2 [x] GPU page produced + read back; determinism/seed/continuity/seam tests PASS (output-proven)
M1.3 [x] page renders on screen — smooth, non-blocky, seed-driven; human visual PASS 2026-06-06
M1.4 [x] NxN page block, zero seams (edge-readback test PASS + teeth; human visual PASS)
M1.5 [x] bounded pool + clipmap rings + read-only view; streams, no black, no z-fight; human live fly PASS 2026-06-06 (slight LOD seam = deferred geomorph)
  M1.5a [x] Rust PagePool: caches by (level,gx,gz), bounded new-per-frame; pool-driven static ring renders (test PASS)
  M1.5b [x] camera-following streaming: ring recenters, evicts behind, pins displayed; flat memory (test PASS)
  M1.5c [x] annulus clipmap: coarse blanket EAGER, fine BOUNDED; coarse HIDDEN where fine covers (no overlap -> no z-fight) yet shown over holes (never-black). coverage + overlap tests PASS
M1.6 [x] LOD to horizon: 6 levels -> ~49km reach (30km goal +margin), fog hides edge; frame-time gate PASS (steady-state 2.4ms/420fps, p99 2.7ms << 16.6); startup ~150ms one-time transient (deferred async-load). Live horizon confirmed at the M1.8 milestone flythrough.
M1.7 [x] near-page collision, character doesn't fall through (human live PASS 2026-06-06)
  M1.7a [x] PagePool retains CPU heights; get_page_heights() returns the SAME array behind the texture (no readback, no second path). Test PASS (bit-identical to texture, matches FieldCompute, empty when non-resident)
  M1.7b [x] collision build in world_view: level-0 only, radius 1, WorkerThreadPool off-thread -> deferred add_child; bodies evict with the ring. Test PASS (shape map_data bit-identical to pool heights; dims + page-centre transform + cell_spacing scale correct; 9 bodies for 294 meshes = near pages only)
  M1.7c [x] capsule character + fly/walk (F/G) toggle. Output-provable core PASS + human live PASS ("didnt fall through, you fixed it"). Fix: walk/fly mutually exclusive (no input bleed) + spawn just above resident terrain. Controls: Space rise/jump, C descend, Shift sprint
M1.8 [x] MILESTONE GATE — full DoD met: 9/9 structural gates + frame-time gate green; human live flythrough (auto-tour) PASS 2026-06-06. Tagged m1-complete.

## M1.9 — Performance hardening (foundation pass, before M2)
A careful, EVIDENCE-FIRST pass: make the foundational infra as efficient as it can be WITHOUT sacrificing features/quality ("build it right once"). Optimize workload-INDEPENDENT things (per-frame waste, allocations, reuse, the streaming hitch); DEFER workload-dependent tuning (LOD radii, texture/scatter batching) to when real M2+ content exists. Measure before cutting.
M1.9.1 [x] instrument per-system frame breakdown — pool produce_us (GPU dispatch+readback), view _process us, mesh-build us; HUD profiler section (key 5). Smoke + 10 gates green. (measure before cutting)
M1.9.2 [x] captured + root-caused the fast-motion spike with the profiler — it was per-page mesh/material ALLOC on the eager burst (NOT the GPU, as first assumed). Evidence-driven.
M1.9.3a [x] mesh/material pooling (shared per-level mesh + instance free-list) — worst frame 35->17ms, mesh build 19->0.8ms. 12 gates green.
M1.9.3b [x] spread the eager burst: mid-coarse bounded (max_eager_per_frame), coarsest unbounded (never-black floor). Worst frame 17->11ms, 0/300 over budget. Never-black PROVEN by new m1_9b_eager_spread_check. 13 gates green.
M1.9.3c [x] cut per-frame string-key churn: parse the page key ONCE at creation (_inst_meta), single-pass drop/pin (was 6x re-iterate + split). Churn ~3.6->~1.8ms. 13 gates green.
M1.9.x [x] PERF GATE: worst fast-motion frame 35->~11ms (3.2x), 0/300 over the 16.6 budget, never-black PROVEN intact, 13 gates green. Workload-independent waste removed. (GPU page production async/double-buffer = the remaining cost, DEFERRED: it's real work + workload-dependent, optimize when biomes/erosion make the field heavy.)

## Milestone 2 — Untextured biomes + DEM-informed shape  (plan: M2_DESIGN.md — plain-language + decisions made)
M2.1 [x] temperature & moisture climate fields. Test gate PASS (m2_1_climate_check: determinism, range [0,1], low-freq/smooth, latitude gradient 0.359/30km — 14/14 gates green, M1 height path bit-identical/additive). VISUAL gate PASS (human, 2026-06-06): flew live, V cycles normal/temp/moisture; after retuning the climate viz to distinct color languages (temp = blue->violet->red thermal; moisture = brown->green->blue earth/water, remapped to the field's real ~[0.12,0.55] range) both read as clear large-scale gradients and are unmistakable from each other. Climate rides height's single GPU dispatch (page = [h,t,m]); height texture/heights array unchanged (collision intact).
M2.2 [x] Whittaker biome id (nearest-centroid over temp/moisture/MACRO-altitude), N-axis data-driven roster (10 biomes), field-side, page gains biome-id channel. Test gate PASS (m2_2_biome_check: determinism, valid ids [0,10), contiguity 0% adjacent-differ on fine pages, global variety, seed sensitivity — 15/15 gates green). VISUAL gate PASS (human, 2026-06-06): flew live, V->biome; large contiguous regions with sensible geography (tundra/rock ridge, snow peak, forest+grassland lowlands), 240fps/prod 0.00ms. Build-time fixes: macro-altitude (continental low-freq, not detailed height) killed confetti-at-LOD; M2.1 temp rebalance (warm floor + normalized lapse) -> all 10 biomes appear. Lowland green/yellow border-mottling + hard edges = M2.4's job.
M2.3 [~] per-biome height shaping. height = SHARED base landform (low octaves, continuous across borders) + biome.detail_amp * detail_fbm(biome.detail_rough). Biome chosen from macro-altitude (independent of shaped height) -> no circularity, determinism intact. Shaping params are DATA (biome rows gained detail_amp + detail_rough; mountain rock amp 1.5/rough 2, grassland amp 0.25/flat). Test gate PASS (m2_3_shaping_check: determinism, rugged biome is roughest AND 2.6x flattest, no border cliff — 16/16 gates green; M1 seam/continuity/collision still pass). VISUAL gate (mountains rugged, plains flat) PARKED-FOR-VISUAL: needs low-altitude flight (high capture too far to show shape); fly mountain-rock vs grassland in the live scene.   <- CURRENT
M2.4 [ ] border blending, no hard square borders
M2.5 [ ] offline DEM-stats tool outputs params file
M2.6 [ ] DEM-informed biomes read as believable
M2.x [ ] MILESTONE GATE — tag m2-complete

## Beyond: see ROADMAP.md (headers only, by design)
