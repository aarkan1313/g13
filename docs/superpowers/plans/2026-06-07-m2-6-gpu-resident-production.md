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

- **RESEARCH FINDINGS (2026-06-07, before spike) — main-device compute rules differ from our local-device path:**
  - **No `submit()`/`sync()` on the main device** — it errors ("Only local devices can submit and sync"). Auto-barriers order compute→draw. This is what removes our stall (good), but means production is no longer a synchronous "dispatch and get the texture back now" call.
  - **Main-device RenderingDevice calls must run on the RENDER thread** via `RenderingServer::call_on_render_thread(callable)`, NOT the main game thread (unsafe under the multi-threaded render model). => GPU-resident production is inherently DEFERRED: enqueue on the render thread; the texture fills in shortly after. `world_view._process` can't call produce() and get a ready texture in the same line. Task 1.1 MUST be designed around render-thread-deferred production (the page shows its coarse blanket until its render texture is filled — fits never-black).
  - **`Texture2DRD` does NOT auto-free its RID** (confirmed leak). Reinforces Stage 3.
  - **Don't swap `set_texture_rd_rid` from a render-thread callback mid-frame** (invalidates uniform sets); create the Texture2DRD / set material params on the main thread.
  - **Confirmed gdext names:** `godot::classes::Texture2Drd` (lowercase d), `set_texture_rd_rid(Rid)`; `rendering_device::TextureUsageBits::{SAMPLING_BIT, STORAGE_BIT, CAN_COPY_TO_BIT}`; `DataFormat::{R32_SFLOAT, R32G32B32A32_SFLOAT}`; `UniformType::IMAGE` (storage image, GLSL `image2D` + `imageStore`); `rd.free_rid(rid)`.
  - **UNCONFIRMED (spike must resolve in code):** `get_rendering_device()` return type (Option<Gd<>> vs Gd<>); `texture_create` arity / `_ex` builder for the data param; `BarrierMask::COMPUTE` path; empty-`Rid` spelling.
  - Reference: Godot official compute/texture/water_plane demo is the canonical example of this exact pattern.

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

### Task 1.0 RESULT (2026-06-07): SPIKE PASSED — path proven, API resolved

