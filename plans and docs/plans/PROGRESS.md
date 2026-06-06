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
M2.3-ABANDONED [~] hand-tuned per-biome noise shaping. Test gate passed but the SHAPE was bad on every live flyover: plain value-noise fBM is structurally incapable of real landforms ("Perlin oatmeal" -> "mesa cliffs", the attempt #1-12 failure). ~10 tuning iterations + the M2.3b ridged-noise attempt all failed. REVERTED the field to the M2.2 state; abandoned hand-tuned noise as the shape source. (Climate M2.1 + biome-selection M2.2 kept — they work.)
   M2 SHAPE REPLANNED (2026-06-06): use the real DEMs to INFORM a procedural generator. Spec: docs/superpowers/specs/2026-06-06-m2-dem-spectral-terrain-design.md. New sequence below.
M2.3 [x] OFFLINE DEM DISTILLATION TOOL (rust/dem_distill, separate binary, NOT in the runtime). Reads 135 labeled DEM tiles -> per-archetype FINGERPRINT file wg-13/data/dem_fingerprints.json (3.5 KB): radial amplitude spectrum (8 octave bands) + slope_p95 ceiling + ridge character. cos(lat) corrected; dims from the .tif (sidecar width/height optional). GATE PASS (tests/fingerprints_sane.rs): read 135/skipped 0, all 12 archetypes, spectra normalized, slopes plausible, mountain slope_p95 0.888 >> grassland 0.181 (4.9x — real-Earth believability signal). 10/10 dem_distill tests pass; runtime (wg13) unaffected (15 GB DEMs -> 3.5 KB, no .tif at runtime). KNOWN for M2.4: ridge_character metric weak/compressed — tune vs real rendered terrain, not in a vacuum.
M2.4 [ ] SPECTRAL-SHAPED RUNTIME FIELD. Field synthesizes procedural height with each biome's MEASURED octave spectrum (not hand-tuned fBM) + ridge character + slope ceiling, read from dem_fingerprints.json. Start with mountain+grassland+desert (prove the contrast), gate test+visual, THEN expand to all 12. Quality-first, NOT perf-tuned yet. GATE (test): determinism, per-biome spectra match fingerprints, no cliffs (step <= data slope ceiling). GATE (visual): believable real-world landforms, distinct per biome.   <- CURRENT
M2.5 [ ] border blending — blend spectral params + color across biome borders (no hard edges). GATE (visual): natural transitions.
M2.6 [ ] EFFICIENCY/PERF PASS (LAST, the M1.9 way): profile the REAL spectral field vs the frame budget (HUD), optimize synthesis (octaves, sample reuse, async). GATE (test): budget held on the RTX 3070 target.
M2.x [ ] MILESTONE GATE — tag m2-complete

## Beyond: see ROADMAP.md (headers only, by design)
