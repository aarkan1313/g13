# M2.4 Clipmap Geomorph Seam Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the visible geometry step/lip at fine↔coarse clipmap ring boundaries so the ground reads smooth and contiguous at low altitude, without changing terrain shape, heights, or collision.

**Architecture:** A self-contained vertex geomorph in the display shader (`ring_displace.gdshader`). Each page, near its outer transition band, blends every vertex's height (and its normal taps) between the full-detail texture value and a half-resolution tap of the *same* texture, keyed by camera-to-vertex distance. Adjacent clipmap levels therefore display the same surface at their shared boundary → no step. The effect is display-only: `page.heights` (collision source) and `FieldCompute` are untouched, so there is NO Rust rebuild.

**Tech Stack:** Godot 4.6.2 spatial shader (GDShader), GDScript (`world_view.gd`), Godot SceneTree gate scripts. GPU gates run with `--rendering-driver vulkan` (never `--headless`).

---

## Why an automated test cannot "see" the morph (read before Task 1)

The morph is a **vertex-shader display effect**. It never writes `page.heights` and never calls `FieldCompute.produce_page`. Every existing gate reads heights through `FieldCompute` — so by design those gates see **identical** heights with or without the morph. That identity is exactly the contract we want (collision/determinism unchanged). Therefore:

- The **automated gate proves the display-only contract** (heights/collision/determinism unchanged + all existing gates still green + shader compiles).
- The **visual fix is proven by the human walk-test** (fly low over a ring boundary; the lip is gone). This is consistent with the project rule that the real terrain gate is the human (02_WORKFLOW §8).

Do not write a height-readback test that claims to verify the morph — it can't, and pretending it does is slop.

---

## File Structure

- **Modify** `wg-13/shaders/ring_displace.gdshader` — add geomorph to `vertex()`: new uniforms, half-res height tap, distance-based morph factor, blended height + blended normal taps. Fragment shader untouched.
- **Modify** `wg-13/scripts/world_view.gd` — in `_make_page_instance`, set the new shader uniforms per page (`page_res`, `morph_start`, `morph_end`); compute the per-level morph band once from existing constants. Add an `@export` to enable/tune.
- **Create** `wg-13/tests/m2_4_geomorph_check.gd` — gate proving the display-only contract: shader compiles, and heights are bit-identical to a known-good reference path (i.e. the morph cannot have touched the height production). Plus a runner note to re-run the existing gate suite.
- **Reference (do not modify):** `wg-13/tests/m1_4_seam_check.gd`, `m1_5c_overlap_check.gd`, `m1_7c_stand_check.gd`, `m2_3_composition_check.gd`, `m2_1_climate_check.gd`, `m2_2_biome_check.gd` — re-run as regression gates.

---

## Conventions you must follow (project-specific)

- **Gate scripts** are `extends SceneTree`, define `var _failed := false`, `func _fail(m)`, and `func _finish()` that prints `RESULT` and calls `quit(1 if _failed else 0)`. Match `m2_3_composition_check.gd` exactly in shape.
- **Run a GPU gate** (PowerShell), using the `_console` exe for stdout:
  ```powershell
  $g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
  & $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/<name>.gd
  ```
  Exit code 0 = PASS.
- **Launch the world** for the human gate: `.\run.ps1` from `D:\world gen 13` (closes any running Godot, opens a windowed Vulkan instance). User has approved closing the currently-running Godot instances.
- **No Rust build needed** for any task here (shader + GDScript only). Do NOT run cargo.
- **Commit messages:** ASCII, via `git commit -F <tempfile>` (here-strings have broken commits before). End with the Co-Authored-By trailer used in this repo.
- **User has deuteranopia:** the human gate judges by SHAPE/SHADING, not color.

---

## Task 1: Add geomorph uniforms + half-res tap helper to the shader (no behavior change yet)

Establish the inputs and the coarse-sampling helper, with the morph defaulting to OFF (factor 0), so this task changes nothing visually and can be committed safely.

**Files:**
- Modify: `wg-13/shaders/ring_displace.gdshader`

- [ ] **Step 1: Add the new uniforms** after the existing `cell_spacing` uniform (currently around line 31).

