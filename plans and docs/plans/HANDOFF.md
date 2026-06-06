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

## 3. Current state (update this in every handoff refresh)
- **As of commit `1a12331`** (pushed to `github.com/aarkan1313/g13`, `main`). Tree clean.
- **Done: M1.1–M1.6.** Skeleton+hot-reload, GPU field (determinism/seam tests), on-screen render, seamless page tiling, full streaming shell (bounded pool, camera-following, annulus clipmap, never-black, no z-fight), LOD to ~49 km horizon @ ~420 fps steady-state (frame gate passing).
- **6 test gates green:** `wg-13/tests/m1_{2,4,5a,5b,5c_coverage,5c_overlap,6_frametime}_check.gd` (run via vulkan, see CODE_MAP).
- **NEXT STEP: M1.7 — collision.** Generate `HeightMapShape3D` for **near pages only**, async/off-main-thread, reading the **same resident page heights** the view uses (never a second field path). Gate: a character stands on the terrain anywhere, including freshly-streamed pages, without falling through. Then M1.8 (run full DoD, tag `m1-complete`).
- **Then M2** (biomes + DEM stats; 135 labeled DEMs already inventoried in `03_DEM_CATALOG.md`).

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
