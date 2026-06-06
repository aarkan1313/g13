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
M1.7 [ ] near-page collision, character doesn't fall through
M1.8 [ ] MILESTONE GATE — full definition of done, tag m1-complete

## Milestone 2 — Untextured biomes + DEM-informed shape
M2.1 [ ] temperature & moisture debug-color fields
M2.2 [ ] Whittaker biome id, contiguous regions (visual + determinism test)
M2.3 [ ] per-biome height shaping
M2.4 [ ] border blending, no hard square borders
M2.5 [ ] offline DEM-stats tool outputs params file
M2.6 [ ] DEM-informed biomes read as believable
M2.x [ ] MILESTONE GATE — tag m2-complete

## Beyond: see ROADMAP.md (headers only, by design)