The throwaway spike compiled and the capture showed the compute-written gradient+
stripe pattern rendering on a mesh via `Texture2Drd` with NO readback. Confirmed in
real compiling code (resolving the prior UNCONFIRMED items):
- `RenderingServer::singleton().get_rendering_device()` -> `Option<Gd<RenderingDevice>>`.
- `rd.texture_create(&tf, &view)` is the **2-arg** form (no data param).
- Main-device compute: `compute_list_begin/bind/dispatch/end` with **NO submit()/sync()**
  works; auto-barriers order compute->draw. (Ran from a single-threaded test scene on
  the main thread without error; the live runtime may need `call_on_render_thread` if
  the project's render thread model is multi-threaded — verify in Task 1.1.)
- `RdTextureFormat`: `set_format(DataFormat::R32G32B32A32_SFLOAT)`, `set_texture_type(
  TextureType::TYPE_2D)`, `set_width/height(u32)`, `set_depth(1)`, `set_array_layers(1)`,
  `set_mipmaps(1)`, `set_usage_bits(TextureUsageBits::SAMPLING_BIT | STORAGE_BIT |
  CAN_COPY_TO_BIT)`. `RdTextureView::new_gd()` default.
- Storage-image uniform: `RdUniform` `set_uniform_type(UniformType::IMAGE)`, `add_id(rid)`;
  GLSL `layout(set=0, binding=0, rgba32f) uniform image2D; imageStore(...)`.
- `Texture2Drd::new_gd()` + `set_texture_rd_rid(rid)`; bind via `set_shader_parameter`.
- `Rid::Invalid` is the empty-RID spelling; `rd.free_rid(rid)` frees (no auto-free).
Spike files were deleted (throwaway); finding recorded here + in DRIFT_LOG.

### Task 1.1: Produce the real field render textures on the main device

**Only after Task 1.0 proves the path.** (Task 1.0 PASSED — see above. Expand the
bite-sized steps below using the resolved API before implementing.) Detailed steps for this task will be written once the spike confirms the exact working API (the spike removes the current API uncertainty). At minimum it will: add a main-device field-compute path in `field_gpu.rs` (or a new `field_gpu_resident.rs`) that runs `field_height.glsl` writing height/climate/normal into RD storage-images; expose per-page `Texture2DRD`s from `PagePool`; bind them in `world_view.gd`'s `_make_page_instance` in place of the ImageTextures for RENDERING; KEEP the existing local-device readback feeding collision unchanged. Gate: `m2_6_burst_perf_check` median-of-maxes beats the Stage 0 baseline; `m1_4`/`m1_7c`/`m2_1`/`m2_2`/`m2_3` PASS; human feel-check (smooth, seam gone, shape unchanged).

**EXPANDED (post-spike). Render-thread decision (pillar call 2026-06-07): produce
inline on the main thread (project is Single-Safe; the spike proved it). Escalation
trigger: if the live runtime throws RD threading errors or shows glitches, switch
that dispatch to `RenderingServer::call_on_render_thread`. Production STAYS
synchronous (produce() returns ready textures) — preserves the pool/view/M1.7
contract. Collision keeps the EXISTING local-device readback unchanged this stage;
Stage 2 trims it. So Stage 1.1 temporarily does BOTH paths — the win is render no
longer syncs/reads back.**

File structure for Stage 1.1:
- New `rust/gdext/src/render_gpu.rs` — owns the MAIN RenderingDevice, compiles the
  field shader once, and per page produces the 4 render textures as main-device RD
  textures (height R32F, climate RG32F, biome R32F, normal RG32F), returning their
  RIDs. Mirrors `field_gpu.rs` but: main device, no sync/readback, outputs storage
  images instead of a readback buffer. The field GLSL is shared (one source).
- `field_height.glsl` — add storage-image outputs (or a second entry/variant) so the
  same field math can write to images for the render path. Keep the buffer-output
  path for the collision/oracle (local device).
- `page_pool.rs` — `ResidentPage` gains the render RD-texture RIDs + their
  `Texture2Drd` wrappers; `request_*` return `Gd<Texture2Drd>`; the getters return
  the render `Texture2Drd`s. Keep `heights` (collision) from the existing local path.
- `world_view.gd` — bind the `Texture2Drd`s to materials (same uniform names).
- `ring_displace.gdshader` — unchanged sampler uniforms; it already samples
  height_tex/climate_tex/biome_tex; they're now Texture2DRD-backed. (Verify a
  vertex-stage `texture()` works on a Texture2DRD — the spike used fragment; if
  vertex sampling of Texture2DRD has issues, that's a finding to handle.)

- [ ] **Step 1: GLSL — add image outputs.** In `field_height.glsl`, add `layout(...,
  rgba32f/r32f) uniform image2D` outputs and `imageStore` the same h/climate/biome/
  normal values currently written to the buffer, guarded so the SAME shader can run
  either the buffer path (collision/oracle) or the image path (render) — e.g. a
  `params.output_mode` uint (0=buffer, 1=images) branch, or a `#define`. Keep buffer
  output byte-identical for mode 0 (M1.7/gates).
- [ ] **Step 2: Build + run m1_4/m2_3 to confirm the buffer path is unchanged** (mode
  0 still bit-identical). Commit GLSL.
- [ ] **Step 3: render_gpu.rs — main-device producer.** Implement per the spike's
  proven API: get main RD, create the 4 RD textures (usage SAMPLING|STORAGE|
  CAN_COPY_TO), bind as IMAGE uniforms, dispatch the field shader in image mode, NO
  sync/readback, return the RIDs. Build.
- [ ] **Step 4: page_pool — wire render textures.** ResidentPage holds the render RIDs
  + Texture2Drd wrappers; produce() calls render_gpu for the render textures AND still
  calls the local field_gpu for the collision `heights` (unchanged). request_*/getters
  return the Texture2Drd. Build.
- [ ] **Step 5: world_view — bind Texture2Drd.** Update `_make_page_instance` to accept/
  bind the Texture2Drd render textures (height for displacement, climate/biome/normal).
- [ ] **Step 6: Run the burst perf gate.** Expect median-of-maxes well below the ~47ms
  baseline (render no longer syncs/reads back). Record the number.
- [ ] **Step 7: Run the full gate suite** (m1_4, m1_5c, m1_6, m1_7c, m2_1, m2_2, m2_3) —
  all PASS. Heights/collision intact (still from the local path).
- [ ] **Step 8: Human feel-check + capture.** Launch; fly low + fast: smooth (no burst
  hitch), seam still gone, shape unchanged, climate/biome view modes (V) still correct.
  Self-verify in a capture first.
- [ ] **Step 9: Commit Stage 1.1** with before/after burst numbers.

> **Note for the executor:** this stage is large. If any step reveals the render-
> thread inline approach fails live (threading errors/glitches), STOP and switch that
> dispatch to call_on_render_thread (the pre-declared escalation), don't stack hacks.
> If Texture2DRD can't be sampled in the VERTEX stage (height displacement needs it),
> that's a real blocker — report it; a fallback is keeping height as a readback/
> ImageTexture while climate/biome/normal go GPU-resident (still a big win, since
> height is 1 of 4 and the normal/climate are the seam/perf-relevant ones).

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
