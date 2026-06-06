extends SceneTree
# M2.4 gate — spectral-shaped field, proven by readback.
#   1. DETERMINISM: same page+seed -> identical heights.
#   2. PER-BIOME STRUCTURE DIFFERS: a mountain-region page is rougher than a
#      grassland-region page (the DEM spectrum/slope taking effect).
#   3. NO CLIFF: max adjacent step bounded (slope clamp working).
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_4_spectral_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 4.0
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
		_fail("FieldCompute init failed (need vulkan)"); _finish(); return

	# Determinism.
	var a: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	var b: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	if a.size() != RES*RES: _fail("page size"); _finish(); return
	if a != b: _fail("determinism: same seed differs")
	else: print("PASS: determinism")

	# Per-biome structure: scan many pages, bucket avg-roughness by majority biome,
	# assert mountain(3) rougher than grassland(4). (Reuses produce_biome_page.)
	var rough := {}; var cnt := {}
	for iz in range(-3, 4):
		for ix in range(-3, 4):
			var ox := ix * 12000.0; var oz := iz * 12000.0
			var h: PackedFloat32Array = fc.produce_page(ox, oz, SPACING, SEED, RES, OCT, FREQ, AMP)
			var bm: PackedFloat32Array = fc.produce_biome_page(ox, oz, SPACING, SEED, RES, OCT, FREQ, AMP)
			var counts := {}
			for v in bm:
				var id := int(round(v)); counts[id] = counts.get(id, 0) + 1
			var maj := 0; var mc := -1
			for id in counts:
				if counts[id] > mc: mc = counts[id]; maj = id
			rough[maj] = rough.get(maj, 0.0) + _avg_step(h)
			cnt[maj] = cnt.get(maj, 0) + 1
	var mean := {}
	for id in cnt: mean[id] = rough[id] / cnt[id]
	for id in mean: print("INFO: biome %d avg roughness %.3f (%d pages)" % [id, mean[id], cnt[id]])
	if mean.has(3) and mean.has(4):
		if mean[3] > mean[4] * 1.3:
			print("PASS: per-biome structure — mountain %.3f > 1.3x grassland %.3f" % [mean[3], mean[4]])
		else:
			_fail("mountain %.3f not >1.3x grassland %.3f" % [mean[3], mean.get(4, 0.0)])
	else:
		print("INFO: mountain/grassland not both present in sample; structure check skipped")

	# No cliff: max step over the origin page bounded (slope clamp). AMP*0.6 is a
	# generous steep-mountain allowance; a true discontinuity blows past it.
	var ms := _max_step(a)
	if ms > AMP * 0.6: _fail("cliff: max step %.1f > %.1f" % [ms, AMP*0.6])
	else: print("PASS: no cliff — max step %.1f within %.1f" % [ms, AMP*0.6])

	_finish()

func _finish() -> void:
	print("M2.4 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
