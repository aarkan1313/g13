# M2.3 — Composition Machine (general terrain structure) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. This is a SINGLE-SESSION, VISUAL-FIRST plan executed inline — the make-or-break is a human visual judgment that cannot be delegated.

**Goal:** Replace the flat M1 `fbm` height with a **composition machine** — an uplift/ruggedness field that PLACES structure (flat lowlands most places, hills, distinct mountain ranges with valleys between) composed from ridged + smooth relief and valley carving, with **hand-set character constants** — and prove it *looks* like believable varied terrain via low-altitude captures + walking, BEFORE wiring DEM data (that's M2.4).

**Status 2026-06-06:** COMPLETE. Test guardrail PASS and human visual PASS after the AABB cull fix.
**Follow-up note:** the later M2.4a DEM-character tuning path failed visual review and was backed out. Current next plan is M2.4b structural scaffold: `docs/superpowers/plans/2026-06-06-m2-4b-dem-structural-scaffold.md`.

**Architecture:** One GPU dispatch, one shader (`field_height.glsl`). The machine writes `height`; M2.1 climate + M2.2 biome are unchanged (biome stays a stats-based skin; height never feeds biome — biome uses `macro_altitude`). Height channel stays R32F for collision (M1.7). Structure comes from the **uplift field** (the thing a global octave-sum lacks); character is hand-set this step, DEM-tuned next step. No Rust change (machine is GLSL-internal, reuses existing params).

**Tech Stack:** GLSL compute, Godot 4.6.2-mono GPU readback (`--rendering-driver vulkan`), the `FieldCompute` oracle (`produce_page`/`produce_biome_page`), a ground-aware low-capture tool, `run.ps1` for the live walk-through.

**THE GOVERNING LESSON (burned in over ~12+ failures + this session):** terrain shape is a VISUAL problem. The test gate is a GUARDRAIL, not the goal — every prior failure passed a green gate while looking like oatmeal/uniform. The driving loop is **capture low → look → tune → re-capture → WALK it**, with the human's eyes as the real judge. Do NOT claim success on a green test gate. PARK for the human before declaring M2.3 done. Structure MUST come from the uplift field + composition; if the output looks uniform, the structure layer is wrong — NOT a tuning problem to paper over.

---

## File structure

- **Modify:** `wg-13/shaders/field_height.glsl`
  - Add composition primitives after `fbm()`: `value_fbm()`, `ridged_fbm()`, `domain_warp()`, `uplift_field()`, `valley_carve()`.
  - Add `composition_height(world_xz, seed)` (hand-set character constants).
  - Replace the height line in `main()`: `float h = fbm(world_xz, uint(seed));` → `float h = composition_height(world_xz, uint(seed));`.
  - Keep `fbm()` (climate/other may reference; harmless if unused — but verify and remove only if truly unused, DRY).
- **Create:** `wg-13/tests/m2_3_composition_check.gd` — the guardrail test gate.
- **Rewrite (ground-aware):** `wg-13/captures/shape_capture.gd` — sample field height, place the eye above local ground (the restored version uses fixed altitudes tuned for ~240m terrain; the new terrain is taller, so a fixed-y camera buries the camera inside a peak).
- **Docs (update as part of the green-gate step):** `PROGRESS.md`, `DRIFT_LOG.md`, `04_CODE_MAP.md`, this plan's checkboxes.

## What the machine computes (the design — from the approved spec, do not re-decide)

```
composition_height(world_xz, seed):
  warp     = domain_warp(world_xz, seed)            # organic, non-grid coords
  uplift   = uplift_field(warp, seed)               # 0..1 — WHERE terrain stands up (STRUCTURE)
  base     = continental_base(world_xz, seed)       # gentle continental undulation everywhere
  ridges   = ridged_fbm(warp * RIDGE_SCALE, seed)   # ridgelines (crest-rounded, has body)
  relief   = uplift * ridges * RELIEF_AMP           # relief ONLY where uplift high -> ranges
  carve    = valley_carve(uplift, CARVE_DEPTH*RELIEF_AMP)  # press inter-range basins down
  detail   = (value_fbm(world_xz, seed) - 0.5) * DETAIL_AMP
  height   = base + relief - carve + detail
```
The **uplift × ridges** is the structural fix: `uplift` is a LOW-frequency field that is high in some regions (ranges stand) and low in most (flat lowlands). Multiplying ridges by uplift means relief only appears where uplift is high → discrete ranges with flat/valley land between. A global octave-sum has no uplift → uniform everywhere (the failure). CAPS = hand-set tuning knobs this step (DEM-tuned in M2.4).

---

## Task 1: Add the composition primitives + machine (compile-green build)

**Files:** Modify `wg-13/shaders/field_height.glsl`

- [x] **Step 1: Re-read the insertion region**

Read `field_height.glsl` lines 104-115 (`fbm`) and 198-220 (`main`) so the exact text is in context. Confirm `value_noise`, `hash_u`, `fade` exist above (reused — DRY, no re-defining noise).

- [x] **Step 2: Add the primitives** (insert right after `fbm()` at ~line 115)

```glsl
// --- M2.3 composition machine: shared terrain primitives --------------------
// Layered composition: relief is PLACED by a low-frequency UPLIFT field (where
// terrain stands up into hills/ranges vs stays flat lowland), carrying ridge
// texture, with inter-range basins carved down. This is what a global octave-sum
// cannot do (no "a range stands HERE") -> it makes uniform texture. World-space,
// deterministic (00 §5). Character constants are hand-set here; DEM-tuned in M2.4.

// Smooth fBM normalized to ~[0,1] (rolling undulation / continental base).
float value_fbm(vec2 p, uint seed, uint oct, float lacunarity, float gain) {
    float sum = 0.0, amp = 1.0, norm = 0.0, freq = 1.0;
    for (uint o = 0u; o < oct; o++) {
        sum  += amp * value_noise(p * freq, seed + o * 0x68bc21ebu);
        norm += amp; amp *= gain; freq *= lacunarity;
    }
    return sum / max(norm, 1e-6);
}

// Ridged fBM: ridgelines via 1-|2n-1|, crest ROUNDED (smoothstep) so ridges have
// body (not pinched tent-poles), with prev-octave weighting so detail rides the
// ridges. Returns ~[0,1].
float ridged_fbm(vec2 p, uint seed, uint oct, float lacunarity, float gain) {
    float sum = 0.0, amp = 0.5, norm = 0.0, freq = 1.0, prev = 1.0;
    for (uint o = 0u; o < oct; o++) {
        float n = value_noise(p * freq, seed + o * 0x9e3779b9u);
        float r = 1.0 - abs(2.0 * n - 1.0);
        r = smoothstep(0.0, 1.0, r);    // round the crest -> ridgelines with body
        r *= prev; prev = clamp(r, 0.0, 1.0);
        sum  += amp * r; norm += amp; amp *= gain; freq *= lacunarity;
    }
    return sum / max(norm, 1e-6);
}

// Domain warp: bend coords by low-freq noise so landforms are organic, not grid.
vec2 domain_warp(vec2 p, uint seed, float amount, float freq) {
    float wx = value_noise(p * freq, seed ^ 0x57415250u) - 0.5;
    float wz = value_noise(p * freq + vec2(31.4, 17.0), seed ^ 0x70726177u) - 0.5;
    return p + amount * 2.0 * vec2(wx, wz);
}

// Uplift field: a blurred LOW-frequency mask in [0,1] — WHERE terrain stands up
// (ranges/uplands) vs stays low (lowlands). Two low octaves (big regions + sub-
// regions). smoothstep with a window so MOST of the world is lowland (real worlds
// are mostly flat) and uplift rises in bands. This is the STRUCTURE PLACER.
float uplift_field(vec2 p, uint seed, float freq, float lo, float hi) {
    float a0 = value_noise(p * freq, seed ^ 0x55504c54u);        // "UPLT"
    float a1 = value_noise(p * freq * 2.03, seed ^ 0x73756272u); // "subr"
    float u = clamp(a0 * 0.7 + a1 * 0.3, 0.0, 1.0);
    return smoothstep(lo, hi, u);
}

// Valley carve: press DOWN inter-range lowlands. Where uplift is low, subtract up
// to depth; on a range (uplift high) subtract nothing. (1-uplift)^2 keeps range
// flanks from being over-carved.
float valley_carve(float uplift, float depth) {
    float v = 1.0 - uplift;
    return depth * v * v;
}
```

- [x] **Step 3: Add `composition_height()`** (after the primitives)

```glsl
// M2.3 general terrain: ONE composition machine for the whole world. Structure
// from uplift; character HAND-SET here (DEM-tuned in M2.4). Most of the world is
// gentle lowland (base + small detail); ranges stand where uplift is high.
float composition_height(vec2 world_xz, uint seed) {
    // --- hand-set character knobs (M2.3 tuning; DEM-driven in M2.4) ---
    const float WARP_AMOUNT  = 2200.0;   // world units of coord bend
    const float WARP_FREQ    = 0.00004;  // warp's own low freq (~25 km)
    const float UPLIFT_FREQ  = 0.000025; // range placement (~40 km regions)
    const float UPLIFT_LO    = 0.45;     // below -> lowland (uplift 0)
    const float UPLIFT_HI    = 0.70;     // above -> full range (uplift 1); wide gap -> mostly lowland
    const uint  RIDGE_OCT    = 6u;
    const float RIDGE_LAC    = 2.03;
    const float RIDGE_GAIN   = 0.55;
    const float RIDGE_SCALE  = 0.0004;   // ridgeline scale (~2.5 km)
    const float RELIEF_AMP   = 1600.0;   // peak range relief (m)
    const float CARVE_DEPTH  = 0.4;      // fraction of relief pressed into valleys
    const float BASE_FREQ    = 0.00012;  // continental base undulation (~8 km)
    const uint  BASE_OCT     = 3u;
    const float BASE_AMP     = 180.0;    // gentle lowland relief everywhere
    const float DETAIL_FREQ  = 0.0016;
    const uint  DETAIL_OCT   = 4u;
    const float DETAIL_AMP   = 70.0;     // fine surface roughness

    vec2 warp    = domain_warp(world_xz, seed, WARP_AMOUNT, WARP_FREQ);
    float uplift = uplift_field(warp, seed, UPLIFT_FREQ, UPLIFT_LO, UPLIFT_HI);
    float base   = value_fbm(world_xz * BASE_FREQ, seed ^ 0x42415345u, BASE_OCT, 2.0, 0.5) * BASE_AMP;
    float ridges = ridged_fbm(warp * RIDGE_SCALE, seed, RIDGE_OCT, RIDGE_LAC, RIDGE_GAIN);
    float relief = uplift * ridges * RELIEF_AMP;
    float carve  = valley_carve(uplift, CARVE_DEPTH * RELIEF_AMP);
    float detail = (value_fbm(world_xz * DETAIL_FREQ, seed ^ 0x44455421u, DETAIL_OCT, 2.0, 0.5) - 0.5)
                   * 2.0 * DETAIL_AMP;
    return base + relief - carve + detail;
}
```

- [x] **Step 4: Swap the height line in `main()`**

Replace:
```glsl
    float h = fbm(world_xz, uint(seed));
```
with:
```glsl
    // M2.3: general terrain from the composition machine (uplift places structure,
    // hand-set character). Replaces the flat M1 fbm. Climate/biome unchanged below
    // (height never feeds biome — biome uses macro_altitude; no circularity).
    float h = composition_height(world_xz, uint(seed));
```

- [x] **Step 5: Compile is proven by the Task 3 gate** (GLSL-only change, no `cargo build`). A compile error makes `FieldCompute.initialize`/`dispatch_page` fail. Do NOT commit until Task 3 + the visual gate.

---

## Task 2: Write the guardrail test gate

**Files:** Create `wg-13/tests/m2_3_composition_check.gd`

The three guardrail checks: **determinism**, **structure-not-uniform** (relief spread across a wide region — flat lowland pages AND tall range pages → big spread; the failed octave-sum had ~0 spread), **no cliffs** (bounded adjacent step).

- [x] **Step 1: Write the gate**

```gdscript
extends SceneTree
# M2.3 gate — composition machine, proven by GPU readback. GUARDRAIL, not the
# success criterion: the REAL gate is the human looking at low captures + walking
# (the 12-failure lesson — a green gate on bad terrain is the trap). Checks:
#   1. DETERMINISM: same page+seed -> identical heights.
#   2. STRUCTURE-NOT-UNIFORM: across a wide region the per-page local roughness
#      SPREADS a lot (flat lowland pages + tall range pages). Uniform terrain (the
#      failure) -> spread ~0. This catches a regression to the octave-sum.
#   3. NO CLIFF: max adjacent step bounded (continuity / no vertical walls).
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_3_composition_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 8.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _avg_step(h: PackedFloat32Array) -> float:
	var s := 0.0; var n := 0
	for z in range(RES):
		for x in range(RES - 1):
			s += absf(h[z*RES+x+1] - h[z*RES+x]); n += 1
	return s / maxf(n, 1)

func _max_step(h: PackedFloat32Array) -> float:
	var m := 0.0
	for z in range(RES):
		for x in range(RES - 1):
			m = maxf(m, absf(h[z*RES+x+1] - h[z*RES+x]))
	return m

func _init() -> void:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.initialize(SHADER):
		_fail("FieldCompute init failed (need vulkan / shader compile error)"); _finish(); return

	# 1. Determinism.
	var a: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	var b: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	if a.size() != RES*RES: _fail("page size"); _finish(); return
	if a != b: _fail("determinism: same seed differs")
	else: print("PASS: determinism")

	# 2. Structure-not-uniform: scan a wide grid; per-page roughness spread.
	var roughs: Array[float] = []
	for iz in range(-8, 9):
		for ix in range(-8, 9):
			var h: PackedFloat32Array = fc.produce_page(ix*1000.0, iz*1000.0, SPACING, SEED, RES, OCT, FREQ, AMP)
			roughs.append(_avg_step(h))
	var lo := roughs[0]; var hi := roughs[0]
	for r in roughs:
		lo = minf(lo, r); hi = maxf(hi, r)
	var spread := (hi - lo) / maxf(hi, 1e-6)
	print("INFO: %d pages  rough lo=%.3f hi=%.3f  spread=%.2f" % [roughs.size(), lo, hi, spread])
	if spread > 0.5:
		print("PASS: structure — wide relief spread %.2f (lowlands + ranges, not uniform)" % spread)
	else:
		_fail("structure: spread %.2f too low — terrain looks UNIFORM (octave-sum regression)" % spread)

	# 3. No cliff: max adjacent step over the origin page bounded.
	var ms := _max_step(a)
	if ms > 600.0: _fail("cliff: max step %.1f > 600" % ms)
	else: print("PASS: no cliff — max step %.1f within 600" % ms)

	_finish()

func _finish() -> void:
	print("M2.3 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
```

---

## Task 3: Run the test gate + no-regression suite

**Files:** none

- [x] **Step 1: Run the M2.3 gate**

```powershell
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "wg-13" --script "res://tests/m2_3_composition_check.gd"
```
Expected: `PASS: determinism`, `PASS: structure — wide relief spread ...`, `PASS: no cliff ...`, `M2.3 RESULT: PASS`.

- [x] **Step 2: If FAIL, debug systematically (do NOT stack fixes)**
- `init failed` → shader compile error: re-read Task 1 edits, brace/paren balance, every helper exists. Fix the ONE error.
- `determinism` → a primitive missed a seed. Fix.
- `structure spread too low` → uplift isn't placing discrete relief (UPLIFT_LO/HI window wrong, UPLIFT_FREQ wrong, or RELIEF_AMP too small vs base/detail). This is the CORE risk — it will also show in captures. Tune Task 1 constants, re-run.
- `cliff` → RIDGE_GAIN/RELIEF_AMP too high for the spacing, or carve making a wall. Reduce.
- After 3 honest attempts without green, STOP + log to DRIFT_LOG (02_WORKFLOW §1.4); leave code compiling.

- [x] **Step 3: No-regression — M2.1 climate + M2.2 biome must still PASS** (height is additive; never feeds biome/climate selection)

```powershell
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "wg-13" --script "res://tests/m2_1_climate_check.gd"
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "wg-13" --script "res://tests/m2_2_biome_check.gd"
```
Expected: both `... RESULT: PASS`. NOTE: M2.1 climate's alt-cool reads the composed height (`(height-150)/200`); the new height range is taller, so if `m2_1_climate_check` regresses on RANGE/GRADIENT, the alt-cool normalization needs revisiting (a known coupling — fix the normalization, re-run; do NOT change the contract). If it passes, the coupling is fine as-is.

---

## Task 4: Make the capture tool ground-aware (so the visual gate is valid)

**Files:** Rewrite `wg-13/captures/shape_capture.gd`

The restored capture tool uses fixed camera altitudes (y≈300-900) tuned for ~240m terrain. The new terrain is taller → a fixed-y eye sits INSIDE a peak (torn undersides in the capture, not real terrain). Fix: sample field height at each spot via `FieldCompute`, place the eye a fixed amount above local ground.

- [x] **Step 1: Rewrite the capture tool ground-aware**

```gdscript
extends SceneTree
# Terrain SHAPE capture — LOW altitude, to judge relief (lowlands, hills, ranges,
# valleys) at the scale you fly. Saves _captures/shape_lowN.png at a few regions.
# Evidence only; live walking is the real judge (01_TOOLCHAIN §5).
#
# GROUND-AWARE (M2.3): terrain relief is now tall + varied, so a fixed-y camera
# would sit buried inside a peak. We SAMPLE the field height at each spot via
# FieldCompute and place the eye a fixed amount ABOVE local ground, aimed at an
# on-ground point ahead. Valid at any relief scale.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://captures/shape_capture.gd

const VIEW := preload("res://scripts/world_view.gd")
const OUT_DIR := "res://_captures"
const SETTLE := 120
const SPACING := 4.0          # match world_view live params (sampled==rendered)
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0
const RES := 32
const EYE_ABOVE := 130.0
const LOOK_AHEAD := 1500.0

# (x,z) vantages over different regions; y filled from sampled ground.
const SPOTS_XZ := [
	Vector2(-32000.0, -16000.0),
	Vector2(40000.0, 0.0),
	Vector2(0.0, 40000.0),
]

var _root: Node3D
var _fc
var _f := 0
var _shot := 0
var _eyes: Array[Vector3] = []
var _tgts: Array[Vector3] = []

func _height_at(wx: float, wz: float) -> float:
	var h: PackedFloat32Array = _fc.produce_page(wx, wz, SPACING, SEED, RES, OCT, FREQ, AMP)
	return h[0] if h.size() > 0 else 0.0

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_fc = ClassDB.instantiate("FieldCompute")
	if _fc == null or not _fc.initialize("res://shaders/field_height.glsl"):
		print("CAPTURE init failed (need vulkan)"); quit(1); return
	var dir: Vector2 = Vector2(1.0, -0.3).normalized()
	for p in SPOTS_XZ:
		var gy: float = _height_at(p.x, p.y)
		var eye := Vector3(p.x, gy + EYE_ABOVE, p.y)
		var ahead: Vector2 = p + dir * LOOK_AHEAD
		var ty: float = _height_at(ahead.x, ahead.y)
		var tgt := Vector3(ahead.x, ty + EYE_ABOVE * 0.4, ahead.y)
		_eyes.append(eye); _tgts.append(tgt)
		print("SPOT (%.0f,%.0f): ground %.0fm -> eye y %.0f" % [p.x, p.y, gy, eye.y])
	_root = Node3D.new()
	_root.set_script(VIEW)
	_root.set("show_page_tint", false)
	get_root().add_child(_root)

func _process(_dt: float) -> bool:
	_f += 1
	var cam := get_root().get_viewport().get_camera_3d()
	if cam and _f == 2:
		cam.global_position = _eyes[_shot]
		cam.look_at(_tgts[_shot], Vector3.UP)
		cam.far = 60000.0
	if _f < SETTLE:
		return false
	var out := "%s/shape_low%d.png" % [OUT_DIR, _shot]
	var err := get_root().get_texture().get_image().save_png(out)
	print("CAPTURE %d: %s" % [_shot, ("saved " + out) if err == OK else ("FAIL " + str(err))])
	_shot += 1
	if _shot >= _eyes.size() or err != OK:
		quit(0 if err == OK else 1)
		return true
	_f = 0
	return false
```

---

## Task 5: THE VISUAL LOOP — capture low, look, tune, WALK (the real gate)

**Files:** `wg-13/shaders/field_height.glsl` (tuning constants only), `wg-13/_captures/*.png` (gitignored)

- [x] **Step 1: Capture low**
```powershell
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "wg-13" --script "res://captures/shape_capture.gd"
```
Expect `SPOT ...: ground ... -> eye y ...` then `CAPTURE 0/1/2 saved`.

- [x] **Step 2: LOOK (Read the PNGs)** — Read `wg-13/_captures/shape_low0.png`, `shape_low1.png`, `shape_low2.png`. Judge honestly: does the world read as **believable varied terrain** — mostly gentle lowlands, some hills, distinct ranges with valleys between — NOT oatmeal, NOT uniform, NOT all-mountains? Describe what you actually see. Do not rationalize a bad picture.

- [x] **Step 3: Tune the hand-set knobs (tuning, not building)** — adjust ONLY the `const` knobs in `composition_height`:
  - Too much of the world is mountainous → raise `UPLIFT_LO`/`UPLIFT_HI` (more lowland).
  - Ranges too small/frequent → lower `UPLIFT_FREQ` (bigger regions).
  - Not tall/dramatic enough → raise `RELIEF_AMP`. Too jagged/spiky → lower `RIDGE_GAIN` or `RELIEF_AMP`.
  - Grid-looking ranges → raise `WARP_AMOUNT`.
  - Valleys not reading → raise `CARVE_DEPTH`.
  - Lowlands too flat/too bumpy → adjust `BASE_AMP`/`DETAIL_AMP`.
  Change few knobs per iteration (cause→effect legible). Re-run Task 3 gate after any change affecting cliffs/determinism.

- [x] **Step 4: Iterate Steps 1-3 until the captures read as believable varied terrain.** Note landed knob values.

- [x] **Step 5: PARK for the human visual gate (cannot self-certify)** —
  1. Bring project to green (Task 3 gate green).
  2. Launch live: `& "D:\world gen 13\run.ps1"`. Tell the human: fly + **WALK** it (G = walk), judge whether terrain reads as believable + varied (lowlands, hills, ranges/valleys). Walking is the truest test.
  3. Write a `PARKED-FOR-VISUAL` DRIFT_LOG entry: captures + landed knobs + "believe satisfied, awaiting human, did NOT proceed to M2.4."
  4. **STOP.** Do not start M2.4 (DEM character). Present captures, wait.

---

## Task 6: On human PASS — record + commit the green visual gate

**Files:** `PROGRESS.md`, `04_CODE_MAP.md`, `DRIFT_LOG.md`, `HANDOFF.md`

- [x] **Step 1: PROGRESS.md** — mark `M2.3 [x]` (test guardrail green + human visual PASS, date), move `<- CURRENT` to `M2.4`.
- [x] **Step 2: 04_CODE_MAP.md** — document the composition machine (primitives + uplift + composition_height) and the renamed `m2_3_composition_check.gd` + the ground-aware capture tool + how to run them.
- [x] **Step 3: DRIFT_LOG.md** — resolution entry: M2.3 visual PASS by human [date], landed knobs, the structural lesson confirmed (uplift places structure where octave-sum couldn't).
- [x] **Step 4: HANDOFF.md §3** — current state: M2.3 done (general terrain proven), next step M2.4 (DEM character integration); note landed knobs as the reference M2.4 tunes against.
- [x] **Step 5: Commit** (ASCII message via temp file, `git commit -F` — HANDOFF §5):
```powershell
Set-Content -Path "$env:TEMP\m23_msg.txt" -Encoding ascii -Value @"
[M2.3] composition machine: uplift places structure (lowlands/hills/ranges+valleys); human visual PASS

Replace flat M1 fbm with a composition machine (domain warp, uplift field,
ridged + value fbm, valley carve), hand-set character. Structure from uplift
(not stats-matching). One dispatch, height R32F, climate/biome unchanged
(no circularity). Gate m2_3_composition_check PASS + human walk PASS. DEM
character = M2.4. Capture tool made ground-aware for tall terrain.
"@
git add -A
git commit -F "$env:TEMP\m23_msg.txt"
```
- [x] **Step 6: Verify** — `git log -1 --stat` shows shader + gate + capture + docs; `git status` clean; push (`git push origin main`).

---

## Self-review notes (checked against the spec)

- **Spec coverage:** composition machine primitives (warp, uplift, ridged, value_fbm, carve) ✓ Task 1; uplift PLACES structure (the anti-octave-sum) ✓; hand-set character now, DEM-tuned deferred to M2.4 ✓ (spec sequence); biome unchanged / height-as-skin-independent ✓ (main() leaves climate/biome lines); contract preserved (one dispatch, R32F, no Rust) ✓; test gate (determinism, structure-not-uniform, no-cliff) ✓ Task 2/3; visual gate as the make-or-break + WALK + PARK ✓ Task 5; scope = general terrain ONLY (per-biome shape + DEM tuning NOT in this plan) ✓.
- **Steep-terrain known-issues:** this plan WILL produce tall terrain → the render-vs-collision gap + fast-traverse items may surface at the walk-through. Per the spec they are handled in their RIGHT layer, gated, when they bite — NOT bandaided here. If the human's walk hits fall-through, that becomes its own systematic-debugging task (render/collision layer), NOT a player hack. Noted so the executor doesn't repeat the prior mistake.
- **No placeholders:** every code step has complete GLSL/GDScript; every run step the exact command + expected output. ✓
- **Consistency:** `composition_height` / `uplift_field` / primitive names + signatures consistent across Task 1, the gate, and Task 5 tuning. `value_noise`/`hash_u`/`fade` reused (DRY). ✓
- **Don't over-build:** only the primitives the composition needs (warp, uplift, ridged, value_fbm, carve). No biome/DEM table read this step. ✓
```