```glsl
// --- M2.4 clipmap geomorph (display-only; smooths fine<->coarse ring boundaries) ---
// Page texel resolution (so we can snap a vertex UV to half resolution for the
// coarse tap). Matches PagePool page_res (128).
uniform int page_res = 128;
// Camera-distance morph band (world units). Beyond morph_end the page shows its
// coarse (half-res) surface; before morph_start it shows full detail; between, it
// blends. Set per-page from the level's ring geometry by world_view.gd. When
// morph_end <= morph_start the morph is OFF (factor stays 0) -> identical to pre-M2.4.
uniform float morph_start = 0.0;
uniform float morph_end = 0.0;
```

- [ ] **Step 2: Add the half-res coarse-tap helper** right after the existing `sample_h` function (currently around line 38).

```glsl
// Sample height at the UV SNAPPED to half resolution (one coarser clipmap step):
// the height this vertex would have on a page of half the texel density. Snap to
// texel centers of the half-res grid so the tap is stable. Clamped like sample_h.
float sample_h_coarse(vec2 uv) {
	float half_res = max(float(page_res) * 0.5, 1.0);
	vec2 snapped = (floor(uv * half_res) + 0.5) / half_res;
	return sample_h(snapped);
}

// Camera-distance morph factor in [0,1]: 0 = full detail, 1 = fully coarse.
float morph_factor(float cam_dist) {
	if (morph_end <= morph_start) return 0.0;   // morph OFF
	return clamp((cam_dist - morph_start) / (morph_end - morph_start), 0.0, 1.0);
}
```

- [ ] **Step 3: Verify the shader still compiles and is unchanged in behavior.** Open the project once (or run any GPU gate that loads the shader, e.g. the new check in Task 5 is not ready yet — use `m2_3` which does not load this display shader, so instead launch the world). Launch:

```powershell
.\run.ps1
```

Expected: world launches, terrain looks identical to before (the helpers are defined but not called yet). If the shader has a syntax error, Godot prints a shader compile error to the console — fix it before committing.

- [ ] **Step 4: Commit**

```powershell
$g = git add wg-13/shaders/ring_displace.gdshader
$f = "$env:TEMP/wg13_t1.txt"
@'
[M2.4] geomorph: add uniforms + half-res coarse tap helper (no behavior change)

morph_start/morph_end default to 0 (morph OFF), so output is identical to the
pre-M2.4 shader. Sets up Task 2 to apply the blend.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@ | Out-File -FilePath $f -Encoding ascii
git commit -F $f
Remove-Item $f
```

---

## Task 2: Apply the morph blend to vertex height and normal in the shader

Wire the morph into `vertex()`. Because the band defaults to OFF, this is still visually identical until Task 3 supplies a real band — but now the code path is live.

**Files:**
- Modify: `wg-13/shaders/ring_displace.gdshader` (the `vertex()` function, currently lines 40-54)

- [ ] **Step 1: Replace the body of `vertex()`** with the morphed version. Current `vertex()`:

```glsl
void vertex() {
	// PlaneMesh lies in XZ with VERTEX.xz in [-size/2, size/2]. Map to UV [0,1].
	vec2 uv = (VERTEX.xz / page_world_size) + vec2(0.5);
	UV = uv;
	float h = sample_h(uv);
	v_height = h;
	VERTEX.y = h;

	// Finite-difference normal from neighboring texels.
	float du = cell_spacing / page_world_size;
	float hx = sample_h(uv + vec2(du, 0.0)) - sample_h(uv - vec2(du, 0.0));
	float hz = sample_h(uv + vec2(0.0, du)) - sample_h(uv - vec2(0.0, du));
	vec3 n = normalize(vec3(-hx, 2.0 * cell_spacing, -hz));
	NORMAL = n;
}
```

Replace it entirely with:

