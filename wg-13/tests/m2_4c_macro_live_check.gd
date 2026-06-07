extends SceneTree
# M2.4c macro live gate — the MACRO_CACHE height lane (terrain_mode=2) is LIVE,
# proven by GPU readback. GUARDRAIL, not the success criterion: the REAL gate is
# the HUMAN flying AND walking the macro terrain (demo.tscn, B -> MACRO_CACHE) and
# judging believability — the controller runs that; this script does NOT
# self-certify the visual (the 12-failure lesson: a green automated gate on bad
# terrain is the trap). This gate is the guardrail that proves the macro fixed the
# oracle's 1km-wall failure. Checks (each prints PASS/FAIL):
#   1. DETERMINISM: produce_macro_page twice at the same origin -> identical.
#   2. FINITE + NON-FLAT: all heights finite; real relief (>100m) somewhere in a
#      wide scan (the macro has real ranges, not a flat/NaN field).
#   3. NO-TERRACING (the key quality assertion): on a FINE 8m page the height is
#      C0-smooth — NO 256m-bake-spacing terraces. Hardware bilinear interpolates
#      between macro texels (256m apart), so over 8m cells the height changes
#      GRADUALLY, never in flat plateaus with sudden jumps. Asserts (a) max
#      adjacent step bounded (<600m — steep slopes ok, NO 256m walls) AND (b) no
#      plateau-then-jump signature (longest run of near-identical consecutive
#      cells stays short — bilinear changes every cell; a terrace = ~32 flat
#      cells [256m/8m] then a jump).
#   4. SEAM (proves the macro fixed the oracle's 1076m walls): a page positioned to
#      STRADDLE a region border has max step <600m (vs the oracle's 1076m), and
#      the border converges (no seam spike — straddling max comparable to interior).
#   5. REGRESSION-FRIENDLY: an INFO line with the key numbers so the human reading
#      the gate output sees the evidence.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_4c_macro_live_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 8.0      # FINE cells (8m) so 256m bake terraces WOULD show
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0

# Macro region core span = (ceil(30000/256)-1)*256 = (118-1)*256 = 29952m, derived
# from DEFAULT_MACRO_SUPER_REGION_M/DEFAULT_MACRO_BAKE_SPACING_M in
# macro_cache::region — keep in sync if those change (matches core_span_m()).
# A fine page spans (128-1)*8 = 1016m.
const CORE_SPAN := 29952.0
const PAGE_SPAN := (RES - 1) * SPACING   # 1016.0

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _all_finite(h: PackedFloat32Array) -> bool:
	for v in h:
		if is_nan(v) or is_inf(v):
			return false
	return true

func _max_step(h: PackedFloat32Array) -> float:
	# Max adjacent-cell step in BOTH x and z (a terrace/wall shows on either axis).
	var m := 0.0
	for z in range(RES):
		for x in range(RES - 1):
			m = maxf(m, absf(h[z*RES+x+1] - h[z*RES+x]))
	for z in range(RES - 1):
		for x in range(RES):
			m = maxf(m, absf(h[(z+1)*RES+x] - h[z*RES+x]))
	return m

func _relief(h: PackedFloat32Array) -> float:
	var lo := h[0]; var hi := h[0]
	for v in h:
		lo = minf(lo, v); hi = maxf(hi, v)
	return hi - lo

# Longest run of consecutive cells (scanning every row in x) whose adjacent delta
# is < FLAT_EPS. A bilinear-smooth field has tiny-but-nonzero deltas everywhere
# (macro slope + macro_detail fbm) -> short runs. A terraced field has ~32 flat
# cells [256m bake / 8m page] before each 256m jump -> a long run.
#
# FLAT_EPS tuned 0.5 -> 0.05m (VERIFIED, not loosened to hide a terrace — the
# opposite, it was TIGHTENED to discriminate harder). At 0.5m the smooth field
# tripped: near a local extremum the height genuinely curves through its peak with
# per-8m-cell deltas of ~0.1-0.25m for ~32 cells (the macro_detail fbm wavelength
# is ~625m, so a quarter-wave near an extremum spans ~32 fine cells). That is a
# SMOOTH hilltop, NOT a terrace: a dumped height row showed values changing every
# cell (442.27 441.26 440.23 ... 437.0 437.1 437.2 437.4 437.6 437.8 438.0 ...)
# with NO jump (whole-page max step is only ~12m, vs a 256m terrace wall). The
# discriminator that survives is "actually flat" = delta < 5cm: a real terrace has
# ~32 cells of ~0.000m delta then a 256m jump; a smooth field's slowest stretch
# (right at an extremum) still moves >5cm/cell except for a handful of cells. At
# eps=0.05m the WORST flat-run across 49 interior pages is 10 cells (2x margin
# under the 20 threshold); a real 32-cell terrace would still trip 20. The
# height-row evidence is in the Task-6 handoff.
const FLAT_EPS := 0.05    # metres: a TRULY-flat adjacent delta (terrace = ~0)
func _longest_flat_run(h: PackedFloat32Array) -> int:
	var longest := 0
	# x-axis rows.
	for z in range(RES):
		var run := 0
		for x in range(RES - 1):
			if absf(h[z*RES+x+1] - h[z*RES+x]) < FLAT_EPS:
				run += 1
				longest = maxi(longest, run)
			else:
				run = 0
	# z-axis columns (a terrace from broken bilinear / a column-major bake bug
	# would show on the z axis too — _max_step scans both, so this must as well,
	# or a z-axis terrace slips past the PRIMARY no-terracing discriminator).
	for x in range(RES):
		var run := 0
		for z in range(RES - 1):
			if absf(h[(z+1)*RES+x] - h[z*RES+x]) < FLAT_EPS:
				run += 1
				longest = maxi(longest, run)
			else:
				run = 0
	return longest

