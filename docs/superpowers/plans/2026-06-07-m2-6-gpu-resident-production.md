# M2.6 GPU-Resident Production — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the streaming-burst frame hitch by making page rendering GPU-resident (no per-page CPU readback/re-upload), keeping CPU readback only for near-collision pages — so streaming is as smooth as stationary on the RTX 3070.

**Architecture:** Split the single produce path into (a) a render path that produces height/climate/normal into GPU textures sampled directly by materials via `Texture2DRD` (no `rd.sync()`/readback for rendering), and (b) a collision path that reads back the height channel only for level-0 pages within `collision_radius`. Staged: perf gate first, then render GPU-resident, then trim collision readback, then RID-lifetime + VRAM gate. Collision (safety-critical) is touched last.

**Tech Stack:** Godot 4.6.2, Rust gdext, GLSL compute (`field_height.glsl`), `Texture2DRD` (4.6), GDScript gates. GPU work needs `--rendering-driver vulkan` (never `--headless`). Build with `$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"`; close the running world before `cargo build` (DLL lock). Commit on `main` (project norm) via `git commit -F` (ASCII).

---

## CRITICAL CONTEXT — read before any task

- **The dominant cost is the per-page synchronous GPU round-trip** (`dispatch_page`: `rd.sync()` ~130us + `buffer_get_data` ~130us, then 4 ImageTexture builds ~224us), serialized in burst frames. Measured this session via split timing.
- **The steady-state `m1_6_frametime_check` gate NEVER bursts** (fixed-direction 900 u/s) so it shows ~1.4ms p99 while a turbo+jump burst shows p99 ~26ms / max ~43ms. The current gates are BLIND to this. Stage 0 fixes the measurement.
- **`FieldGpu` runs on a LOCAL RenderingDevice** (`RenderingServer::create_local_rendering_device()`). A texture on the local device is NOT sampleable by the main draw. GPU-resident rendering requires producing render textures on the **main** device (`RenderingServer::get_rendering_device()`) and wrapping them in `Texture2DRD`.
- **`Texture2DRD` (verified present in Godot 4.6):** `set_texture_rd_rid(rid)` assigns an RD texture RID; the object is a `Texture2D` a `ShaderMaterial` can sample. RD textures are **NOT ref-counted** — they must be freed manually (`rd.free_rid`) on evict or VRAM leaks.
- **M1.7 collision contract (MUST preserve):** the `HeightMapShape` reads a CPU `heights` array that is byte-identical to what the field produced. Collision is built only for level-0 pages within `collision_radius`, async via WorkerThreadPool.
- **Never-black (MUST preserve):** coarse pages form the blanket under un-loaded fine pages; eviction must never remove a displayed page out from under the mesh.
- **Uncertain API surface:** the exact gdext Rust calls for creating a sampleable RD texture on the MAIN device and binding it to a material via `Texture2DRD` are NOT yet verified in code. Stage 1 therefore STARTS with a minimal proof-of-concept spike (Task 1.0) that must work before the full render-path rewrite. Do NOT write the full rewrite before the spike proves the path.

---

## Stage 0 — Reliable burst perf gate (DO FIRST; nothing else ships without it)

A deterministic, low-noise burst gate so stages 1–3 are measurable. Single runs were too noisy (same build varied 3–25 over-budget frames); this repeats the burst and reports a stable aggregate.

### Task 0.1: Deterministic burst perf gate

**Files:**
- Create: `wg-13/tests/m2_6_burst_perf_check.gd`

- [ ] **Step 1: Write the gate.** Create `wg-13/tests/m2_6_burst_perf_check.gd`:

