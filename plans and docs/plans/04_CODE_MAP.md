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
                    Each resident page caches the texture AND the CPU height
                    array it was packed from (ResidentPage); get_page_heights()
                    returns that same array for collision (M1.7, 00 §2.2) — no
                    re-dispatch, no readback, can't drift from the view.

wg-13/                          (the Godot project, res://)
  project.godot                 Vulkan; main_scene = scenes/demo.tscn.
  wg13.gdextension              points at rust/target/{debug,release}/wg13.dll.
  shaders/
    field_height.glsl           THE FIELD (compute): world-space fBM height page.
                                Source of truth (00 §2.1). Sampled in world coords.
    ring_displace.gdshader       PRESENTS a height page: displaces a plane, shades.
                                Not a generator (00 §4).
  scripts/
    world_view.gd               LIVE view: owns PagePool, multi-level clipmap,
                                camera-following streaming, never-black layering.
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
                                sprint. HUD: H toggle, 1-4 sections. Tour: T toggle.
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
    hud_smoke_check.gd          (smoke) perf HUD loads, finds the view, all sections show sane values matching the pool, toggles work
    tour_smoke_check.gd         (smoke) auto-tour starts OFF, drives the real fly-cam, advances steps, pause restores control, resume works
  captures/                     SCREENSHOT TOOLS (evidence, not gates).
    stream_capture.gd           fly the world_view, save _captures/streamed.png
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
| m1_5b_stream_check.gd | M1.5b | no pinned page evicted; eviction happens; residency bounded |
