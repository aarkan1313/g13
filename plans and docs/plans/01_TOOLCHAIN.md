# Toolchain & Build/Run/Test Procedure

**Status:** verified 2026-06-06 on this machine. If a command here fails, the environment drifted — fix the environment or update this doc deliberately; do not invent an alternate build path mid-step.
**Why this exists:** `02_WORKFLOW.md` gates depend on concrete, repeatable build/run/test/capture commands. M1.1's gate ("hot reload works") and M1.6's perf gate ("frame time measured, not eyeballed") are meaningless without a written procedure. This is that procedure.

---

## 1. Verified environment (this machine, 2026-06-06)

| Tool | Version / Path | Notes |
|---|---|---|
| **Godot** | `4.6.2-stable-mono` | `C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64.exe` |
| Godot (console) | same dir, `..._console.exe` | Use this for CLI runs so stdout/`print()` is visible. |
| **Rust** | `rustc 1.94.1`, `cargo 1.94.1` | On PATH. |
| **git** | `2.52.0.windows.1` | Repo root = `D:\world gen 13`. |
| Renderer | Forward+ / **Vulkan** | `project.godot` → `rendering_device/driver.windows="vulkan"`. |
| Physics | Jolt | Godot 4.6 default; fine for M1.7 collision. |

**Mono build, no C#.** The installed Godot is the Mono (.NET) build. We use it but write **zero C#** — gdext (Rust) + GDScript only. The `[dotnet]` section was removed from `project.godot` so the editor does not expect a C# solution. gdext loads through the GDExtension interface independently of the C# layer, so Mono vs standard makes no difference to our Rust path. (This refines `00_ARCHITECTURE.md §4`'s "no C#": it means no C# *scripting*, not "non-Mono build required.")

**Convenience:** the Godot exe is not on PATH. Either add it, or set once per shell:
```powershell
$env:GODOT = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64.exe"
$env:GODOT_CONSOLE = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
```

---

## 2. Project layout (target, from M1.1 on)

```
D:\world gen 13\
├─ wg-13\                     # the Godot project (res://)
│  ├─ project.godot
│  ├─ wg13.gdextension        # created M1.1 — points at the built Rust lib
│  ├─ shaders\                # GLSL: field producer (compute) + ring_displace (render)
│  ├─ scenes\                 # demo + review scenes (.tscn)
│  ├─ scripts\                # thin GDScript assembly only
│  └─ tests\                  # *_check.gd / *_capture.gd headless gate scripts
├─ rust\                      # the gdext crate (workspace)
│  ├─ Cargo.toml              # workspace
│  └─ gdext\                  # the GDExtension — depends on `godot`
│     └─ src\
│        ├─ lib.rs
│        ├─ page_pool/        # bounded residency, acquire/evict, pins
│        ├─ rings.rs          # clipmap ring geometry
│        ├─ terrain_view.rs   # read-only view over resident pages
│        └─ field_compute.rs  # dispatches the GLSL producer; readback for tests
└─ plans and docs\...
```
**Boundary made physical (`00 §2`):** the world math lives in **`wg-13/shaders/` GLSL**, the only implementation of the field. Rust dispatches it and owns scheduling/residency/view/tests; Rust never re-implements the world math on the CPU. The render shader (`ring_displace`) only presents pages — it is not a terrain generator. If a CPU copy of the field math appears in `rust/`, that's the "two worlds" violation; STOP and log it.

---

## 3. The build/run loop

### Build the Rust extension (debug)
```powershell
cargo build --manifest-path "D:\world gen 13\rust\Cargo.toml"
```
The compiled `.dll` lands in `rust\target\debug\`. The `wg-13\wg13.gdextension` manifest points at it per-platform. (Release: add `--release`, manifest references `target\release\`.)

### Run the demo scene (visible console)
```powershell
& $env:GODOT_CONSOLE --path "D:\world gen 13\wg-13"
```

### Hot reload (the tuning loop — M1.1 gate)
gdext supports hot reload. The loop is: edit Rust → `cargo build` → Godot picks up the rebuilt `.dll` without an editor restart. **M1.1's gate is verifying exactly this works:** change a `print!` string, rebuild, see the new string without restarting the editor.

---

## 4. Tests (test gates — agent can self-certify)

### Field determinism/seam tests (Rust drives the real GPU compute, reads back)
```powershell
cargo test --manifest-path "D:\world gen 13\rust\Cargo.toml"
```
These exercise the **real compute path** (`00_ARCHITECTURE.md §2.1`): Rust spins up a `RenderingDevice`, runs the field GLSL over a page, reads it back, and asserts determinism (same seed → identical bytes), continuity, and adjacent-page edge equality (M1.2, M1.4). The GPU output is the oracle — there is no CPU field to compare against. Note: these need a GPU/RenderingDevice available, so they are not pure-CPU unit tests; on a headless agent box confirm a usable device or run them via the headless Godot path below.

### Godot-side tests (headless)
For gates that need the engine (e.g. a scene loads, a mesh has N vertices), run a GDScript check headless and exit:
```powershell
& $env:GODOT_CONSOLE --headless --path "D:\world gen 13\wg-13" --script res://tests/<name>_check.gd
```
The `_check.gd` script asserts, `print("PASS"/"FAIL ...")`, and calls `get_tree().quit(code)`. PASS/FAIL is the gate. (Pattern carried from WG10's `*_check.gd`.)

---

## 5. Visual capture (so "park for visual" produces evidence)

`02_WORKFLOW.md` requires the agent to PARK at visual gates for the human to eyeball. The agent should still produce a **screenshot artifact** so the human can review without re-launching. Procedure (carried from WG10's `*_visual_capture.gd`):

- A capture script positions a fixed camera/light, lets the scene settle a few frames, then `viewport.get_texture().get_image().save_png("res://_captures/<gate>.png")` and quits.
- Run headless or windowed:
  ```powershell
  & $env:GODOT_CONSOLE --path "D:\world gen 13\wg-13" --script res://tests/<gate>_capture.gd
  ```
- The agent writes the PNG path into `DRIFT_LOG.md` alongside the PARKED-FOR-VISUAL entry. The human opens the PNG, marks pass/fail.

This keeps visual gates first-class (a `WG10_MOUNTAIN_DEEP_DIVE.md` "What WG13 Should Keep" rule) without the agent ever self-certifying them.

> Note: a saved PNG is the baseline. Hot-reload tuning and final 60-FPS feel still need a live human session — the capture is evidence, not a substitute for the desk pass.

---

## 6. Performance measurement (M1.6 perf gate)

The M1.6 test gate ("frame time < budget while flying across many chunk loads") must be **measured, not eyeballed**:
- A fly-path script moves the camera along a fixed route at fixed speed, samples `Performance.get_monitor(Performance.TIME_PROCESS)` / `TIME_FRAME` each frame, records max + 99th-percentile frame time, prints PASS if under budget (16.6 ms) else FAIL with the worst frame.
- **Target hardware must be named when M1.6 is reached** (the docs currently say "midrange PC" without specifics — pin it down before relying on the number). Until then, record the dev-machine number as a baseline, not as the gate pass.

---

## 7. Open verification items (resolve at the step that needs them)
- **gdext version pin:** `00_ARCHITECTURE.md` claims "v0.5+". Pin the exact `godot` crate version in `rust/gdext/Cargo.toml` at M1.1 and confirm `compatibility_minimum = 4.2` loads in 4.6.2. Log the resolved version back into §1 here.
- **Target hardware for 60 FPS:** undefined in the milestone docs. Name it before M1.6.
