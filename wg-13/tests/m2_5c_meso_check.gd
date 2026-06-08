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
