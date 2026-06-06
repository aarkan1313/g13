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
                                This is what demo.tscn runs.
    fly_camera.gd               Reusable WASD + right-drag inspection camera.
  scenes/
    demo.tscn                   The launch target: WorldRoot + world_view. F5 = fly.
  tests/                        GATES (PASS/FAIL, exit code). See "Running gates".
    m1_2_field_check.gd         determinism + continuity (GPU readback)
    m1_4_seam_check.gd          adjacent-page edge equality + teeth check
    m1_5a_pool_check.gd         pool caching + bounded-per-frame + budget reset
    m1_5b_stream_check.gd       streaming invariants: pins honored, eviction, flat memory
    m1_5c_coverage_check.gd     never-black: coarse blanket covers starved fine cells
    m1_5c_overlap_check.gd      annulus: no visible coarse overlaps covered fine (no z-fight)
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
| m1_5b_stream_check.gd | M1.5b | no pinned page evicted; eviction happens; residency bounded |
