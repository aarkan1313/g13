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
M2-SHAPE REDESIGNED (2026-06-06): after ~12+ failed terrain-shape attempts across
M2.3/M2.3b/M2.4 (hand-noise "oatmeal" -> ridged "mesa" -> DEM-spectral "uniform";
then a per-biome composition-recipe attempt that LOOKED good but got tangled in a
steep-terrain collision mess), rolled main back to M2.2 (c83da21) and redesigned.
NEW ARCHITECTURE (spec: docs/superpowers/specs/2026-06-06-m2-terrain-composition-dem-tuned-design.md):
two INDEPENDENT axes -- SHAPE = ONE DEM-tuned composition machine (an uplift field
PLACES structure; DEM stats TUNE character via a continuous blend); BIOME = the
unchanged M2.2 stats classifier as a SKIN (color now, textures later). Structure
from composition, NOT stats-matching (the proven failure). General terrain first;
per-biome shape + erosion (M6) deferred. The offline dem_distill tool + fingerprints
are RESTORED to feed the character field. New sequence below.
M2.3 [x] COMPOSITION MACHINE: structure (primitives + uplift field + composition, hand-set character). Test gate PASS (fresh re-run 2026-06-06: m2_3_composition_check determinism, structure-not-uniform spread 0.81, no-cliff 5.1m; m2_1/m2_2/m1_7c still PASS). Human VISUAL gate PASS 2026-06-06: live fly after AABB cull fix, user verdict "terrain looks really good"; good beginning for macro mountain/plain terrain. Capture tool made ground-aware. DEM character tuning is NOT done yet; M2.3 is the general structure pass.
M2.4 [ ] DEM CHARACTER integration - RETHINK after M2.4a visual fail. The 2026-06-06 M2.4a attempt wired DEM fingerprint scalars directly into ridge/detail/relief knobs; it passed numeric gates twice but failed live visual review twice with corduroy grooves / harsh parallel walls. Main has been reverted to the M2.3 visual-pass terrain. Failed M2.4a is preserved at branch `backup/m2-4-failed-2026-06-06` and tag `backup-m2-4-failed-2026-06-06`. New direction: M2.4b must not be another scalar tweak. Keep M2.3 structure as baseline, use DEMs indirectly as offline target envelopes / region-level character families, add fixed visual-fail hotspots to capture/gates, and require human visual pass before marking complete.   <- CURRENT
M2.5 [ ] general-terrain VISUAL ACCEPTANCE + polish (fly + walk whole world; address steep-terrain consequences HERE if they appear, in the right layer, gated).
M2.6 [ ] EFFICIENCY/PERF PASS (LAST, the M1.9 way): profile the real composed field vs budget on the RTX 3070 target.
M2.7 [ ] CHARACTER/COLLISION CONTROLLER PASS (its own gated step, pillar call 2026-06-06 — do NOT keep patching the probe piecemeal). The M1.7 capsule is a collision test PROBE; this session bolted on turbo, anti-tunnel substepping, momentum, climb-any-slope, taller capsule (all functional, m1_7c green) while chasing fall-throughs. Remaining for a clean pass: (a) "see under the slope" — on steep ground the upright tall capsule's fixed-offset eye looks INTO the uphill terrain (collision data is CORRECT — measured == terrain within 4cm; it's camera/character GEOMETRY on slopes, NOT a collision-height bug); (b) jump feel; (c) long-term collision quality (HeightMapShape linear-interp between cells; collision only on level-0 fine pages; following at distance); (d) capsule shape/eye tuning. Decide engine-rig vs game-character boundary here. KNOWN-GOOD: collision follows the active controller (capsule in walk) + radius 2; turbo no longer tunnels (substepped).
M2.x [ ] MILESTONE GATE — tag m2-complete
LATER (not M2, each its own gated step): per-biome SHAPE modulation (one biome at a time); erosion (M6) carves AAA hydraulic realism into the macro.

## Beyond: see ROADMAP.md (headers only, by design)
