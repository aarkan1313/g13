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