```gdscript
extends SceneTree
# M2.6 gate — BURST streaming frame time (what the steady-state m1_6 gate misses).
# Drives DETERMINISTIC turbo motion + periodic big jumps to fresh regions so many
# pages are produced in single frames (the felt hitch). Repeats the burst REPEATS
# times and reports the aggregate worst sustained frame, so it's stable enough to
# A/B a perf change (single runs were too noisy). Uses a FIXED per-frame step (not
# dt) so timing variance doesn't move WHERE we sample.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_6_burst_perf_check.gd

const VIEW := preload("res://scripts/world_view.gd")
const WARMUP := 120
const MEASURE := 240
const REPEATS := 3
const TURBO_STEP := 250.0     # world units/frame (~15000 u/s @ 60) -> heavy bursts
const JUMP_EVERY := 40
const JUMP_DIST := 8000.0
const BUDGET_MS := 16.6

var _root: Node3D
var _f := 0
var _rep := 0
var _jumps := 0
var _all_samples := []        # frame times across ALL repeats
var _rep_maxes := []          # worst frame per repeat
var _cur := []

func _init() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_root = Node3D.new()
	_root.set_script(VIEW)
	get_root().add_child(_root)

func _process(_dt: float) -> bool:
	_f += 1
	var cam := get_root().get_viewport().get_camera_3d()
	if _f <= WARMUP:
		return false
	if cam:
		cam.global_position += Vector3(TURBO_STEP, 0.0, -TURBO_STEP)
		if _f % JUMP_EVERY == 0:
			_jumps += 1
			cam.global_position += Vector3(JUMP_DIST * float(_jumps), 0.0, JUMP_DIST * 0.5 * float(_jumps))
	var ms := _dt * 1000.0
	_cur.append(ms)
	_all_samples.append(ms)
	if _cur.size() >= MEASURE:
		_cur.sort()
		_rep_maxes.append(_cur[_cur.size() - 1])
		_cur = []
		_rep += 1
		_f = WARMUP        # re-warm between repeats (keep streaming, reset counter window)
		if _rep >= REPEATS:
			_report()
			return true
	return false

func _report() -> void:
	_all_samples.sort()
	var n := _all_samples.size()
	var p999: float = _all_samples[mini(int(n * 0.999), n - 1)]
	var p99: float = _all_samples[mini(int(n * 0.99), n - 1)]
	var p50: float = _all_samples[n / 2]
	# Stable worst metric: MEDIAN of the per-repeat maxes (robust to one unlucky run).
	_rep_maxes.sort()
	var med_max: float = _rep_maxes[_rep_maxes.size() / 2]
	var over := 0
	for s in _all_samples:
		if s > BUDGET_MS: over += 1
	print("M2.6 BURST perf, %d repeats x %d frames:" % [REPEATS, MEASURE])
	print("  median %.2f | p99 %.2f | p99.9 %.2f ms | median-of-maxes %.2f ms | frames>16.6: %d/%d" % [
		p50, p99, p999, med_max, over, n])
	# This gate is a MEASURING STICK + regression guard, not a hard pass/fail on an
	# absolute number yet (the M2.6 stages drive med_max down). Fail only on a gross
	# regression so it can run in the suite without false alarms; the real bar is the
	# stage-over-stage improvement recorded in the plan + the human feel-check.
	var GROSS := 60.0
	if med_max > GROSS:
		print("FAIL: median-of-maxes %.2f ms exceeds gross-regression guard %.1f ms" % [med_max, GROSS])
		quit(1)
	else:
		print("PASS: burst measured (median-of-maxes %.2f ms); compare across M2.6 stages" % med_max)
		quit(0)
```

- [ ] **Step 2: Run it and record the CURRENT baseline.**

```powershell
$g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m2_6_burst_perf_check.gd
```
Expected: prints the metric line and `PASS`. RECORD the `median-of-maxes` number — this is the committed-seam-fix baseline the stages must beat. Run it 2–3 times to confirm `median-of-maxes` is stable (varies < ~20%). If it's still too noisy, raise `REPEATS` to 5 and re-baseline.

- [ ] **Step 3: Commit.**

```powershell
git add wg-13/tests/m2_6_burst_perf_check.gd
$f = "$env:TEMP/wg26_0.txt"
@'
[M2.6] stage 0: deterministic burst perf gate (the steady-state gate missed bursts)

Repeats a turbo+jump burst and reports median-of-maxes -> stable enough to A/B.
Establishes the current seam-fix baseline for stages 1-3 to beat.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@ | Out-File -FilePath $f -Encoding ascii
git commit -F $f
Remove-Item $f
```

---

## Stage 1 — GPU-resident render (starts with a proof-of-concept spike)

**The API for sampleable RD textures on the main device from gdext is not yet verified in code. Task 1.0 is a SPIKE to prove it before the rewrite.** If the spike can't be made to work after reasonable effort, STOP and escalate — do not fake the rewrite.

### Task 1.0: SPIKE — prove a compute-written texture on the MAIN device renders via Texture2DRD

**Goal:** a throwaway proof that we can (1) get the main `RenderingDevice`, (2) create an RD texture, (3) write to it from a compute dispatch on the main device, (4) wrap it in `Texture2DRD`, (5) have a `ShaderMaterial` sample it on a visible mesh — with NO `buffer_get_data`. Verify by eye in a capture.

**Files:**
- Create: `rust/gdext/src/spike_gpu_resident.rs` (throwaway; a `#[func]`-exposed test object), wired into `lib.rs`
- Create: `wg-13/tests/spike_gpu_resident_capture.gd` (places a mesh with a Texture2DRD-backed material, saves a PNG)