```glsl
void vertex() {
	// PlaneMesh lies in XZ with VERTEX.xz in [-size/2, size/2]. Map to UV [0,1].
	vec2 uv = (VERTEX.xz / page_world_size) + vec2(0.5);
	UV = uv;

	// M2.4 geomorph: blend this vertex (and its normal taps) between full detail
	// and a half-res coarse tap, by camera distance. World-space vertex position
	// via MODEL_MATRIX (PlaneMesh local -> world). morph_factor() is 0 (no change)
	// unless world_view.gd supplied a real band for this page's level.
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float cam_dist = distance(world_pos.xz, CAMERA_POSITION_WORLD.xz);
	float a = morph_factor(cam_dist);

	float h_full = sample_h(uv);
	float h = mix(h_full, sample_h_coarse(uv), a);
	v_height = h;
	VERTEX.y = h;

	// Finite-difference normal — blend each tap the SAME way as the height so the
	// shaded surface matches the morphed geometry (no shading seam reappearing).
	float du = cell_spacing / page_world_size;
	float hxp = mix(sample_h(uv + vec2(du, 0.0)), sample_h_coarse(uv + vec2(du, 0.0)), a);
	float hxm = mix(sample_h(uv - vec2(du, 0.0)), sample_h_coarse(uv - vec2(du, 0.0)), a);
	float hzp = mix(sample_h(uv + vec2(0.0, du)), sample_h_coarse(uv + vec2(0.0, du)), a);
	float hzm = mix(sample_h(uv - vec2(0.0, du)), sample_h_coarse(uv - vec2(0.0, du)), a);
	vec3 n = normalize(vec3(-(hxp - hxm), 2.0 * cell_spacing, -(hzp - hzm)));
	NORMAL = n;
}
```

- [ ] **Step 2: Verify the shader compiles and behavior is still unchanged** (band is still OFF: world_view hasn't set `morph_start`/`morph_end` yet, so they're 0 → `morph_factor` returns 0 → `mix(..., 0.0)` is the full-detail value).

```powershell
.\run.ps1
```

Expected: world launches; terrain identical to before. No shader compile error in the console.

- [ ] **Step 3: Commit**

```powershell
git add wg-13/shaders/ring_displace.gdshader
$f = "$env:TEMP/wg13_t2.txt"
@'
[M2.4] geomorph: apply morph blend to vertex height + normal taps

Blend defaults OFF (band still 0 from world_view), so output unchanged. Normal
taps are morphed identically to the height so shading matches the morphed surface.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@ | Out-File -FilePath $f -Encoding ascii
git commit -F $f
Remove-Item $f
```

---

## Task 3: Drive the morph band per page from world_view.gd

Now supply a real per-level distance band so the morph actually engages. The band is derived from the existing clipmap constants (`base_span`, `ring_radius`, level), set once per material in `_make_page_instance`. Add an `@export` toggle/tuning so the human can dial it live.

**Files:**
- Modify: `wg-13/scripts/world_view.gd` (add exports near the other `@export`s ~line 44; set uniforms in `_make_page_instance` ~line 368)

- [ ] **Step 1: Add export knobs** after the `collision_radius` export (currently line 44).

```gdscript
# M2.4 geomorph: smooth the fine<->coarse clipmap boundary by morphing each page
# toward a half-res tap of its own height near the camera-distance band where the
# NEXT-coarser level takes over. morph_frac = where in a level's reach the morph
# starts (fraction of that level's ring reach); the morph completes at the reach
# edge. enable_geomorph=false restores the exact pre-M2.4 look (band -> 0).
@export var enable_geomorph: bool = true
@export_range(0.3, 0.95, 0.01) var morph_frac: float = 0.6
```

- [ ] **Step 2: Set the geomorph uniforms in `_make_page_instance`.** Add these lines right after the existing `cell_spacing` set (currently line 368, `mat.set_shader_parameter("cell_spacing", spacing * pow(2.0, level))`).

```gdscript
	# M2.4 geomorph band for THIS page's level. A level-L page is the finest cover
	# out to its ring reach (ring_radius * span); beyond that the next-coarser level
	# takes over. Morph from morph_frac*reach to reach, so by the hand-off this page
	# already shows its coarse (half-res) surface and meets the coarser level smoothly.
	# Level (num_levels-1) is the coarsest blanket: nothing coarser to meet, so OFF.
	mat.set_shader_parameter("page_res", page_res)
	if enable_geomorph and level < num_levels - 1:
		var reach: float = float(ring_radius) * span
		mat.set_shader_parameter("morph_start", reach * morph_frac)
		mat.set_shader_parameter("morph_end", reach)
	else:
		mat.set_shader_parameter("morph_start", 0.0)   # OFF (coarsest level or disabled)
		mat.set_shader_parameter("morph_end", 0.0)
```

- [ ] **Step 3: Launch and look (first real visual check).**

```powershell
.\run.ps1
```

Expected: world launches. Fly LOW over a fine→coarse ring boundary. The geometry step/lip should be visibly reduced/gone vs. before. Terrain shape and the surface directly under the camera (level 0, near = full detail) unchanged. If the morph is too aggressive (detail vanishes too close), raise `morph_frac` toward 0.9 in the inspector; if the step still shows, lower it toward 0.4. (This is a tuning knob, not a code change.)

