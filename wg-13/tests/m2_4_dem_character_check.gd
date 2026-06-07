extends SceneTree
# M2.4 gate - DEM character tuning. GUARDRAIL, not visual sign-off.
# Checks:
#   1. Determinism: same page+seed -> identical heights.
#   2. Character variation: page roughness and roughness/relief ratio vary across
#      a broad world scan, proving the field is not one-note.
#   3. Steep regions: the roughest pages are materially steeper than the gentlest.
#   4. Continuity: adjacent steps stay bounded (no cliff regression).
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_4_dem_character_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 8.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0

var _failed := false
func _fail(m: String) -> void:
	_failed = true
	print("FAIL: ", m)

func _page_stats(h: PackedFloat32Array) -> Dictionary:
	var min_h := h[0]
	var max_h := h[0]
	for v in h:
		min_h = minf(min_h, v)
		max_h = maxf(max_h, v)

	var sum_step := 0.0
	var max_step := 0.0
	var n := 0
	for z in range(RES):
		for x in range(RES - 1):
			var sx := absf(h[z * RES + x + 1] - h[z * RES + x])
			sum_step += sx
			max_step = maxf(max_step, sx)
			n += 1
	for z in range(RES - 1):
		for x in range(RES):
			var sz := absf(h[(z + 1) * RES + x] - h[z * RES + x])
			sum_step += sz
			max_step = maxf(max_step, sz)
			n += 1

	var relief := max_h - min_h
	var avg_step := sum_step / maxf(n, 1)
	return {
		"relief": relief,
		"avg_step": avg_step,
		"max_step": max_step,
		"rough_ratio": avg_step / maxf(relief, 1.0),
	}

func _avg(values: Array[float], start: int, end: int) -> float:
	var s := 0.0
	var n := 0
	for i in range(start, end):
		s += values[i]
		n += 1
	return s / maxf(n, 1)

func _init() -> void:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.initialize(SHADER):
		_fail("FieldCompute init failed (need vulkan / shader compile error)")
		_finish()
		return

	var a: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	var b: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	if a.size() != RES * RES:
		_fail("page size")
		_finish()
		return
	if a != b:
		_fail("determinism: same seed differs")
	else:
		print("PASS: determinism")

	var roughs: Array[float] = []
	var ratios: Array[float] = []
	var reliefs: Array[float] = []
	var scan_max_step := 0.0

	for iz in range(-8, 9):
		for ix in range(-8, 9):
			var h: PackedFloat32Array = fc.produce_page(ix * 4000.0, iz * 4000.0, SPACING, SEED, RES, OCT, FREQ, AMP)
			var st := _page_stats(h)
			roughs.append(st["avg_step"])
			ratios.append(st["rough_ratio"])
			reliefs.append(st["relief"])
			scan_max_step = maxf(scan_max_step, st["max_step"])

	# Include far-world visual-fail hotspots. The first M2.4 pass looked acceptable
	# around origin but produced corduroy cliffs around these live-review positions.
	var hotspots: Array[Vector2] = [
		Vector2(-164530.0, -62330.0),
		Vector2(-175629.0, -26099.0),
		Vector2(-39000.0, 30000.0),
		Vector2(39000.0, 30000.0),
	]
	for p in hotspots:
		var h_hot: PackedFloat32Array = fc.produce_page(p.x, p.y, SPACING, SEED, RES, OCT, FREQ, AMP)
		var st_hot := _page_stats(h_hot)
		roughs.append(st_hot["avg_step"])
		ratios.append(st_hot["rough_ratio"])
		reliefs.append(st_hot["relief"])
		scan_max_step = maxf(scan_max_step, st_hot["max_step"])

	roughs.sort()
	ratios.sort()
	reliefs.sort()

	var rough_lo := roughs[0]
	var rough_hi := roughs[roughs.size() - 1]
	var ratio_lo := ratios[0]
	var ratio_hi := ratios[ratios.size() - 1]
	var relief_lo := reliefs[0]
	var relief_hi := reliefs[reliefs.size() - 1]
	var third := roughs.size() / 3
	var gentle_avg := _avg(roughs, 0, third)
	var steep_avg := _avg(roughs, roughs.size() - third, roughs.size())
	var rough_spread := (rough_hi - rough_lo) / maxf(rough_hi, 1e-6)
	var ratio_spread := (ratio_hi - ratio_lo) / maxf(ratio_hi, 1e-6)
	var relief_spread := (relief_hi - relief_lo) / maxf(relief_hi, 1e-6)

	print("INFO: %d pages rough %.3f..%.3f spread=%.2f ratio %.5f..%.5f spread=%.2f relief %.1f..%.1f spread=%.2f max_step=%.1f" %
		[roughs.size(), rough_lo, rough_hi, rough_spread, ratio_lo, ratio_hi, ratio_spread, relief_lo, relief_hi, relief_spread, scan_max_step])

	if rough_spread > 0.55 and ratio_spread > 0.20:
		print("PASS: character variation - roughness and roughness/relief ratio vary across regions")
	else:
		_fail("character variation too low: rough_spread %.2f ratio_spread %.2f" % [rough_spread, ratio_spread])

	if steep_avg > gentle_avg * 1.8:
		print("PASS: steep regions - roughest third avg %.3f > gentlest third avg %.3f" % [steep_avg, gentle_avg])
	else:
		_fail("steep regions not distinct enough: rough %.3f vs %.3f" % [steep_avg, gentle_avg])

	if relief_spread > 0.50:
		print("PASS: M2.3 structure retained - relief spread %.2f" % relief_spread)
	else:
		_fail("M2.3 structure regressed: relief spread %.2f" % relief_spread)

	if scan_max_step < 180.0:
		print("PASS: no cliff - scan max step %.1f within 180" % scan_max_step)
	else:
		_fail("cliff: scan max step %.1f > 180" % scan_max_step)

	_finish()

func _finish() -> void:
	print("M2.4 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
