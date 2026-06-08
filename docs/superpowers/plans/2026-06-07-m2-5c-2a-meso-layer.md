# M2.5c — Step 2a: Meso layer (sub-region modulation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the missing MIDDLE frequency tier — a meso (~single-digit-km) field that varies each macro region's shape sub-region to sub-region — so the land is always resolving into something new as you travel (fixes "scale feels off / 1000s of km of sameness"). Plus a dedicated N key to jump straight to biome view, and a per-step isolated profiling timer in the new gate.

**Architecture:** Touch ONLY `composition_height` (and the `band()`/macro helpers it shares) in the GPU field shader `field_height.glsl` — the framework (streaming, climate/biome classifier, M2.4 analytic-normal seam fix, M1.7 collision, M2.5b archetype roster) is unchanged. The meso layer is a pure world function of `(world_xz, seed)` that returns two decorrelated channels: `meso_mod` (multiplies each archetype's contribution so sub-regions rise/fall) and a reserved `meso_dev` (deviation noise, plumbed but UNUSED until 2d — features). No circular dependency: meso noise is its own hashed seed, independent of detailed height.

**Tech Stack:** GLSL compute (the field, source of truth). Godot 4.6.2 GDScript gates run via the `_console` exe with `--rendering-driver vulkan`. No `cargo` rebuild (shader + GDScript only — the field is hot-reloaded; the open editor does NOT lock the shader).

**Spec:** `docs/superpowers/specs/2026-06-07-m2-5c-two-tier-diversity-scale-design.md`
**Baseline reference (current production shape):** `wg-13/shaders/field_height.glsl` — `composition_height` lines ~238-266, `band()` line ~209, `arch_*` lines ~181-208.

**Toolchain (01_TOOLCHAIN):**
- Console exe: `C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe`
- Gate: `& "<console>" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/<gate>.gd"` → prints `... RESULT: PASS|FAIL`.
- Kill Godot first: `Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force`
- Commit ASCII via tempfile: `git -C "D:\world gen 13" commit -F <tempfile>`; end body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- NO `cargo build` (GLSL + GDScript only, hot).

**HARD RULES:**
- Never silently loosen a gate (change a threshold only as a stated decision + code comment, only when it still catches the regression).
- The meso field MUST stay a smooth pure function of `(world_xz, seed)` — NO hard `if` cutoffs in the height path, NO reads of detailed height, NO per-page state. This preserves the seam-free invariant (`m1_4`) and the no-circular-dependency rule BY CONSTRUCTION.
- Channels 0-3 of the field output keep their byte layout (M1.7 height/collision contract). Only the VALUE of `h` changes.
- If 2+ gates fail unexpectedly, STOP and report (don't stack fixes). A failed VISUAL gate → `git reset --hard` to the prior green commit; never roll back terrain shape just to pass a test gate.

**Scope (2a only):** meso MODULATION of the existing 6 M2.5b archetypes + N-key + the new gate with isolated timing. The data-row refactor (2b), 5-family spine (2c), and feature stamping / deviation knob (2d) are LATER plans — `meso_dev` is plumbed here but deliberately unused.

---

### Task 1: Add the meso field primitive (two decorrelated channels)

**Files:**
- Modify: `wg-13/shaders/field_height.glsl` — add a `meso_field()` function in the "shared terrain primitives" block, immediately AFTER `domain_warp` (~line 156, before the M2.5b archetype section).

- [ ] **Step 1: Add the meso_field function**

Insert after `domain_warp` (after line ~156):

```glsl
// --- M2.5c meso layer: the MIDDLE frequency tier (sub-region variation) --------
// Returns two DECORRELATED channels off a mid-frequency field (~1/several-km), in
// world space, pure function of (world_xz, seed) so it is seam-free + has no
// circular dependency (own hashed seeds, never reads detailed height):
//   .x = meso_mod  in ~[-1,1]  -> how this sub-region nudges the parent's shape
//   .y = meso_dev  in ~[0,1]   -> deviation noise (RESERVED for 2d feature stamps;
//                                  plumbed now, UNUSED in 2a)
// meso_freq is the sub-region scale: smaller => larger sub-regions. Default
// 0.00012 (~1/8.3km wavelength) gives single-digit-km sub-regions (spec §4).
vec2 meso_field(vec2 world_xz, uint seed, float meso_freq) {
    uint mod_seed = hash_u(seed ^ 0x4d45534fu);   // "MESO"
    uint dev_seed = hash_u(seed ^ 0x44455621u);    // "DEV!"
    // Two octaves of smooth fBM, centered to [-1,1] for mod / kept [0,1] for dev.
    float m = value_fbm(world_xz * meso_freq, mod_seed, 2u, 2.0, 0.5);
    float d = value_fbm(world_xz * meso_freq * 1.7, dev_seed, 2u, 2.0, 0.5);
    return vec2(m * 2.0 - 1.0, d);
}
```

- [ ] **Step 2: Verify the shader still compiles (run the existing seam gate)**

Run:
```powershell
Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m1_4_seam_check.gd"
```
Expected: `M1.4 RESULT: PASS` (function added but not yet called → shape unchanged → still compiles + seamless). If it prints a GLSL compile error, fix the syntax before proceeding.

- [ ] **Step 3: Commit**

Write the message to a tempfile `D:\tmp\m25c_t1.txt`:
```
[M2.5c-2a] add meso_field primitive (two decorrelated channels, unused yet)

The middle frequency tier (spec 2a). Pure (world_xz, seed) function: meso_mod
nudges parent shape, meso_dev reserved for 2d feature stamps. Not called yet
(shape bit-unchanged); m1_4 seam PASS confirms it compiles.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
Then:
```powershell
git -C "D:\world gen 13" add wg-13/shaders/field_height.glsl
git -C "D:\world gen 13" commit -F D:\tmp\m25c_t1.txt
Remove-Item D:\tmp\m25c_t1.txt
```

---

### Task 2: Wire meso modulation into composition_height

**Files:**
- Modify: `wg-13/shaders/field_height.glsl` — `composition_height` (~lines 238-266).

**Context:** `composition_height` currently sums each archetype's height weighted by `band()` climate weights, divided by `wsum`, then adds `lone_peaks`. The meso layer multiplies the per-archetype CONTRIBUTION by a sub-region factor so the SAME region rises into sub-ranges and falls into saddles as you travel. A per-archetype `meso_strength` constant (the 2b refactor will make this a data column; here it is a named const so the diff is one line per archetype) scales how much each family responds — mountains vary a lot, plains gently.

- [ ] **Step 1: Add meso modulation to composition_height**

Replace the body of `composition_height` (the function at ~line 239) with:

```glsl
// M2.5b composition + M2.5c meso modulation: blend archetypes by MACRO climate,
// vary each archetype's contribution by the MESO sub-region field, add lone peaks.
float composition_height(vec2 world_xz, uint seed) {
    vec2 rp = domain_warp(world_xz, seed ^ 0x52454749u, 3000.0, 0.00003);
    float macro_alt = macro_altitude(rp, seed);
    vec2  mc = macro_climate(rp, seed, macro_alt);
    float temp = mc.x, moist = mc.y;

    // M2.5c: meso sub-region field (the middle tier). meso_mod in [-1,1].
    const float MESO_FREQ = 0.00012;     // ~1/8.3km sub-regions (spec §4 default)
    float meso_mod = meso_field(world_xz, seed, MESO_FREQ).x;

    float macro_base = (macro_alt - 0.35) * 1400.0;

    float w_alpine   = band(macro_alt, 0.85, 0.16);
    float w_highland = band(macro_alt, 0.62, 0.14);
    float w_forest   = band(macro_alt, 0.45, 0.16) * band(moist, 0.6, 0.35);
    float w_mesa     = band(macro_alt, 0.5, 0.2) * band(moist, 0.15, 0.18) * band(temp, 0.8, 0.3);
    float w_swamp    = band(macro_alt, 0.28, 0.12) * band(moist, 0.85, 0.25);
    float w_plains   = band(macro_alt, 0.32, 0.18);
    float wsum = w_alpine + w_highland + w_forest + w_mesa + w_swamp + w_plains + 1e-4;

    // Per-archetype meso response (2b will make this a data column). Each archetype's
    // contribution is scaled by (1 + meso_mod*strength): high meso_mod -> this
    // sub-region of the region rises; low -> it sinks toward a saddle/basin. Clamped
    // so a sub-region never inverts the landform (stays >= 0.25 of base).
    float ma = clamp(1.0 + meso_mod * 0.65, 0.25, 1.75);   // alpine: strong relief
    float mh = clamp(1.0 + meso_mod * 0.55, 0.25, 1.75);   // highland
    float mf = clamp(1.0 + meso_mod * 0.40, 0.35, 1.65);   // forest hills
    float mm = clamp(1.0 + meso_mod * 0.50, 0.30, 1.70);   // mesa
    float ms = clamp(1.0 + meso_mod * 0.30, 0.50, 1.50);   // swamp: gentle
    float mp = clamp(1.0 + meso_mod * 0.35, 0.45, 1.55);   // plains: gentle

    float h = macro_base + (
          w_alpine   * arch_alpine(world_xz, seed)     * ma
        + w_highland * arch_highlands(world_xz, seed)  * mh
        + w_forest   * arch_forest_hills(world_xz, seed) * mf
        + w_mesa     * arch_mesa(world_xz, seed)       * mm
        + w_swamp    * arch_swamp(world_xz, seed)      * ms
        + w_plains   * arch_plains(world_xz, seed)     * mp
    ) / wsum;

    h += lone_peaks(world_xz, seed);
    return h;
}
```

- [ ] **Step 2: Run the seam gate (meso must stay seam-free)**

Run:
```powershell
Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m1_4_seam_check.gd"
```
Expected: `M1.4 RESULT: PASS` — meso is a pure world function, so adjacent pages still agree at the shared edge (the analytic normal in `main()` re-evaluates `composition_height` at neighbors, which now include the meso term, so normals stay consistent).

- [ ] **Step 3: Run the composition gate (structure must remain non-uniform)**

Run:
```powershell
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m2_3_composition_check.gd"
```
Expected: `M2.3 RESULT: PASS` — determinism holds, spread stays > 0.5 (meso ADDS variation so spread should be >= the M2.5b 0.93, never less), max step within 600.

- [ ] **Step 4: Commit**

Tempfile `D:\tmp\m25c_t2.txt`:
```
[M2.5c-2a] meso modulation of archetype contributions (the middle tier)

Each archetype's contribution scaled by (1 + meso_mod*strength), clamped so a
sub-region varies but never inverts. Mountains respond strongly, plains/swamp
gently. Sub-regions now rise into sub-ranges / fall into saddles as you travel.
Pure world function -> m1_4 seam PASS, m2_3 structure PASS.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
```powershell
git -C "D:\world gen 13" add wg-13/shaders/field_height.glsl
git -C "D:\world gen 13" commit -F D:\tmp\m25c_t2.txt
Remove-Item D:\tmp\m25c_t2.txt
```

---

### Task 3: Write the m2_5c_meso_check gate (with isolated timing)

**Files:**
- Create: `wg-13/tests/m2_5c_meso_check.gd`

**Context:** This is the 2a test gate (`02_WORKFLOW §2`). It proves the meso layer is (1) deterministic, (2) ADDS sub-region variation that the macro-only field lacked — measured as MESO-SCALE relief: sample a line of pages a few km apart WITHIN one macro region and confirm their mean heights vary (sub-regions exist), and (3) bounded (no cliff). It also reports an ISOLATED timing number (spec §6) — the wall-clock to produce N pages — so this step's added cost is visible in isolation, separate from the aggregate `m2_6_burst`. This is a GUARDRAIL; the REAL gate is the human flying it.

- [ ] **Step 1: Write the gate**

```gdscript
extends SceneTree
# M2.5c-2a gate — meso layer (sub-region modulation), proven by GPU readback.
# GUARDRAIL, not the success criterion: the REAL gate is the human flying it and
# seeing sub-regions resolve as they travel. Checks:
#   1. DETERMINISM: same page+seed -> identical heights.
#   2. MESO VARIATION: along a line of pages a few km apart inside ONE macro region,
#      mean page height VARIES (sub-regions rise/fall) -> the middle tier exists.
#      Macro-only terrain (the pre-2a baseline) would be ~flat along that short line.
#   3. NO CLIFF: max adjacent step bounded (continuity preserved).
# Also prints ISOLATED TIMING (spec §6): us to produce a batch of pages, so 2a's
# added cost is visible separately from the aggregate m2_6_burst gate.
# Run: <console> --rendering-driver vulkan --path wg-13 --script res://tests/m2_5c_meso_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 8.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _mean(h: PackedFloat32Array) -> float:
	var s := 0.0
	for v in h: s += v
	return s / maxf(h.size(), 1)

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

	# 2. Meso variation: walk a line of pages ~4km apart (sub-region scale) and
	# confirm the per-page MEAN height varies. A page is RES*SPACING = ~1km wide; we
	# step 4km so consecutive samples land in different meso sub-regions. We anchor
	# near a mid-altitude region so several archetypes are active (more meso effect).
	const STEP := 4000.0          # ~half the ~8.3km meso wavelength -> samples differ
	const ANCHOR_X := 30000.0
	const ANCHOR_Z := 30000.0
	var means: Array[float] = []
	for i in range(12):
		var h: PackedFloat32Array = fc.produce_page(ANCHOR_X + i*STEP, ANCHOR_Z, SPACING, SEED, RES, OCT, FREQ, AMP)
		means.append(_mean(h))
	var lo := means[0]; var hi := means[0]
	for m in means:
		lo = minf(lo, m); hi = maxf(hi, m)
	var meso_range := hi - lo
	print("INFO: 12 pages over %dm  mean lo=%.1f hi=%.1f  meso_range=%.1fm" % [int(11*STEP), lo, hi, meso_range])
	# Sub-regions must differ by a meaningful margin (tens of meters minimum) along a
	# short in-region line. Threshold 40m: macro-only baseline along this line is much
	# flatter; meso modulation lifts it well past this. Catches a regression that
	# drops the meso term (would collapse toward the macro mean -> range < 40).
	if meso_range > 40.0:
		print("PASS: meso variation — sub-regions vary %.1fm along a 44km in-region line" % meso_range)
	else:
		_fail("meso variation: range %.1fm too low — middle tier missing/too weak" % meso_range)

	# 3. No cliff.
	var ms := _max_step(a)
	if ms > 600.0: _fail("cliff: max step %.1f > 600" % ms)
	else: print("PASS: no cliff — max step %.1f within 600" % ms)

	# 4. Isolated timing (spec §6): time producing a batch of pages on THIS step.
	# Not a pass/fail (the budget authority is m2_6_burst); a visible per-step number
	# so a future step's regression is attributable here, not only in the aggregate.
	var t0 := Time.get_ticks_usec()
	const TIMED := 20
	for i in range(TIMED):
		var _h: PackedFloat32Array = fc.produce_page(i*1000.0, 5000.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	var dt := Time.get_ticks_usec() - t0
	print("INFO: isolated timing — %d pages in %d us (%.1f us/page incl. dispatch+readback)" % [TIMED, dt, float(dt)/TIMED])

	_finish()

func _finish() -> void:
	print("M2.5c-2a RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
```

- [ ] **Step 2: Run the new gate — expect PASS**

Run:
```powershell
Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m2_5c_meso_check.gd"
```
Expected: `M2.5c-2a RESULT: PASS`, with an INFO line showing `meso_range` > 40m and an INFO timing line. If `meso_range` is < 40m, the meso term is too weak — INCREASE the per-archetype strengths in Task 2 (do NOT lower the threshold; that would defeat the gate). Record the actual `meso_range` and us/page numbers in the commit.

- [ ] **Step 3: Commit**

Tempfile `D:\tmp\m25c_t3.txt` (fill in the real numbers from Step 2):
```
[M2.5c-2a] gate m2_5c_meso_check (determinism, meso variation, no-cliff, timing)

Proves the middle tier exists: mean page height varies <RANGE>m along a 44km
in-region line (macro-only baseline is far flatter). Determinism + no-cliff hold.
Isolated timing <US>/page (budget authority stays m2_6_burst). GUARDRAIL; the
real gate is the human fly-test.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
```powershell
git -C "D:\world gen 13" add wg-13/tests/m2_5c_meso_check.gd
git -C "D:\world gen 13" commit -F D:\tmp\m25c_t3.txt
Remove-Item D:\tmp\m25c_t3.txt
```

---

### Task 4: Add the N key → jump to biome view

**Files:**
- Modify: `wg-13/scripts/dem_grounded_world_view.gd` — `_unhandled_input` (~lines 241-246).

**Context:** Today only V cycles the view modes (`normal → temperature → moisture → biome`); biome is the 4th press. During the diversity work the human constantly checks shape↔color agreement, so a dedicated key that jumps straight to biome view (index 3) is worth the 3 lines. `VIEW_MODE_NAMES` is `["normal", "temperature", "moisture", "biome"]`, so biome is index 3. `_apply_view_mode()` already pushes the mode to all live + recycled materials.

- [ ] **Step 1: Add the N-key branch**

In `_unhandled_input`, find the existing V branch:
```gdscript
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_V:
		_view_mode = (_view_mode + 1) % VIEW_MODE_NAMES.size()
		_apply_view_mode()
		print("view mode: %s" % VIEW_MODE_NAMES[_view_mode])
```
Add immediately AFTER it (still inside `_unhandled_input`):
```gdscript
	# M2.5c: N jumps straight to BIOME view (index 3) — the shape<->color check used
	# constantly while tuning diversity. Press again from biome returns to normal (0).
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_N:
		var biome_idx := VIEW_MODE_NAMES.find("biome")
		_view_mode = 0 if _view_mode == biome_idx else biome_idx
		_apply_view_mode()
		print("view mode: %s" % VIEW_MODE_NAMES[_view_mode])
```

- [ ] **Step 2: Verify the scene loads clean (no parse error)**

Run the tour smoke check (loads the view, exercises input-free streaming):
```powershell
Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/tour_smoke_check.gd"
```
Expected: the smoke check runs to its normal RESULT line with no GDScript parse error referencing `dem_grounded_world_view.gd`. (If the smoke check targets the production view and doesn't load the dem view, instead confirm no parse error by launching the dem scene headless for a few seconds — but the parse error would surface on any load of the edited file.)

- [ ] **Step 3: Commit**

Tempfile `D:\tmp\m25c_t4.txt`:
```
[M2.5c-2a] N key jumps straight to biome view (shape<->color check)

Toggles directly to biome mode (index 3) and back to normal; V still cycles all
four. GDScript-only, no gate risk. Used constantly while tuning diversity.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
```powershell
git -C "D:\world gen 13" add wg-13/scripts/dem_grounded_world_view.gd
git -C "D:\world gen 13" commit -F D:\tmp\m25c_t4.txt
Remove-Item D:\tmp\m25c_t4.txt
```

---

### Task 5: Hold the perf budget + full regression sweep

**Files:** none (verification only).

**Context:** The meso layer adds `meso_field` (2 fBM evals) to `composition_height`, which `main()` evaluates 5× per cell (center + 4 normal neighbors). Spec §5 names perf as the top risk; this task re-runs the budget gate and the full suite before the visual gate.

- [ ] **Step 1: Run the burst perf gate**

Run:
```powershell
Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m2_6_burst_perf_check.gd"
```
Expected: `RESULT: PASS`, 0/720 (or within the established budget) over the 16.6ms frame budget. Record the median-of-maxes. If it FAILS (over budget), the meso evals are too heavy at 5×/cell — apply a pre-identified lever (spec §5: drop the meso octaves on the 4 NORMAL taps only — the normal tolerates a cheaper meso than the height; or share the `meso_field` result across taps if feasible). Do NOT proceed to the visual gate over-budget.

- [ ] **Step 2: Run the remaining regression gates**

Run each; all must print `RESULT: PASS`:
```powershell
$gates = @("m1_4_seam_check","m2_3_composition_check","m2_1_climate_check","m2_2_biome_check","m1_7a_heights_check","m1_7c_stand_check","m2_5c_meso_check")
foreach ($g in $gates) {
  Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force
  & "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/$g.gd"
}
```
Expected: every gate ends in `PASS`. m1_7a/m1_7c confirm the height/collision contract is intact (channels 0-3 unchanged). m2_1/m2_2 confirm climate/biome are unaffected (meso only touches height).

- [ ] **Step 3: Record the sweep (no commit — verification only, or a docs commit in Task 6)**

Note the burst median-of-maxes and the `m2_5c_meso_check` meso_range + us/page in your working notes for the Task 6 docs update and the DRIFT_LOG park entry.

---

### Task 6: Update docs + park for the human visual gate

**Files:**
- Modify: `plans and docs/plans/PROGRESS.md` (add the 2a line under M2.5b)
- Modify: `plans and docs/plans/DRIFT_LOG.md` (prepend a PARKED-FOR-VISUAL entry)
- Modify: `plans and docs/plans/04_CODE_MAP.md` (note meso_field + the N key + the new gate)

**Context:** The working method (§8) records as part of the step. The 2a VISUAL gate (sub-regions resolve as you travel) needs the human's eyes — so this step brings the world to the believed-good green state, writes the park entry, and STOPS (does not start 2b).

- [ ] **Step 1: Add the PROGRESS line**

In `PROGRESS.md`, under the M2.5b line (the `M2.5b [~] REGIONAL-ARCHETYPE...` entry ~line 102), add:
```
M2.5c-2a [~] MESO LAYER (sub-region modulation) — the missing MIDDLE tier. meso_field
  (2 channels: meso_mod nudges each archetype's contribution, meso_dev reserved for 2d)
  wired into composition_height; each archetype meso-responds (mountains strong, plains
  gentle). + N-key->biome view, + gate m2_5c_meso_check (determinism, meso variation
  <RANGE>m/44km, no-cliff, isolated timing <US>/page). Perf HELD (burst <X>ms, 0/720).
  Gates green (m1_4/m2_3/m2_1/m2_2/m1_7a/m1_7c/m2_5c). PARKED for human visual: does the
  land resolve into new sub-regions as you travel (scale/sameness fixed)? Spec/plan:
  docs/superpowers/.../2026-06-07-m2-5c-*.
```
(Fill `<RANGE>`, `<US>`, `<X>` from Task 3/Task 5.)

- [ ] **Step 2: Prepend the DRIFT_LOG park entry**

At the top of `DRIFT_LOG.md` (after the header, before the most recent entry), prepend:
```
## [2026-06-07] - M2.5c-2a MESO LAYER shipped -> PARKED FOR VISUAL
TYPE: PARKED-FOR-VISUAL (test gates self-certified; the LOOK awaits the human — 02_WORKFLOW §2)
WHAT: added the MIDDLE frequency tier (spec 2a). meso_field(world_xz, seed, freq) returns
meso_mod (~[-1,1], nudges each archetype's contribution) + meso_dev (reserved for 2d). Wired
into composition_height: each archetype's contribution scaled by (1 + meso_mod*strength),
clamped so sub-regions vary but never invert (alpine 0.65 strongest .. swamp/plains ~0.3
gentle). Pure (world_xz, seed) function -> seam-free + no circular dependency BY CONSTRUCTION.
Also: N-key jumps to biome view; new gate m2_5c_meso_check with isolated timing.
TEST GATES (self-certified): m1_4 seam PASS, m2_3 structure PASS (spread held), m2_1/m2_2
climate+biome PASS (height-only change), m1_7a/m1_7c height/collision contract PASS,
m2_5c_meso_check PASS (meso_range <RANGE>m over 44km in-region, no-cliff, timing <US>/page),
m2_6_burst <X>ms median-of-maxes 0/720 over budget (perf top-risk HELD).
VISUAL GATE — BELIEVE SATISFIED, AWAITING HUMAN: fly the dem scene. (1) Does the land now
resolve into distinct SUB-REGIONS as you travel within one macro region — sub-ranges, saddles,
basins — instead of vast sameness? (2) Press N to check biome color still matches shape. (3)
Any seam/popping at sub-region boundaries (should be NONE — smooth meso). If sub-regions are
too subtle, the lever is MESO_FREQ (lower = bigger sub-regions) or the per-archetype strengths
(data in 2b); if too busy, raise MESO_FREQ. DID NOT start 2b (data-row refactor).
CODEBASE STATE: dem-grounded, green. composition_height has the meso tier; framework intact.
```
(Fill the numbers.)

- [ ] **Step 3: Update the CODE_MAP**

In `04_CODE_MAP.md`, in the `field_height.glsl` description, append a sentence:
```
M2.5c-2a: + meso_field() (middle frequency tier) — composition_height varies each
archetype's contribution by a ~1/8.3km sub-region field (meso_mod), seam-free.
```
And in the `dem_grounded_world_view.gd` description, append:
```
M2.5c: N key jumps straight to biome view (shape<->color check).
```
And in the gates list, add:
```
m2_5c_meso_check.gd — 2a meso layer (determinism, meso variation, no-cliff, isolated timing).
```

- [ ] **Step 4: Commit the docs**

Tempfile `D:\tmp\m25c_t6.txt`:
```
[M2.5c-2a] PARK for visual: meso layer shipped, docs updated

PROGRESS + DRIFT_LOG (park entry) + CODE_MAP. Test gates green, perf held. Awaiting
human fly-test: does the land resolve into sub-regions as you travel?

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
```powershell
git -C "D:\world gen 13" add "plans and docs/plans/PROGRESS.md" "plans and docs/plans/DRIFT_LOG.md" "plans and docs/plans/04_CODE_MAP.md"
git -C "D:\world gen 13" commit -F D:\tmp\m25c_t6.txt
Remove-Item D:\tmp\m25c_t6.txt
```

- [ ] **Step 5: Launch for the human + STOP**

Launch the dem scene for the live fly-test (the human resolves the visual gate):
```powershell
# Per 02_WORKFLOW §8: run.ps1 brings up a visible window for the human to fly.
& "D:\world gen 13\run.ps1"
```
Then STOP. Do NOT start 2b (the data-row refactor) — it begins only after the human PASSES this visual gate. Report: gates green, perf held, world parked for the fly-test, with the meso_range / us/page / burst numbers.

---

## Self-review notes (for the implementer)

- **Spec coverage:** This plan covers spec step **2a only** (meso modulation + N-key + isolated-timing gate). Steps 2b (data-row refactor), 2c (5-family spine), 2d (features + deviation) are SEPARATE plans written after each predecessor's gate is green — by design (`02_WORKFLOW §1/§2`, the gated ladder). `meso_dev` is plumbed here, used in 2d.
- **No new Rust:** the meso layer is shader-only; no `cargo build`. The N-key is GDScript-only. This keeps 2a low-risk per the spec's meso-first rationale.
- **Threshold honesty:** the 40m `meso_range` gate is the regression catch (a dropped meso term collapses toward the macro mean). If real terrain legitimately exceeds/needs adjustment, change it only as a stated decision + comment (HARD RULE).
- **The real gate is visual.** Every test gate here is a guardrail; the human fly-test (sub-regions resolve as you travel) is the success criterion — the project's terrain-quality lesson (a green gate on bad terrain is the trap).