- [ ] **Step 4: Commit** (code; tuning value can be revisited at the human gate).

```powershell
git add wg-13/scripts/world_view.gd
$f = "$env:TEMP/wg13_t3.txt"
@'
[M2.4] geomorph: drive per-level morph band from world_view

Sets page_res + a camera-distance morph band (morph_frac*reach .. reach) per page,
off for the coarsest level and when enable_geomorph=false. Engages the shader
blend so fine<->coarse boundaries smooth out. Band is inspector-tunable.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@ | Out-File -FilePath $f -Encoding ascii
git commit -F $f
Remove-Item $f
```

---

## Task 4: Write the display-only contract gate

Prove the morph did NOT touch the height/collision production. The check produces pages via `FieldCompute` (the same path collision and the gates use) and asserts determinism + a stable known property, demonstrating the height path is independent of the shader change. (It also serves as a fast "did I accidentally break the field" guard.)

**Files:**
- Create: `wg-13/tests/m2_4_geomorph_check.gd`

- [ ] **Step 1: Write the gate.** Create `wg-13/tests/m2_4_geomorph_check.gd`:

```gdscript
extends SceneTree
# M2.4 gate — geomorph is DISPLAY-ONLY. The morph lives entirely in
# ring_displace.gdshader's vertex stage; it never writes page.heights and never
# touches FieldCompute. This gate is a GUARDRAIL proving that contract: the height
# production (the collision source, M1.7) is unaffected by the M2.4 change. The
# REAL gate for the seam fix is the human walk-test (fly low over a ring boundary;
# the lip is gone) — a height-readback test CANNOT see a vertex-shader effect.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_4_geomorph_check.gd

const SHADER := "res://shaders/field_height.glsl"
const DISPLAY_SHADER := "res://shaders/ring_displace.gdshader"
const RES := 128
const SPACING := 4.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	# 1. The display shader still COMPILES (catches a geomorph syntax error).
	var sh := load(DISPLAY_SHADER)
	if sh == null:
		_fail("ring_displace.gdshader failed to load/compile"); _finish(); return
	print("PASS: display shader loads/compiles")

	# 2. Height production unchanged: determinism (the morph cannot have leaked into
	#    the field path — if it had, FieldCompute would differ or fail).
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.initialize(SHADER):
		_fail("FieldCompute init failed (need vulkan / field shader error)"); _finish(); return
	var a: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	var b: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	if a.size() != RES * RES:
		_fail("page size %d != %d" % [a.size(), RES * RES]); _finish(); return
	if a != b:
		_fail("determinism: same seed/page differs (field path disturbed)")
	else:
		print("PASS: height production deterministic + intact (display-only contract holds)")

	_finish()

func _finish() -> void:
	print("M2.4 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
```

- [ ] **Step 2: Run the gate and verify it PASSES.**

```powershell
$g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m2_4_geomorph_check.gd
```

Expected output contains `PASS: display shader loads/compiles`, `PASS: height production deterministic + intact`, and `M2.4 RESULT: PASS`. Exit code 0.

- [ ] **Step 3: Commit**

```powershell
git add wg-13/tests/m2_4_geomorph_check.gd
$f = "$env:TEMP/wg13_t4.txt"
@'
[M2.4] gate: display-only contract check (shader compiles + field path intact)

Proves the geomorph did not touch height/collision production. The seam fix
itself is gated by the human walk-test (a vertex-shader effect is invisible to a
height-readback test, by design).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@ | Out-File -FilePath $f -Encoding ascii
git commit -F $f
Remove-Item $f
```

---

## Task 5: Regression — re-run the existing gate suite

Confirm nothing regressed. All must stay green (the M2.4 change is display-only, so they should be unaffected).

**Files:** none (running existing gates).

- [ ] **Step 1: Run each existing gate.**

```powershell
$g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
$proj = "D:\world gen 13\wg-13"
foreach ($t in @(
	"m1_4_seam_check",
	"m1_5c_overlap_check",
	"m1_7c_stand_check",
	"m2_1_climate_check",
	"m2_2_biome_check",
	"m2_3_composition_check",
	"m2_4_geomorph_check"
)) {
	"=== $t ==="
	& $g --rendering-driver vulkan --path $proj --script "res://tests/$t.gd"
	"exit: $LASTEXITCODE"
}
```

