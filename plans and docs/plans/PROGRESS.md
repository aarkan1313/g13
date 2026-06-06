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
M1.3 [~] page renders on screen (PNGs captured: non-blocky, seed-driven); PARKED-FOR-VISUAL aesthetic   <- CURRENT (see DRIFT_LOG)
M1.4 [ ] NxN page block, zero seams (visual + edge-readback test)
M1.5 [ ] bounded page pool + clipmap rings + read-only view; stream, no black, no leak
M1.6 [ ] LOD to horizon at frame budget, frame-time test passes
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
