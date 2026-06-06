extends SceneTree
# M2.1 gate — climate fields (temperature + moisture) on the real GPU path,
# proven by readback (00_ARCHITECTURE §2.1: the GPU output is the oracle).
#
# Proves, output-provably:
#   1. DETERMINISM — same world page + seed -> bit-identical temp/moisture (the
#      §5 rule: same world pos + seed => same answer, always).
#   2. SEED SENSITIVITY — a different seed yields different climate.
#   3. RANGE — temperature and moisture are normalized in [0,1] (no NaN/Inf/garbage).
#   4. LOW FREQUENCY (anti-"Perlin confetti", MILESTONE_2 §2) — climate varies
#      SMOOTHLY: the largest step between adjacent cells is tiny vs the full range,
#      so biomes (M2.2) will come out large and contiguous, never per-cell noise.
#   5. LATITUDE GRADIENT — temperature changes meaningfully across a large world-Z
#      span (the Earth-like band is real, not a flat constant). Altitude coupling
#      and the moisture axis are exercised by the range + determinism checks.
#
# Run (GPU compute needs a real driver, NOT --headless — 01_TOOLCHAIN §4):
#   godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_1_climate_check.gd
# Prints PASS/FAIL; exit 0 = pass.

const SHADER := "res://shaders/field_height.glsl"
const RES := 128         # page resolution (cells/side)
const SPACING := 4.0     # world units between cells
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0

var _failed := false
func _fail(m: String) -> void:
	_failed = true
	print("FAIL: ", m)

func _make() -> RefCounted:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null:
		_fail("FieldCompute not registered (extension not loaded?)"); return null
	if not fc.initialize(SHADER):
		_fail("FieldCompute.initialize() false (no GPU / shader error?)"); return null
	return fc

# Returns interleaved [temp, moisture] per cell (2*RES*RES floats).
func _climate(fc, ox: float, oz: float, seed: float) -> PackedFloat32Array:
	return fc.produce_climate_page(ox, oz, SPACING, seed, RES, OCT, FREQ, AMP)

func _init() -> void:
	var fc = _make()
	if fc == null:
		_finish(); return

	var a := _climate(fc, 0.0, 0.0, SEED)
	if a.size() != RES * RES * 2:
		_fail("climate page size %d != %d (2 channels)" % [a.size(), RES * RES * 2])
		_finish(); return

	# --- 1. determinism: same page+seed twice -> identical bytes ---
	var b := _climate(fc, 0.0, 0.0, SEED)
	if a != b:
		var diffs := 0
		for i in range(a.size()):
			if a[i] != b[i]:
				diffs += 1
		_fail("determinism: same seed produced different climate (%d/%d values differ)" % [diffs, a.size()])
	else:
		print("PASS: determinism — same seed -> identical climate page (%d values)" % a.size())

	# --- 2. seed sensitivity ---
	var c := _climate(fc, 0.0, 0.0, 9999.0)
	if a == c:
		_fail("seed sensitivity: different seed produced identical climate")
	else:
		print("PASS: seed sensitivity — different seed -> different climate")

	# --- 3. range: temp/moisture in [0,1], no NaN/Inf ---
	var tmin := 1e30; var tmax := -1e30
	var mmin := 1e30; var mmax := -1e30
	var bad := false
	for i in range(RES * RES):
		var tv = a[i * 2]
		var mv = a[i * 2 + 1]
		if is_nan(tv) or is_inf(tv) or is_nan(mv) or is_inf(mv):
			_fail("range: NaN/Inf in climate at cell %d" % i); bad = true; break
		tmin = minf(tmin, tv); tmax = maxf(tmax, tv)
		mmin = minf(mmin, mv); mmax = maxf(mmax, mv)
	if not bad:
		if tmin < 0.0 or tmax > 1.0 or mmin < 0.0 or mmax > 1.0:
			_fail("range: out of [0,1] — temp [%.3f,%.3f] moist [%.3f,%.3f]" % [tmin, tmax, mmin, mmax])
		else:
			print("PASS: range — temp [%.3f,%.3f], moist [%.3f,%.3f] all in [0,1]" % [tmin, tmax, mmin, mmax])

	# --- 4. low frequency: max adjacent-cell step is tiny (smooth, not confetti) ---
	# A single 508 m page spans a small fraction of the climate feature scale
	# (~tens of km), so neighboring cells must be nearly identical. A large step
	# would mean high-frequency noise leaked in (the confetti failure mode).
	var max_t_step := 0.0
	var max_m_step := 0.0
	for z in range(RES):
		for x in range(RES - 1):
			var i0 := (z * RES + x) * 2
			var i1 := (z * RES + x + 1) * 2
			max_t_step = maxf(max_t_step, absf(a[i1] - a[i0]))
			max_m_step = maxf(max_m_step, absf(a[i1 + 1] - a[i0 + 1]))
	# Also check the Z direction (north-south, where the latitude term lives).
	for z in range(RES - 1):
		for x in range(RES):
			var i0 := (z * RES + x) * 2
			var i1 := ((z + 1) * RES + x) * 2
			max_t_step = maxf(max_t_step, absf(a[i1] - a[i0]))
			max_m_step = maxf(max_m_step, absf(a[i1 + 1] - a[i0 + 1]))
	# Generous threshold: well under 5% of full range across one cell. (Observed
	# steps are ~0.001; this catches a frequency that's orders of magnitude off.)
	var step_limit := 0.05
	if max_t_step > step_limit or max_m_step > step_limit:
		_fail("low-freq: adjacent step too large — temp %.4f, moist %.4f exceed %.2f (confetti?)" % [
			max_t_step, max_m_step, step_limit])
	else:
		print("PASS: low frequency — max adjacent step temp %.4f / moist %.4f << %.2f (smooth)" % [
			max_t_step, max_m_step, step_limit])

	# --- 5. latitude gradient: temperature changes across a large world-Z span ---
	# Sample the page-(0,0) corner temp vs a page far to the "north" (large +Z).
	# The latitude band has a ~120 km period; ~30 km apart must differ clearly.
	var north := _climate(fc, 0.0, 30000.0, SEED)
	var t_here := a[0]                       # temp at world (0,0)
	var t_north := north[0]                  # temp at world (0, 30000)
	var lat_delta := absf(t_north - t_here)
	if lat_delta < 0.05:
		_fail("latitude: temp barely changed over 30 km (%.4f) — gradient missing/too weak" % lat_delta)
	else:
		print("PASS: latitude gradient — temp shifts %.3f over 30 km of world-Z (band is real)" % lat_delta)

	_finish()

func _finish() -> void:
	print("M2.1 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