Expected: every gate prints its `RESULT: PASS` and `exit: 0`. If any FAILs, STOP — do not proceed to the human gate. Investigate (the morph should not affect any of these; a failure means something else broke). Per the working method: if a fix doesn't work, REVERT it, don't stack a second fix.

- [ ] **Step 2: No commit** (running gates produces no file changes). Record the results in the milestone note in Task 6.

---

## Task 6: Human visual gate (the real gate) + docs

The automated gates prove the contract; the human proves the fix. Park for the human walk-test, then update docs at green.

**Files:**
- Modify: `plans and docs/plans/PROGRESS.md` (flip M2.4 line at green)
- Modify: `plans and docs/plans/DRIFT_LOG.md` (append the result entry)

- [ ] **Step 1: Launch the world for the human.**

```powershell
.\run.ps1
```

- [ ] **Step 2: Ask the human to walk-test** with this exact ask:
  - Fly LOW over a fine→coarse chunk boundary. Is the geometry step/lip gone — does the ground read smooth and contiguous across the boundary?
  - Is the M2.3 terrain shape unchanged, and the surface directly under you (near, level 0) still full-detail?
  - (If the morph is too aggressive or too weak, adjust `Morph Frac` on the world_view node in the inspector — 0.4 = morph later/less, 0.9 = morph earlier/more — and re-look. No code change needed.)
  - User has deuteranopia: judge by shape/shading, not color.

- [ ] **Step 3: If the human PASSES**, update PROGRESS.md — change the `M2.4` line from the rolled-back note to:

```
M2.4 [x] CLIPMAP GEOMORPH seam fix: self-contained vertex morph in ring_displace (half-res tap, camera-distance band per level) removes the fine<->coarse geometry step. Display-only (heights/collision/determinism intact; no Rust rebuild). Gates: m2_4_geomorph_check PASS + m1_4/m1_5c/m1_7c/m2_1/m2_2/m2_3 all green. Human VISUAL gate PASS <date>: chunk borders read smooth/contiguous low; M2.3 shape unchanged. morph_frac=<final value>.
```

- [ ] **Step 4: Append a DRIFT_LOG.md entry** at the top (after the `---` on line 5) recording: the fix shipped, the final `morph_frac`, the human verdict, and that the **DEM-direct brainstorm is the next track**.

- [ ] **Step 5: Commit the docs.**

```powershell
git add "plans and docs/plans/PROGRESS.md" "plans and docs/plans/DRIFT_LOG.md"
$f = "$env:TEMP/wg13_t6.txt"
@'
[M2.4] docs: geomorph seam fix shipped (human visual PASS) -> DEM-direct next

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@ | Out-File -FilePath $f -Encoding ascii
git commit -F $f
Remove-Item $f
```

- [ ] **Step 6: If the human does NOT pass after tuning `morph_frac`**, STOP and report. Do not stack a second mechanism. Options to bring back to brainstorming: widen the approach (neighbor-fine-page morph, the alternative in the spec) or reconsider scope. Revert the shader/world_view changes if the look regressed: `git revert` the Task 2/3 commits (keep Task 1's inert helpers if desired).

---

## Self-Review (completed by plan author)

**Spec coverage:** Every spec section maps to a task — root cause/mechanism → Tasks 1–3; determinism/contracts-preserved → Task 4; acceptance gates (automated + human) → Tasks 4–6; "no Rust rebuild" honored (no cargo anywhere); pillar call & tradeoff are in the spec and reflected in the OFF-by-default + inspector-tunable design. The "morph toward neighbor fine page" alternative is captured as the Task 6 fallback.

**Placeholder scan:** No TBD/TODO. Every code step shows full code. The only intentional runtime variable is `morph_frac`'s final tuned value and the human-gate date, which are genuinely determined at the gate (not placeholders — they're outputs of the gate step).

**Type/name consistency:** Uniform names match across shader and GDScript: `page_res`, `morph_start`, `morph_end` (shader uniforms) ↔ `set_shader_parameter("page_res"/"morph_start"/"morph_end", ...)` in world_view. Helper names `sample_h_coarse`, `morph_factor` defined in Task 1, used in Task 2. Exports `enable_geomorph`, `morph_frac` defined and used in Task 3. Gate file name `m2_4_geomorph_check.gd` consistent across Tasks 4–5.
