# Code Map — what's where, what runs what, how to run a gate

**Status:** living index of the implementation. Update it when files are added/moved/removed.
**Why:** so the next session (human or agent) knows what's live, what each file does, and how to run every gate — without reverse-engineering the tree. Pairs with `01_TOOLCHAIN.md` (the commands) and `PROGRESS.md` (where we are).

---

## Layout

```
rust/gdext/src/
  lib.rs            WorldRoot node + extension entry; registers modules.
  field_gpu.rs      THE ONE place that runs the field on the GPU: compile shader,
                    dispatch a page, read back. Shared by the two classes below
                    so there's no duplicated field code (00 §4).
  field_compute.rs  FieldCompute (RefCounted) — test oracle over field_gpu.
                    produce_page / produce_page_texture. Used by the M1.2/M1.4 gates.
  page_pool.rs      PagePool (RefCounted) — the runtime: bounded production,
                    page cache by (level,gx,gz), pins, eviction. Over field_gpu.
                    Each resident page caches the height texture AND the CPU height
                    array it was packed from (ResidentPage); get_page_heights()
                    returns that same array for collision (M1.7, 00 §2.2) — no
                    re-dispatch, no readback, can't drift from the view. M2.1: the
                    page ALSO carries ONE climate_tex (RG32F: R=temperature,
                    G=moisture, same production); get_page_climate_tex() exposes it
                    to the view. M2.2: ALSO a biome_tex (R32F id) + the biome array;
                    get_page_biome_tex/get_page_biome expose them; biome roster +
                    weights are DATA (BIOME_CENTROIDS) pushed to the GPU in
                    initialize(). configure_climate() tunes the climate model.
                    Height path is unchanged (additive).
  field_gpu.rs (+)  dispatch_page produces [height,temp,moisture,biome] in ONE
                    dispatch (FIELD_CHANNELS=4, interleaved) and returns a
                    deinterleaved FieldPage{heights,temp,moisture,biome}. heights is
                    byte-identical to the M1 single-channel output (M1.7 intact).
                    Pushes the biome centroid table (binding 2, BIOME_STRIDE=4:
                    temp_c/moist_c/alt_c/_pad) via set_biome_centroids. (M2.4 will
                    add the per-archetype spectral params here.)

rust/dem_distill/                OFFLINE tool (M2.3) — separate workspace member, a
                    [[bin]], NOT linked into wg13.dll (the runtime never opens a
                    .tif, 03_DEM_CATALOG hard rule). Reads the 135 labeled DEM tiles
                    and emits wg-13/data/dem_fingerprints.json (~3.5 KB). Modules:
  src/archetype.rs  filename -> 1 of 12 archetypes (+ folds). Pure, unit-tested.
  src/sidecar.rs    parse .tif.json (bounds required; width/height OPTIONAL — dims
                    come from the .tif).
  src/analyze.rs    cos(lat) metre spacing; slope_p95; radial amplitude spectrum
                    (Hann + 2D FFT via rustfft, 8 log bands, normalized); ridge
                    character (mean |Laplacian|/range). Unit-tested on synthetic data.
  src/fingerprint.rs  per-archetype Accum -> Fingerprint{spectrum,slope_p95,
                    ridge_character}; serialize to JSON.
  src/main.rs       walk dir -> read+analyze each tile -> aggregate -> write JSON.
  tests/fingerprints_sane.rs  M2.3 GATE: output sane + mountain steeper than grassland.
                    Run: cargo run --release -p dem_distill -- <opentopo_dir> <out.json>

wg-13/                          (the Godot project, res://)
  project.godot                 Vulkan; main_scene = scenes/demo.tscn.
  wg13.gdextension              points at rust/target/{debug,release}/wg13.dll.
  shaders/
    field_height.glsl           THE FIELD (compute): world-space fBM height page
                                + M2.1 climate (temp + moisture) + M2.2 biome id
                                (nearest-centroid over temp/moist/macro-altitude),
                                ALL in the SAME dispatch. Output [h,t,m,biome]/cell
                                interleaved. macro_altitude = a continental low-freq
                                landform (NOT detailed height) so biomes stay
                                contiguous at every LOD. M2.3: height = shared base
                                landform + per-biome detail (detail_amp/detail_rough
                                from the table) -> mountains rugged, plains flat,
                                borders continuous (no cliff). Biome table at binding
                                2 (2 vec4/biome). Source of truth (00 §2.1).
    ring_displace.gdshader       PRESENTS a height page: displaces a plane, shades.
                                view_mode uniform: 0 normal / 1 temperature /
                                2 moisture / 3 BIOME. Tints by climate_tex (RG32F:
                                .r=temp .g=moist) or biome_tex (R32F id, nearest
                                filter). Distinct palettes (temp=thermal blue->red;
                                moist=earth brown->blue; biome=BIOME_COLORS table
                                matching the Rust roster by index). Only reads/draws.
  scripts/
    world_view.gd               LIVE view: owns PagePool, multi-level clipmap,
                                camera-following streaming, never-black layering.
                                M2.1: V cycles view_mode (normal/temperature/
                                moisture), pushed to all page materials; binds each
                                page's climate textures from the pool.
                                Also builds NEAR (level-0) collision (M1.7):
                                WorkerThreadPool packs a HeightMapShape3D from the
                                pool's resident heights off-thread -> deferred
                                add_child; bodies evict with the ring. This is
                                what demo.tscn runs.
    fly_camera.gd               Reusable WASD + right-drag inspection camera.
    player_capsule.gd           DEMO test character (M1.7c): CharacterBody3D
                                capsule. F = fly, G = walk (drop + gravity + WASD).
                                Walk: Space = jump, Shift = sprint. (Fly: Space =
                                rise, C = descend, Shift = boost — fly_camera.gd.)
                                Walk/fly are mutually exclusive (no input bleed);
                                spawns just above resident terrain (no fresh-page
                                fall-through). `auto_move` hook lets the auto-tour
                                drive it without faking OS input. Drops out clean.
    perf_hud.gd                 DEMO dev tool: top-right perf/diagnostics HUD.
                                True per-frame delta -> fps/ms + p99/max (amber
                                over budget); streaming (pages/bodies/made/evict),
                                M1.9 profiler (prod ms + fine/eager churn, view ms,
                                mesh ms), position, memory/VRAM. Label rebuilt at
                                update_hz (~5/s), not per frame -> no perf cost.
                                H = toggle all; 1-5 = toggle sections. Read-only.
    auto_tour.gd                DEMO dev tool: data-driven auto-tour. `tour` is a
                                list of {action,...,secs} step dicts (edit rows to
                                change it); each action is a small fn. Drives the
                                EXISTING rigs (fly-cam + player auto_move), not a
                                parallel mover. T toggles; any movement input or T
                                PAUSES + hands you control; T resumes. Starts OFF.
  scenes/
    demo.tscn                   The launch target: WorldRoot + View + Player +
                                PerfHUD + AutoTour. F5 = fly.
                                CONTROLS — Fly: WASD move, right-drag look, Space
                                rise, C descend, Shift boost, wheel speed. Walk
                                (press G; F back to fly): WASD, Space jump, Shift
                                sprint. HUD: H toggle, 1-5 sections. Tour: T toggle.
                                M2.1: V cycles view mode (normal/temp/moisture).
  tests/                        GATES (PASS/FAIL, exit code). See "Running gates".
    m1_2_field_check.gd         determinism + continuity (GPU readback)
    m1_4_seam_check.gd          adjacent-page edge equality + teeth check
    m1_5a_pool_check.gd         pool caching + bounded-per-frame + budget reset
    m1_5b_stream_check.gd       streaming invariants: pins honored, eviction, flat memory
    m1_5c_coverage_check.gd     never-black: coarse blanket covers starved fine cells
    m1_5c_overlap_check.gd      annulus: no visible coarse overlaps covered fine (no z-fight)
    m1_7a_heights_check.gd      get_page_heights == texture bytes (same source), matches FieldCompute, empty if non-resident
    m1_7b_collision_check.gd    drives the real view: level-0 collision body exists, shape map_data == pool heights, page-centre transform + cell_spacing scale, near-pages-only count
    m1_7c_stand_check.gd        loads demo.tscn, drops the capsule in WALK, asserts it doesn't fall through + is_on_floor on the terrain (output-provable core of the visual gate)
    m1_9b_eager_spread_check.gd never-black holds when mid-coarse eager is bounded+starved (every fine cell covered by some resident level; coarsest floor complete) — earns M1.9.3b
    m2_1_climate_check.gd       (M2.1) climate determinism + range [0,1] + low-freq smoothness (anti-confetti) + latitude gradient, on the real GPU readback
    m2_2_biome_check.gd         (M2.2) biome determinism + valid ids [0,N) + contiguity (low adjacent-differ, no confetti) + global variety + seed sensitivity
    (M2.3's gate is Rust-side: rust/dem_distill/tests/fingerprints_sane.rs — not a Godot gate. The abandoned m2_3/m2_3b hand-noise gates were removed in the DEM-spectral replan.)
    hud_smoke_check.gd          (smoke) perf HUD loads, finds the view, all sections show sane values matching the pool, toggles work
    tour_smoke_check.gd         (smoke) auto-tour starts OFF, drives the real fly-cam, advances steps, pause restores control, resume works
  data/
    dem_fingerprints.json       (M2.3 OUTPUT, committed, ~3.5 KB) per-archetype spectrum + slope_p95 + ridge_character. M2.4's field reads this. Produced by rust/dem_distill.
  captures/                     SCREENSHOT TOOLS (evidence, not gates).
    stream_capture.gd           fly the world_view, save _captures/streamed.png
    climate_capture.gd          (M2.1) high wide vantage, save _captures/climate_{normal,temperature,moisture}.png — evidence for the parked visual gate
    shape_capture.gd            LOW-altitude shape captures (for M2.4's visual gate — mountains rugged vs plains flat)
  _captures/                    PNG output — gitignored scratch (regenerable).

run.ps1                         Launcher: agent runs the windowed scene on the user's
                                desktop via a PS Job (.\run.ps1 / .\run.ps1 -Stop).
```

