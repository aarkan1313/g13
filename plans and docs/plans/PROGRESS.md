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
M1.6 [~] LOD to horizon: 6 levels -> ~49km reach (30km goal +margin), fog hides edge; frame-time gate PASS (steady-state 2.4ms/420fps, p99 2.7ms << 16.6); startup ~150ms one-time transient (deferred async-load). Live horizon PARKED-FOR-VISUAL   <- CURRENT
M1.7 [x] near-page collision, character doesn't fall through (human live PASS 2026-06-06)
  M1.7a [x] PagePool retains CPU heights; get_page_heights() returns the SAME array behind the texture (no readback, no second path). Test PASS (bit-identical to texture, matches FieldCompute, empty when non-resident)
  M1.7b [x] collision build in world_view: level-0 only, radius 1, WorkerThreadPool off-thread -> deferred add_child; bodies evict with the ring. Test PASS (shape map_data bit-identical to pool heights; dims + page-centre transform + cell_spacing scale correct; 9 bodies for 294 meshes = near pages only)
  M1.7c [x] capsule character + fly/walk (F/G) toggle. Output-provable core PASS + human live PASS ("didnt fall through, you fixed it"). Fix: walk/fly mutually exclusive (no input bleed) + spawn just above resident terrain. Controls: Space rise/jump, C descend, Shift sprint
M1.8 [x] MILESTONE GATE — full DoD met: 9/9 structural gates + frame-time gate green; human live flythrough (auto-tour) PASS 2026-06-06. Tagged m1-complete.

## M1.9 — Performance hardening (foundation pass, before M2)
A careful, EVIDENCE-FIRST pass: make the foundational infra as efficient as it can be WITHOUT sacrificing features/quality ("build it right once"). Optimize workload-INDEPENDENT things (per-frame waste, allocations, reuse, the streaming hitch); DEFER workload-dependent tuning (LOD radii, texture/scatter batching) to when real M2+ content exists. Measure before cutting.
M1.9.1 [x] instrument per-system frame breakdown — pool produce_us (GPU dispatch+readback), view _process us, mesh-build us; HUD profiler section (key 5). Smoke + 10 gates green. (measure before cutting)
M1.9.2 [ ] root-cause + fix the fast-motion streaming spikes (p99/max jumps when moving fast)   <- CURRENT
M1.9.3 [ ] sweep workload-independent inefficiencies (per-frame GDScript, allocations, mesh/material reuse)
M1.9.x [ ] perf gate: smooth under motion, no per-frame waste, all M1 gates still green

## Milestone 2 — Untextured biomes + DEM-informed shape
M2.1 [ ] temperature & moisture debug-color fields
M2.2 [ ] Whittaker biome id, contiguous regions (visual + determinism test)
M2.3 [ ] per-biome height shaping
M2.4 [ ] border blending, no hard square borders
M2.5 [ ] offline DEM-stats tool outputs params file
M2.6 [ ] DEM-informed biomes read as believable
M2.x [ ] MILESTONE GATE — tag m2-complete

## Beyond: see ROADMAP.md (headers only, by design)
