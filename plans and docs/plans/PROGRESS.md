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
M2.4 [~] DEM/terrain-shape enrichment — ATTEMPTED 4 ways (a/b/c/d), ALL failed visual review, ROLLED BACK to this M2.3 baseline (2026-06-07). a=DEM scalar tuning, b=per-cell oracle, c=cached macro GPU bridge, d=DEM-driven macro. History recoverable: tag `backup-m2-4-all-attempts-2026-06-07`. LESSON (postmortem `plans and docs/plans/M2_4_POSTMORTEM.md`): the problem is MACRO RESOLUTION × LOD × VIEWING SCALE, not character source — DEM character was PROVEN to reach the screen and still looked blocky (256m macro grid = the visible stair-step artifact at altitude). Do NOT re-run "wire character to DEM."
M2.4-reframe [x] DONE (2026-06-07). Brainstorm reframed M2.4 from "richer shape" to the ONE real defect at the scale the user judges by (low/walk): the per-chunk SEAM. Diagnosed (after 2 wrong guesses — geometry step, then normal-via-fragment — both reverted) by EVIDENCE: heights bit-identical across edges (m1_4), normal mismatch only ~0.8deg (probe), nearest-filter didn't help, page-tint overlay + user's "fixed line between every chunk, all views, ground+air, doesn't flip with light" -> it's the display shader's per-vertex normal going ONE-SIDED at page borders (sample_h UV clamp). FIX: bake an ANALYTIC per-cell normal in field_height.glsl from the continuous composition_height at world neighbors (+/-spacing) -> adjacent pages agree at the shared edge -> seam gone BY CONSTRUCTION (one source of truth). FIELD_CHANNELS 4->6 (normal_x/z), RG32F normal_tex per page (mirrors climate/biome), display reads it. Heights/collision untouched. Gates green (m1_4/m1_7c/m2_3/m2_1/m2_2 PASS). Self-verified seam gone in shape_low0/1/2 captures, then human VISUAL PASS 2026-06-07 ("its good"). Commits 1620e55/a537282/f1ec447 (geomorph detour reverted 9ac29df).
M2.4-perf -> became M2.6 [~] MOSTLY DONE (2026-06-07). The seam fix exposed a pre-existing streaming-BURST hitch (profiling corrected the "5x math" guess: the 4 extra evals were only ~3%; the real cost was the per-page SYNCHRONOUS GPU round-trip in produce()). Did the full M2.6 GPU-resident pass (spec/plan committed). DONE + committed: Stage 0 burst perf gate (baseline 47ms median-of-maxes); GPU-resident RENDER via Texture2DRD on the main device (no readback/re-upload for render) + RENDER_MODE in field_height.glsl + render_gpu.rs; collision readback trimmed to level-0 only; RAII RID lifetime (fixed a 609-errors/frame use-after-free where evicted Texture2DRDs were still bound — world_view._recycle_instance now nulls material textures); coarse-page mesh subdivision taper (6.5M->2.2M tris, free headroom). RESULT: burst 47ms -> ~13ms median-of-maxes, 0/720 over budget; 609 render errors -> 0; human re-fly "better, more stable on average, occasional 12-14ms". DEEP-DIVE (evidence): stationary=1.5ms vs moving=8.4ms -> remaining movement cost is PER-PAGE PRODUCTION (the level-0 collision readback STILL blocks on rd.sync ~625us/page + the main-device render compute for new pages), NOT draw/triangles/fill. Gates green: m1_4/m1_5c/m1_6/m1_7a(updated for Texture2DRD)/m1_7b/m1_7c/m2_1/m2_2/m2_3/m2_6_burst/m2_6_vram.
M2.6-batch [x] DONE (2026-06-07). Async per-page readback was tried + FAILED (local RenderingDevice = ONE outstanding submit; per-page tickets impossible; reverted). The working fix: BATCH the level-0 collision readback — produce() records pending level-0 pages (render textures still immediate, GPU-resident); the next begin_frame runs dispatch_height_batch over ALL pending in ONE compute list / ONE submit / ONE sync, fills each page's heights. Fits the single-submit constraint. Heights land one frame later; collision already retries (m1_7b/c PASS); m1_7a updated to trigger the collect before asserting (heights still bit-identical to FieldCompute — no drift). MEASURED (low-fly A/B): avg frame 8.02->7.06ms, produce_us 2250->1717us (-24%). Burst still 0/720 over budget. All 10 gates green. Commit fa32d85. Preserves Codex's cpu_readback_enabled toggle (DEM-review escape hatch; NOT accepted production architecture per user). NET PERF (whole pass): seam-fix 47ms burst -> 13ms; low-fly ~7ms; 609 render errors/frame -> 0.
M2.6-more [ ] OPTIONAL / deferred. Remaining per-page producer: the MAIN-device RENDER dispatch (render_gpu.produce) is still one-per-page — could batch it the same way, but render has NO blocking sync (the cheap half) so the gain is smaller than the collision batch. Pursue only if perf still bites once real game systems exist. Also untried: lower max_new_per_frame (spreads fine production, more pop-in). Perf is in a strong, banked place; M2.6 effectively complete for now.