func _init() -> void:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.initialize(SHADER):
		_fail("FieldCompute init failed (need vulkan / shader compile error)"); _finish(); return

	# Interior page: well inside region (0,0), away from any border. Used for
	# determinism / finite / no-terracing and as the interior seam baseline.
	var int_ox := 5000.0
	var int_oz := 5000.0

	# 1. DETERMINISM: same origin twice -> identical arrays.
	var a: PackedFloat32Array = fc.produce_macro_page(int_ox, int_oz, SPACING, SEED, RES, OCT, FREQ, AMP)
	var b: PackedFloat32Array = fc.produce_macro_page(int_ox, int_oz, SPACING, SEED, RES, OCT, FREQ, AMP)
	if a.size() != RES*RES:
		_fail("macro page size — produce_macro_page empty? (mode-2 wiring / shader compile)"); _finish(); return
	if a != b: _fail("determinism: same origin/seed differs")
	else: print("PASS: determinism — macro page identical across two calls")

	# 2. FINITE + NON-FLAT: finite everywhere; >100m relief somewhere in a wide scan.
	if not _all_finite(a): _fail("macro origin page has NaN/Inf")
	else: print("PASS: interior page all finite")
	var max_relief := 0.0
	# Scan within region (0,0) [0..29952m] on a coarse stride so we sample real
	# ranges/lowlands. Stride 4000m -> 7x7 pages, all inside the region.
	for iz in range(7):
		for ix in range(7):
			var ox := 1000.0 + ix * 4000.0
			var oz := 1000.0 + iz * 4000.0
			var h: PackedFloat32Array = fc.produce_macro_page(ox, oz, SPACING, SEED, RES, OCT, FREQ, AMP)
			if h.size() != RES*RES:
				_fail("macro page empty at (%.0f,%.0f)" % [ox, oz]); break
			if not _all_finite(h):
				_fail("macro NaN/Inf at page (%.0f,%.0f)" % [ox, oz]); break
			max_relief = maxf(max_relief, _relief(h))
	if max_relief > 100.0:
		print("PASS: non-flat — max page relief %.1fm > 100m (macro has real ranges)" % max_relief)
	else:
		_fail("flat: max relief %.1fm <= 100m — macro looks flat/uniform (wiring/sample issue)" % max_relief)

	# 3. NO-TERRACING (the key quality assertion) on the interior fine page.
	var int_max_step := _max_step(a)
	var flat_run := _longest_flat_run(a)
	# (a) bounded adjacent step: no 256m bake walls (steep real slopes allowed).
	if int_max_step > 600.0:
		_fail("terrace/wall: interior max step %.1fm > 600 — bilinear not interpolating? (256m bake wall)" % int_max_step)
	else:
		print("PASS: no-terracing (step) — interior max step %.1fm within 600" % int_max_step)
	# (b) no plateau-then-jump: bilinear changes the height every cell, so the
	# longest near-flat run stays short. A 256m terrace = ~32 flat 8m cells.
	if flat_run >= 20:
		_fail("terrace (flat run): %d consecutive near-flat cells (>=20) — bilinear broken (plateau-then-jump)" % flat_run)
	else:
		print("PASS: no-terracing (flat run) — longest near-flat run %d cells (< 20)" % flat_run)

	# 4. SEAM: a page STRADDLING the region (0,*) | (1,*) border at x=29952.
	# origin_x = CORE_SPAN - PAGE_SPAN/2 puts the border near the page center;
	# r0x = floor(origin_x/CORE_SPAN) = 0, so the 2x2 block is regions (0..1, 0..1)
	# and the page crosses from region 0 into region 1 at x=29952 — exactly the seam.
	# origin_z = 0.0 keeps z interior.
	var seam_ox := CORE_SPAN - PAGE_SPAN / 2.0   # 29952 - 508 = 29444
	var s: PackedFloat32Array = fc.produce_macro_page(seam_ox, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	if s.size() != RES*RES:
		_fail("seam page size — produce_macro_page empty across border"); _finish(); return
	if not _all_finite(s): _fail("seam page has NaN/Inf")
	var seam_max_step := _max_step(s)
	# vs the oracle's 1076m walls: a straddling page must stay bounded (<600m).
	# Scope: this tests ONLY the x=CORE_SPAN boundary (z stays interior) — NOT a
	# full 2D seam proof. A z-boundary seam is out of step-2 scope.
	if seam_max_step > 600.0:
		_fail("SEAM WALL (x-boundary): straddling max step %.1fm > 600 (oracle was 1076) — border not converging" % seam_max_step)
	else:
		print("PASS: seam (x-boundary) bounded — straddling max step %.1fm within 600 (vs oracle's 1076m wall)" % seam_max_step)
	# Boundary convergence (Task-4 carry-forward): no special seam spike at the
	# border column — straddling max comparable to interior max. The <600 bound
	# above already proves no 1km wall; this guards a subtler localized seam jump.
	if seam_max_step < int_max_step * 2.0 + 50.0:
		print("PASS: boundary (x) converges — no seam spike (straddling %.1fm ~ interior %.1fm)" % [seam_max_step, int_max_step])
	else:
		_fail("seam spike (x-boundary): straddling %.1fm >> interior %.1fm (localized border jump)" % [seam_max_step, int_max_step])

	# 5. REGRESSION-FRIENDLY evidence for the human.
	print("INFO: macro live — max_relief=%.1fm  step(interior)=%.1fm  step(straddling,x-boundary)=%.1fm  longest_flat_run(both axes)=%d cells  [thresholds: relief>100, step<600, run<20]" % [max_relief, int_max_step, seam_max_step, flat_run])

	_finish()

func _finish() -> void:
	print("M2.4c macro live RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
