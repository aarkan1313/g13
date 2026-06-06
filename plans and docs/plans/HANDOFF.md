# HANDOFF — start here in a new session

You are picking up the WG13 world-generator **engine** (attempt #13; `D:\world gen 13`). This doc transfers the *operating state and judgment*, not the architecture — the canonical docs hold that. Read this, then the two short docs in step 1, then act. Do **not** binge-read everything; that bloats context and degrades you as badly as starting cold.

> **Note on you:** session-to-session is the fragile transition. The previous sessions had a good rhythm the user wants kept ("the magic"). The way to keep it is not to absorb maximum context — it's to adopt the *posture* below and trust the gates. When unsure, do the methodical thing, not the clever thing.

## 1. Orient (read these two, in order — ~5 min, not everything)
1. `02_WORKFLOW.md` §8 (the working method) and §9 (engine-not-a-game). **This is the posture. Internalize it before touching anything.**
2. `PROGRESS.md` (where we are) + the **top** of `DRIFT_LOG.md` (most recent entries — what just happened, what's parked).

Then, only if you need them: `00_ARCHITECTURE.md` (the rules), `04_CODE_MAP.md` (what runs what + how to run a gate), `MILESTONE_1_land.md` / `MILESTONE_2_biomes.md` (the current step's detail). `README.md` lists full read-order. **Don't read the WG10 deep dive unless a step references it** — it's reference-only and long.

## 2. The posture (the part that's easy to lose)
- **Quality #1 = "do it right, no slop"** > Survivability > Modularity > Performance. **Apply the pillars yourself and state the decision.** Don't ask the user to ratify pillar calls — they've said this repeatedly. Surface only *genuine forks* (real design tradeoffs).
- **One gated step at a time.** Explain (plain language) → implement → **verify with evidence** (test PASS from stdout, or a measurement — never an eyeballed "it works") → update docs → commit at green → continue.
- **Systematic debugging always. If a fix doesn't work, REVERT it — never stack a second fix.** Question the measurement before trusting a number (we've been burned by `Performance.TIME_PROCESS`/`TIME_FPS` hiding spikes — use true per-frame `delta`, vsync off).
- **This is an engine, not a game.** No game-specific content in core; variability lives in data (`WorldConfig`, assets).
- **You launch scenes for the user** via `run.ps1` (PS Job → visible window). They only open the editor to tune in the inspector or when a Rust rebuild needs the DLL-lock released.
- **Use the brainstorming/debugging/etc. skills** when they apply (the harness reminds you). They've been load-bearing here.

## 3. Current state (update this in every handoff refresh) — refreshed 2026-06-06 (terrain-shape REDESIGN, after rollback)
- **On `main` at `540d58f`** (`github.com/aarkan1313/g13`). Tree clean. `m1-complete` tagged. Pushed to origin.
- **Done: M1 COMPLETE + M1.9 perf hardening + M2.1 climate + M2.2 biome id.** M1 = streaming shell (bounded pool, annulus clipmap, never-black, no z-fight), LOD ~49 km, near-page collision, perf-hardened (worst frame ~11 ms, 0/300 over budget). M2.1 = temp/moisture climate (V cycles normal/temp/moisture/biome). M2.2 = Whittaker biome id (10-biome roster, stats-based) — large contiguous regions. Both M2.1/M2.2 gated + human visual PASS.
- **!!! main was DELIBERATELY ROLLED BACK to M2.2 on 2026-06-06 !!!** (read the TOP DRIFT_LOG entry.) Terrain SHAPE thrashed (~12+ attempts: oatmeal/mesa/uniform, then a per-biome recipe that looked good but got tangled in a steep-terrain collision mess + a bandaiding-not-pillars lapse). The human chose to roll back to clean M2.2 and redesign. The abandoned M2.4a mountain-recipe work is SAFE (stash@{0}, branch `backup/pre-m2-rollback-7b2e8f4`, tag `backup-before-m2-rollback`, all on origin) — recoverable if wanted, but the redesign supersedes it.
- **NEXT STEP: M2.3 — the composition machine (general DEM-tuned terrain SHAPE).** APPROACH DECIDED + SPEC WRITTEN (do NOT re-decide): spec `docs/superpowers/specs/2026-06-06-m2-terrain-composition-dem-tuned-design.md`. TWO INDEPENDENT AXES: (1) SHAPE = ONE composition machine — an uplift/ruggedness field PLACES structure (ranges/hills vs flat lowlands), ridged+value fbm give relief, valley carve, and a CONTINUOUS DEM-CHARACTER field tunes relief/slope/ridge/scale (sampled richly across the library). STRUCTURE FROM COMPOSITION, NOT stats-matching (the burned-in failure). (2) BIOME = the unchanged M2.2 stats classifier as a SKIN (color now, textures later) — biomes care about stats + their own textures, NOT the DEMs. One dispatch, height R32F, no circularity. General terrain FIRST; per-biome shape modulation + erosion (M6) deferred. The offline `dem_distill` tool + `dem_fingerprints.json` are RESTORED (10/10 tests pass) to feed the character field. Build sequence: M2.3 structure -> M2.4 DEM character -> M2.5 visual-accept -> M2.6 perf. CRITICAL: terrain is a VISUAL problem — capture low + WALK it and use the human's eyes EARLY, every gate; a green test gate on a bad picture is the trap that burned every prior attempt. Plan M2.3 via writing-plans, then execute gated.
- **DEFERRED / KNOWN (don't rediscover):** (a) GPU page production async/double-buffer = workload-dependent, do at M2.6 perf pass. `max_eager_per_frame` is the live lever (RTX 3070 min target). (b) STEEP-TERRAIN issues to design for WHEN terrain gets steep, in the RIGHT layer, gated — NOT bandaid the player: render-vs-collision surface gap (~4-5m on steep slopes; displaced mesh bilinear-samples height tex at vertex UVs vs HeightMapShape3D raw grid), collision residency vs fast movement (radius 1, async), a fast on-foot traverse control. (c) Erosion (M6) carves AAA hydraulic realism into the composed macro later.

## 4. Known deferred items (don't "rediscover" these as bugs)
- **LOD transition seams** between clipmap levels (faint shading/detail steps as you fly) — roadmap-deferred **geomorph** polish. Not a crack, not z-fighting. Don't fix piecemeal (that's slop); it's a dedicated later pass. (Human confirmed 2026-06-06: still slightly present — fine to fix later.)
- **Far-edge streaming pop-in** (human-spotted 2026-06-06): at the loaded-world frontier, new pages can be seen *appearing* rather than dissolving into the depth fog as you fly outward. Distinct from the LOD detail-step (#above) and from the startup hitch (#below) — this is the *moving streaming frontier* showing through. Likely fog-vs-reach tuning (the coarsest edge isn't fully hidden) and/or pages produced inside the visible, non-fogged range under motion. Deferred polish (same family as async-load / fog tuning); M1's gate is "no black, no cracks" — both hold, this is far-edge LOD softness. Fix later, not piecemeal.
- **~150 ms one-time startup hitch** while the 6-level clipmap + GPU pipeline warm up — a *load* transient, not movement stutter. Proper fix is async page production / loading screen, later.
- **`show_page_tint`** debug checkerboard exists on `world_view` (default off).

## 5. The gotchas that will bite a fresh session (all in `01_TOOLCHAIN.md`, but here too)
- Build with `$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"` first, or the `.gdextension` won't find the dll (a global CARGO_TARGET_DIR points elsewhere).
- **GPU tests can't run `--headless`** (no RenderingDevice) — use `--rendering-driver vulkan`.
- **The open editor locks `wg13.dll`** → `cargo build` fails. Close it (or `run.ps1 -Stop`) before rebuilding. GDScript/shader-only changes need no rebuild.
- Godot exe: `C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64(_console).exe`. Use `_console` for stdout (gate PASS/FAIL); plain for the visible window.
- Commit messages: keep ASCII, write via a temp file (`git commit -F`) — here-strings with leading `/` or special chars have broken commits before.

## 6. How to recover "the feel" fast
- Skim the last 5 `DRIFT_LOG.md` entries — they show *how* recent problems were reasoned through (the annulus z-fight, the frame-time measurement lesson, the reverted eager-cap). That narrative IS the judgment to re-absorb.
- Run the 6 gates (one command loop in CODE_MAP) — green gates confirm the foundation is solid and you can trust it.
- Launch `run.ps1` and look. Seeing it working re-grounds you faster than reading.
- Then take the next gated step. Don't try to hold the whole project in your head — hold the *method* and the *current step*.
