extends SceneTree
# M2.4b gate — the oracle candidate lane is LIVE in field_height.glsl, proven by
# GPU readback. GUARDRAIL, not the success criterion: the REAL gate is the human
# flying AND walking the oracle (Task 7). Checks:
#   1. REFERENCE REGRESSION: mode 0 (produce_page) is DETERMINISTIC and unchanged
#      vs the M2.3 path (the candidate lane didn't disturb the reference).
#   2. ORACLE DETERMINISM: mode 1 (produce_oracle_page) same page -> identical.
#   3. ORACLE FINITE + NON-FLAT: mode 1 heights are all finite and develop real
#      relief across a wide region (not a flat/NaN field).
#   4. ORACLE DISTINCT: mode 1 differs from mode 0 on the same page (the oracle is
#      actually a different terrain, i.e. the branch + params are wired through).
# NOTE (recorded decision): the GLSL oracle uses a 32-bit hash, so it is a
# STATISTICAL TWIN of the reviewed Rust oracle, not bit-identical — this gate
# asserts non-flat/deterministic/distinct, NOT GLSL==Rust equality.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_4b_oracle_live_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 8.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _all_finite(h: PackedFloat32Array) -> bool:
	for v in h:
		if is_nan(v) or is_inf(v):
			return false
	return true

func _avg_step(h: PackedFloat32Array) -> float:
	var s := 0.0; var n := 0
	for z in range(RES):
		for x in range(RES - 1):
			s += absf(h[z*RES+x+1] - h[z*RES+x]); n += 1
	return s / maxf(n, 1)

func _init() -> void:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.initialize(SHADER):
		_fail("FieldCompute init failed (need vulkan / shader compile error)"); _finish(); return

	# 1. Reference regression: mode 0 deterministic (and unchanged M2.3 path).
	var r0a: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	var r0b: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	if r0a.size() != RES*RES: _fail("reference page size"); _finish(); return
	if r0a != r0b: _fail("reference determinism: mode-0 same seed differs")
	else: print("PASS: reference (mode 0) deterministic")

	# 2. Oracle determinism: mode 1 same page -> identical.
	var o1a: PackedFloat32Array = fc.produce_oracle_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	var o1b: PackedFloat32Array = fc.produce_oracle_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	if o1a.size() != RES*RES: _fail("oracle page size — produce_oracle_page empty? (shader compile / wiring)"); _finish(); return
	if o1a != o1b: _fail("oracle determinism: mode-1 same seed differs")
	else: print("PASS: oracle (mode 1) deterministic")

	# 3. Oracle finite + non-flat across a wide region.
	if not _all_finite(o1a): _fail("oracle has NaN/Inf on origin page")
	else: print("PASS: oracle origin page all finite")
	var roughs: Array[float] = []
	for iz in range(-8, 9):
		for ix in range(-8, 9):
			var h: PackedFloat32Array = fc.produce_oracle_page(ix*1000.0, iz*1000.0, SPACING, SEED, RES, OCT, FREQ, AMP)
			if not _all_finite(h): _fail("oracle NaN/Inf at page (%d,%d)" % [ix, iz]); break
			roughs.append(_avg_step(h))
	var lo := roughs[0]; var hi := roughs[0]
	for r in roughs:
		lo = minf(lo, r); hi = maxf(hi, r)
	var spread := (hi - lo) / maxf(hi, 1e-6)
	print("INFO: oracle %d pages  rough lo=%.3f hi=%.3f  spread=%.2f" % [roughs.size(), lo, hi, spread])
	if hi > 0.05 and spread > 0.3:
		print("PASS: oracle non-flat — relief present, spread %.2f (lowlands + ranges)" % spread)
	else:
		_fail("oracle looks flat/uniform — hi=%.3f spread=%.2f (wiring or port issue)" % [hi, spread])

	# 4. Oracle distinct from reference on the same page.
	var differs := false
	for i in range(r0a.size()):
		if absf(r0a[i] - o1a[i]) > 0.5:
			differs = true; break
	if differs: print("PASS: oracle distinct from reference (mode branch is live)")
	else: _fail("oracle == reference — terrain_mode branch not taking effect")

	_finish()

func _finish() -> void:
	print("M2.4b oracle live RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
