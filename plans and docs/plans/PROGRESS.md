# PROGRESS — single source of truth for "where are we"

One line per step. Agent updates at every green gate. If this disagrees with reality, reality wins and the agent logs the discrepancy in DRIFT_LOG.md.

## Setup (pre-M1, 2026-06-06)
S.1 [x] toolchain verified (Godot 4.6.2-mono, Rust 1.94.1, git 2.52) — see 01_TOOLCHAIN.md
S.2 [x] project.godot fixed: Vulkan driver, [dotnet] stripped (no C#)
S.3 [x] git initialized at repo root; archive (97 GB) + _manifest gitignored
S.4 [x] DEM library inventoried: 135 labeled reference tiles — see 03_DEM_CATALOG.md
S.5 [x] docs reconciled: CPU-source-of-truth vs WG10 GPU path made explicit (00 §3.1)

## Milestone 1 — Contiguous infinite land
M1.1 [ ] project skeleton compiles, hot reload works   <- CURRENT
M1.2 [ ] field crate compiles, determinism + continuity tests pass
M1.3 [ ] single chunk renders (smooth, non-blocky)
M1.4 [ ] NxN chunk grid, zero seams (visual + edge-vertex test)
M1.5 [ ] streaming load/unload around viewer, no stutter, no leak
M1.6 [ ] LOD to horizon at 60 FPS, frame-time test passes
M1.7 [ ] near-chunk collision, character doesn't fall through
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
