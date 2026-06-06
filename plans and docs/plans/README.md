# World Generator — Documentation Set

Attempt #13. The previous twelve failed on **architecture tangle** and **plan drift during unsupervised work**, not on algorithms. This doc set is built to prevent exactly those two failure modes.

## Read in this order
1. **00_ARCHITECTURE.md** — first principles. The Field/Renderer boundary is the rule that prevents "works then breaks." Read this fully before any code.
2. **01_TOOLCHAIN.md** — verified environment + the concrete build/run/test/visual-capture/perf commands every gate depends on.
3. **02_WORKFLOW.md** — the anti-drift protocol. THE most important doc for the real failure mode. Defines gates, the DRIFT_LOG, and the rule that unsupervised work may only cross *test* gates and must park at *visual* ones.
4. **MILESTONE_1_land.md** — contiguous infinite land, gated step by step. Start here for building.
5. **MILESTONE_2_biomes.md** — untextured biomes + how DEMs inform the terrain.
6. **03_DEM_CATALOG.md** — inventory of the 135 labeled reference DEMs M2 draws on.
7. **ROADMAP.md** — everything else, as headers, in dependency order.

## Live tracking files
- **PROGRESS.md** — where we are, one line per step.
- **DRIFT_LOG.md** — what the agent hit while you were away. Read first each session.

## The three things to never forget
1. **Field is the "what," Renderer is the "how it looks." They never know each other's internals.** (00 §2)
2. **Every step ends in a gate. Unsupervised work crosses test gates and PARKS at visual gates.** (02 §2)
3. **Quality is the LAST pillar. Survivability is the first.** A live, troubleshootable project beats a beautiful dead one. (00 §1)

## Confirmed technical baseline (verified 2026-06-06 on this machine)
- Godot **4.6.2-stable-mono**, Forward+ / **Vulkan** (`project.godot` set to vulkan). Mono build, but **no C#** — gdext + GDScript only; `[dotnet]` stripped. See `01_TOOLCHAIN.md §1`.
- Rust `1.94.1` / cargo `1.94.1`; git `2.52`. Repo root = `D:\world gen 13` (archive + manifests gitignored).
- gdext (godot-rust) v0.5+, `compatibility_minimum = 4.2`; hot reload supported (essential for the tuning loop). Exact crate version pinned at M1.1.
- Canonical data model: 3D signed-distance/density field; M1 renders surface-only; caves later use Surface Nets/Dual Contouring with no field rewrite.
- **CPU field is the source of truth.** M1 meshes the surface on the CPU (per-chunk `ArrayMesh`). The GPU page-pool/clipmap machinery described in `WG10_MOUNTAIN_DEEP_DIVE.md` is a *later* performance path and a source of lessons — **not** how M1 starts. We do not begin with GPU page producers. See `00_ARCHITECTURE.md §3`.