- [ ] **Step 1: Research the exact gdext API.** Before coding, confirm in the gdext docs / godot classes the Rust signatures for: `RenderingServer::singleton().get_rendering_device()`; `RenderingDevice::texture_create(format, view, data)` with an `RdTextureFormat` set for `USAGE_SAMPLING_BIT | USAGE_STORAGE_BIT | USAGE_CAN_UPDATE_BIT`; binding a storage-image uniform (`UniformType::IMAGE`) for the compute write; and `Texture2DRD::set_texture_rd_rid()`. Write these signatures as a comment block at the top of `spike_gpu_resident.rs` BEFORE implementing, so the approach is concrete. If any signature can't be confirmed, escalate (NEEDS_CONTEXT) rather than guess.

- [ ] **Step 2: Implement the spike object.** A `GodotClass` (RefCounted) with a `#[func] fn make_resident_texture(&mut self, res: i32, seed: f32) -> Gd<Texture2DRD>` that: gets the main RD; creates an R32F (or RGBA32F) RD texture with sampling+storage usage; compiles a TINY compute shader that writes a recognizable gradient/pattern (NOT the full field — just enough to see it); dispatches it on the main RD (no sync-for-readback needed; the texture is consumed by the GPU); wraps the RID in a `Texture2DRD` via `set_texture_rd_rid` and returns it. Keep it minimal and obviously-correct.

- [ ] **Step 3: Wire into lib.rs** (register the spike class) and build:
```powershell
$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"
.\run.ps1 -Stop
cd "D:\world gen 13\rust\gdext"; cargo build > "$env:TEMP\wg_b.txt" 2>&1; Get-Content "$env:TEMP\wg_b.txt" | Select-Object -Last 3
```
Expected: `Finished` in the log tail. (Ignore PowerShell NativeCommandError wrapping on native exe stderr — check the log tail, not `$?`.)

- [ ] **Step 4: Capture to verify by eye.** `spike_gpu_resident_capture.gd` instantiates the spike, gets a `Texture2DRD`, puts it on a `MeshInstance3D` (a PlaneMesh) with a ShaderMaterial that samples it, points a camera at it, and saves `res://_captures/spike_resident.png`. Run with `--rendering-driver vulkan`, then READ the PNG. Expected: the recognizable gradient/pattern appears on the mesh — proving compute→sampleable texture with NO readback works.