## Conventions (follow these going forward)

- **One live view.** `world_view.gd` is *the* view; demo.tscn runs it. When a step changes the view, edit `world_view.gd` — don't fork `m1_X_view.gd` copies. (We deleted the M1.3/M1.4 forks for exactly this reason.) Old behavior is recoverable from git, not from dead files.
- **`tests/` = gates only.** A file in `tests/` is a `*_check.gd` that asserts and `quit(0/1)`. If it just takes a screenshot, it belongs in `captures/`.
- **`captures/` = evidence tools.** Reusable; output goes to `_captures/` (gitignored). Gate evidence of record is the `DRIFT_LOG.md` narrative + the live scene, not the PNG.
- **No throwaway direction (00 §1.1).** A new file should be something later steps build on, not replace. If you'd delete it next step, don't write it.
- **Rust owns runtime + policy; GLSL owns world math; GDScript assembles only** (00 §4). No CPU copy of the field; no terrain decisions in GDScript.
- **GPU dispatch lives only in `field_gpu.rs`.** New consumers (collision sampling, etc.) use FieldGpu — they don't re-implement dispatch.

## Running gates

All GPU gates need a real driver (NOT `--headless` — see `01_TOOLCHAIN.md §4`):
```powershell
$g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/<name>.gd
# PASS/FAIL printed; exit code 0 = pass.
```
Build first (note the local target-dir override, `01_TOOLCHAIN.md §1`):
```powershell
$env:CARGO_TARGET_DIR = "D:\world gen 13\rust\target"
cargo build --manifest-path "D:\world gen 13\rust\Cargo.toml"
```
Fly the live world: `.\run.ps1` (agent launches a windowed instance on the user's desktop via a PS Job; `.\run.ps1 -Stop` to close). The editor is only for inspector tuning or when a Rust rebuild needs the DLL lock released.

## Gate ↔ milestone

| Gate file | Milestone | Asserts |
|---|---|---|
| m1_2_field_check.gd | M1.2 | same seed→identical page; different seed differs; continuity |
| m1_4_seam_check.gd | M1.4 | adjacent E/S edges bit-identical; wrong stride doesn't (teeth) |
| m1_5a_pool_check.gd | M1.5a | cache hit on repeat; ≤ max-new/frame; budget resets |
| m1_5b_stream_check.gd | M1.5b | no pinned page evicted; eviction happens; residency bounded |
| m1_5c_coverage_check.gd | M1.5c | never-black: coarse covers fine cells starved by tight budget |
| m1_5c_overlap_check.gd | M1.5c | annulus: no visible coarse page overlaps a fully-covered fine area |
| m1_7a_heights_check.gd | M1.7a | get_page_heights returns the same array behind the texture; matches FieldCompute; empty when non-resident |
| m1_7b_collision_check.gd | M1.7b | real view builds level-0 collision; shape map_data == pool heights; page-centre transform + cell_spacing scale; near-pages-only count |
| m1_7c_stand_check.gd | M1.7c | capsule dropped in demo.tscn doesn't fall through and is_on_floor on the terrain (output-provable core; live walk is the human visual gate) |
| m1_9b_eager_spread_check.gd | M1.9.3b | bounding mid-coarse eager stays never-black: every fine cell covered by some resident level; coarsest floor complete |
| m2_1_climate_check.gd | M2.1 | climate determinism (same page+seed → bit-identical); range [0,1]; low-freq/smooth (anti-confetti); latitude gradient real |
| m2_2_biome_check.gd | M2.2 | biome determinism; valid integer ids [0,N); contiguity (low adjacent-differ); global variety; seed sensitivity |
| dem_distill/tests/fingerprints_sane.rs | M2.3 | (Rust, offline) fingerprints sane (spectra normalized, slopes/ridge in range); mountain slope_p95 >> grassland |
