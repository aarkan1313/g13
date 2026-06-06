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

## 3. Current state (update this in every handoff refresh) — refreshed 2026-06-06 (end of the M2.4 redesign session)
- **On `main`** (`github.com/aarkan1313/g13`). Tree clean. `m1-complete` tagged.
- **DONE:** M1 (streaming shell, LOD ~49km, collision, perf-hardened) + **M2.1 climate** (temp/moisture, V-toggle viz, both gates PASS) + **M2.2 biome id** (nearest-centroid Whittaker over temp/moist/macro-altitude, 10-biome roster, both gates PASS) + **M2.3 DEM distillation tool** (`rust/dem_distill`, offline binary, reads 135 DEM tiles → `wg-13/data/dem_fingerprints.json` (3.5 KB): per-archetype radial amplitude spectrum + slope_p95 + ridge character; gate PASS).
- **THE M2.4 SAGA (read so you don't repeat it):** terrain SHAPE is the hard problem and where attempts #1-12 died. This session tried, in order, and ABANDONED: (a) hand-tuned per-biome noise (M2.3 original) → "Perlin oatmeal"; (b) domain-warped ridged macro (M2.3b) → "mesa cliffs"; (c) DEM-spectral octave-sum (M2.4 spectral) → uniform terrain, no discrete ranges. ~12 iterations total. **Lesson burned in: a global noise/octave-sum CANNOT make believable landforms — it makes the same texture everywhere.** The field was reverted to the M2.2 state after each. The DEM distill tool (M2.3) survives all of it and feeds the new approach.
- **NEXT STEP: M2.4a — composition machine + MOUNTAIN recipe.** APPROACH DECIDED + SPEC WRITTEN (do NOT re-decide): adopt **WG10's proven layered composition** (read `WG10_MOUNTAIN_DEEP_DIVE.md` lines ~221-233 + "What WG13 Should Keep"). Terrain = a shared composition MACHINE (primitives: domain warp, **region envelope** [blurred low-freq mask = WHERE ranges stand up], **ridged fbm** [sharp ridgelines], **valley carve**, blend) + per-biome RECIPE functions in one `field_height.glsl`, **DEM-fingerprint-tuned**, biome-selected, **border-blended** (one dispatch, contract intact). The envelope×ridges is the missing ingredient — it concentrates relief into discrete ranges with valleys between (the octave-sum had no envelope → uniform). **DECISION: PROVE WITH 3 recipes (mountain → grassland → desert), each gated/visually-accepted, THEN schedule the rest.** Spec: `docs/superpowers/specs/2026-06-06-m2-terrain-composition-machine-design.md`. Plan M2.4a via writing-plans, then execute gated. The Rust fingerprint loader + per-biome GPU table (BIOME_STRIDE=16, carries slope_p95+spectrum) are ALREADY COMMITTED and reused — the mountain recipe just reads them; no new Rust needed for M2.4a.
- **CRITICAL PROCESS LESSON from this session (the user said so):** terrain shape is a VISUAL problem — **iterate with low-altitude captures + the user's eyes EARLY and often, not metrics.** Every failure came from trusting a gate/number while the picture was bad (gates passed on "spiky oatmeal" and "uniform rolling"). The `captures/shape_capture.gd` tool flies low over a mountain region (spot 0 = world (-32000,-16000)). Land the mountain LOOK before cloning the pattern. The user has good instincts about the terrain — surface bad results honestly, don't claim success on a green gate.
- **DEFERRED (don't rediscover):** GPU page production async/double-buffer = workload-dependent, do it at M2.6 perf pass against the REAL composed field. `max_eager_per_frame` is the live lever (RTX 3070 min target). M6 erosion later carves real hydraulic detail into the composed macro shape.

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