## Render Forever — range + fog + spread streaming (2026-06-07; spec+plan committed)
Builds on M2.6. Spec: docs/superpowers/specs/2026-06-07-render-forever-range-fog-spread-design.md. Plan: docs/superpowers/plans/2026-06-07-render-forever-range-fog-spread.md.
RF.P1 [~] REACH: num_levels 6->8 -> reach ~49km -> ~195.1km. Test gate: full 10-gate suite GREEN at 8 levels (burst median-of-maxes 10.10ms@6lvl -> 10.95ms@8lvl, still 0/720 over the 16.6 budget; VRAM bounded resident 368 << produced 5213; collision/heights/seam/climate/biome/composition all PASS). VISUAL gate PARKED for human (does terrain read to a far horizon in all directions? any far-distance vertex shimmer/precision wobble?).
RF.P2 [ ] FOG/FAR: retune so the continuous-flight streaming frontier is buried in fog (no pop-in). GDScript-only.
RF.P3 [ ] SPREAD: bound the coarsest level — EVIDENCE-GATED (only if the 8-level burst hitches; the P1 measurement already suggests YAGNI). Rust.
RF.P4 [ ] HOLD BUDGET: re-confirm m2_6_burst_perf_check at 8 levels (preview above: holds).
M2.5 (was next pre-perf) [ ] general-terrain VISUAL ACCEPTANCE + polish — still pending; perf was done out of order.
M2.5 [ ] general-terrain VISUAL ACCEPTANCE + polish (fly + walk whole world; address steep-terrain consequences HERE if they appear, in the right layer, gated).
M2.6 [ ] EFFICIENCY/PERF PASS (LAST, the M1.9 way): profile the real composed field vs budget on the RTX 3070 target.
M2.7 [ ] CHARACTER/COLLISION CONTROLLER PASS (its own gated step, pillar call 2026-06-06 — do NOT keep patching the probe piecemeal). The M1.7 capsule is a collision test PROBE; this session bolted on turbo, anti-tunnel substepping, momentum, climb-any-slope, taller capsule (all functional, m1_7c green) while chasing fall-throughs. Remaining for a clean pass: (a) "see under the slope" — on steep ground the upright tall capsule's fixed-offset eye looks INTO the uphill terrain (collision data is CORRECT — measured == terrain within 4cm; it's camera/character GEOMETRY on slopes, NOT a collision-height bug); (b) jump feel; (c) long-term collision quality (HeightMapShape linear-interp between cells; collision only on level-0 fine pages; following at distance); (d) capsule shape/eye tuning. Decide engine-rig vs game-character boundary here. KNOWN-GOOD: collision follows the active controller (capsule in walk) + radius 2; turbo no longer tunnels (substepped).
M2.x [ ] MILESTONE GATE — tag m2-complete
LATER (not M2, each its own gated step): per-biome SHAPE modulation (one biome at a time); erosion (M6) carves AAA hydraulic realism into the macro.

## dem-grounded branch — streaming work (2026-06-07, IN PROGRESS, UNRESOLVED)
On branch `dem-grounded` (off main d56220c). The DEM-grounded terrain prototype.
USER VERDICT THIS SESSION: terrain SHAPE is acceptable ("we know terrain is ok").
The OPEN, UNRESOLVED problem the user wants fixed: streaming POP-IN and the world
not feeling consistently CENTERED on the camera while flying. User states it is not
better after the changes below, and is still wrong.

What was changed on dem_grounded_world_view.gd this session (committed):
- 215b8f6: num_levels 6->8, nearest-first page production, thin edge fog.
- 16295ee: ring_radius 3->5, evict_margin 1->2, max_new_per_frame 8->32,
  max_eager_per_frame 24->128, travel-direction bias on production. (Reach ~162km.)
- Part A (round() instead of floor() for ring centering): IMPLEMENTED, user flew it,
  reported "not really any different/better and now its laggy" -> REVERTED (not committed).
- Design spec 1b26175: docs/superpowers/specs/2026-06-07-clipmap-continuous-centering-design.md
  (Part A round-centering + Part B fade-in). Part A reverted as above; Part B not done.

Current config on the branch (committed at 1b26175): num_levels 7, ring_radius 5,
evict_margin 2, max_new_per_frame 32, max_eager_per_frame 128. User reports this is LAGGY.

STATUS: streaming pop-in / centering NOT fixed. Next steps not decided. Throwaway
diagnostic captures/popin_probe.gd exists (uncommitted). Untracked editor-regenerated
files stashed on main earlier ("editor-regenerated uid/tscn files on main, 2026-06-07").

## Beyond: see ROADMAP.md (headers only, by design)