- [ ] **Step 5: Decision gate.** If the pattern renders: the path is proven — proceed to Task 1.1, and DELETE the spike files (`spike_gpu_resident.rs`, the capture, the lib.rs registration) in the Task 1.1 commit or a cleanup commit. If it does NOT render after reasonable debugging: STOP, report findings, and reconsider the approach (fall back to async-readback from the spec's out-of-scope, or seek help). Do not proceed to the rewrite on an unproven path.

- [ ] **Step 6: Commit the spike result** (so the finding is recorded even though spike code is throwaway):
```powershell
git add rust/gdext/src/spike_gpu_resident.rs rust/gdext/src/lib.rs wg-13/tests/spike_gpu_resident_capture.gd
$f = "$env:TEMP/wg26_10.txt"
@'
[M2.6] stage 1 spike: prove compute->Texture2DRD renders with no readback

Throwaway PoC: a compute pass on the MAIN RenderingDevice writes an RD texture
that a ShaderMaterial samples via Texture2DRD, no buffer_get_data. Verified by
capture. Confirms the GPU-resident render path before the full rewrite.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@ | Out-File -FilePath $f -Encoding ascii
git commit -F $f
Remove-Item $f
```

### Task 1.1: Produce the real field render textures on the main device

**Only after Task 1.0 proves the path.** Detailed steps for this task will be written once the spike confirms the exact working API (the spike removes the current API uncertainty). At minimum it will: add a main-device field-compute path in `field_gpu.rs` (or a new `field_gpu_resident.rs`) that runs `field_height.glsl` writing height/climate/normal into RD storage-images; expose per-page `Texture2DRD`s from `PagePool`; bind them in `world_view.gd`'s `_make_page_instance` in place of the ImageTextures for RENDERING; KEEP the existing local-device readback feeding collision unchanged. Gate: `m2_6_burst_perf_check` median-of-maxes beats the Stage 0 baseline; `m1_4`/`m1_7c`/`m2_1`/`m2_2`/`m2_3` PASS; human feel-check (smooth, seam gone, shape unchanged).

> **Plan note:** Task 1.1's bite-sized steps are intentionally deferred until the Task 1.0 spike resolves the API uncertainty. This is a deliberate de-risking gate, not a placeholder — writing exact rewrite code now would be guessing at unverified signatures. After the spike, return here and expand Task 1.1 into concrete steps before implementing.

---

## Stage 2 — Trim collision readback to near level-0 only

### Task 2.1: Only read back CPU heights for collision-eligible pages

**Files:**
- Modify: `rust/gdext/src/page_pool.rs` (the `produce` path + request modes)
- Modify: `wg-13/scripts/world_view.gd` if needed (it already only builds collision for level-0 within `collision_radius`)

- [ ] **Step 1:** Make `produce` skip the CPU readback + `heights` array for pages that will never get collision (everything except level-0; and optionally only level-0 within collision radius). The render path (Stage 1) no longer needs CPU heights, so coarse/far pages can produce render textures only. Keep `get_page_heights` returning a valid array for collision-eligible pages (M1.7). Concrete steps written after Stage 1 lands (the produce path shape depends on the Stage 1 split).
- [ ] **Step 2:** Gate: `m1_7c_stand_check` PASS (collision intact), `m2_6_burst_perf_check` improves further, never-black intact, human feel.
- [ ] **Step 3:** Commit.

> **Plan note:** like Task 1.1, Stage 2's exact steps depend on the produce-path shape after Stage 1. Expand into bite-sized steps once Stage 1 is committed.

---

## Stage 3 — Free RD texture RIDs on evict + VRAM-stability gate

### Task 3.1: VRAM-stability gate (write FIRST, TDD)

**Files:**
- Create: `wg-13/tests/m2_6_vram_check.gd`

- [ ] **Step 1:** Write a gate that streams a large area (drive the camera far, forcing many page produce+evict cycles) and asserts the resident texture/RID count (and/or `RenderingServer.get_rendering_info` VRAM) returns to a flat baseline after eviction — i.e. no unbounded growth. Run it BEFORE the free-on-evict code exists; expect it to FAIL (RIDs leak), proving the gate has teeth.
- [ ] **Step 2:** Run, confirm FAIL (leak detected).

### Task 3.2: Free RIDs on evict

**Files:**
- Modify: `rust/gdext/src/page_pool.rs` (eviction path)

- [ ] **Step 1:** In the page-eviction path, free each evicted page's RD texture RIDs (`rd.free_rid` on the main device) and any `Texture2DRD` references, so VRAM is reclaimed. Concrete steps after Stage 1 (depends on what RIDs a page owns).
- [ ] **Step 2:** Run `m2_6_vram_check` — expect PASS (no leak).
- [ ] **Step 3:** Run the full gate suite (`m1_4`, `m1_5c`, `m1_6`, `m1_7c`, `m2_1`, `m2_2`, `m2_3`, `m2_6_burst_perf_check`, `m2_6_vram_check`) — all PASS.
- [ ] **Step 4:** Human feel-check: long fast flight, HUD `vram` stays bounded, no hitch, seam gone, shape unchanged.
- [ ] **Step 5:** Commit.

---

## Final: docs + close

- [ ] Update `PROGRESS.md` (M2.4-perf / M2.6 line) and `DRIFT_LOG.md` with the before/after burst numbers and the human PASS.
- [ ] Remove any remaining diagnostic probes.
- [ ] Record the RTX-3070 bar as REASONED-from-headroom (dev machine is stronger), not directly measured — be explicit.

---

## Self-Review (plan author)

**Spec coverage:** Stage 0 (perf gate) ✓; Stage 1 GPU-resident render ✓ (gated behind a spike to handle the spec's acknowledged API uncertainty honestly); Stage 2 trim collision readback ✓; Stage 3 RID-free + VRAM gate ✓; acceptance + rollback discipline ✓.

**Placeholder honesty:** Tasks 0.1, 1.0, 3.1 are fully concrete (real code/commands). Tasks 1.1, 2.1, 3.2 are deliberately deferred-to-after-spike with an explicit rationale — this is a genuine de-risking decision (the exact main-device RD-texture API is unverified; writing code against unverified signatures would be the real placeholder sin). They MUST be expanded into bite-sized steps before implementing, once the spike resolves the API. This is called out at each such task.

**Type/name consistency:** gate filenames `m2_6_burst_perf_check.gd`, `m2_6_vram_check.gd` consistent; `Texture2DRD` / `set_texture_rd_rid` consistent with the spec; build/run commands consistent with project toolchain.

**Known deviation from "no placeholders":** This plan front-loads a spike instead of full code for Stage 1+ because the API is unverified. The writing-plans skill says no placeholders; the honest engineering judgment here is that a spike-gated plan is correct for an uncertain external API, and faking exact code would be worse. Flagged explicitly for the executor and the user.
