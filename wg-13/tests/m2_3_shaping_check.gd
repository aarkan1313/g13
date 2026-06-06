extends SceneTree
# M2.3 gate — per-biome height shaping, proven by readback (00 §2.1).
#
# The point of M2.3: different biomes shape terrain differently — rugged biomes
# (mountain rock) are rough and tall, flat biomes (grassland/savanna) are smooth.
# We prove it OUTPUT-PROVABLY by measuring local roughness PER BIOME over a wide
# sampled area and asserting the rugged biome is markedly rougher than the flat
# ones. (The "looks like mountains" aesthetic is the human visual gate.)
#
# Proves:
#   1. DETERMINISM — same page+seed -> identical shaped height (§5; shaping is a
#      pure function of world pos + biome, biome is a pure function of world pos).
#   2. PER-BIOME ROUGHNESS DIFFERS — mean adjacent-height-delta for the rugged
#      biome (mountain rock, id 3) is much greater than for flat biomes
#      (grassland id 4, savanna id 8). This is the shaping actually taking effect.
#   3. CONTINUITY ACROSS BORDERS — no cliff: the max adjacent height step over the
#      whole area stays bounded (shared base => borders are roughness steps, not
#      elevation jumps).
#
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_3_shaping_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 4.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0
const RUGGED_ID := 3   # bare mountain rock (high detail_amp + rough)
const FLATTEST_ID := 4   # grassland (the designed-flattest biome, detail_amp 0.25)
# Rugged must be (a) the single roughest biome present, and (b) markedly rougher
# than the flattest. All biomes share the base landform (~1.2 roughness floor),
# so the biome's CONTRIBUTION is the detail on top; a 2.2x total ratio over the
# flattest is a clear, readable "mountains rugged, plains flat" difference.
const RUGGED_MIN_RATIO := 2.2

var _failed := false
func _fail(m: String) -> void:
	_failed = true
	print("FAIL: ", m)

func _make() -> RefCounted:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null:
		_fail("FieldCompute not registered"); return null
	if not fc.initialize(SHADER):
		_fail("FieldCompute.initialize() false (need vulkan)"); return null
	return fc

func _init() -> void:
	var fc = _make()
	if fc == null:
		_finish(); return

	# --- 1. determinism (shaped height) ---
	var h0: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	var h1: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	if h0.size() != RES * RES:
		_fail("page size %d != %d" % [h0.size(), RES * RES]); _finish(); return
	if h0 != h1:
		_fail("determinism: same seed -> different shaped height"); _finish(); return
	print("PASS: determinism — shaped height reproduces identically")

	# --- 2/3. per-biome roughness over a wide area ---
	# For each cell, local roughness = |h(right)-h| + |h(down)-h|; accumulate by
	# the cell's biome id. Sample many pages so the rugged + flat biomes all occur.
	var rough_sum := {}     # id -> summed roughness
	var rough_cnt := {}     # id -> cell count
	var max_step := 0.0
	var coords := []
	for iz in range(-3, 4):
		for ix in range(-3, 4):
			coords.append([ix * 12000.0, iz * 12000.0])
	for c in coords:
		var h: PackedFloat32Array = fc.produce_page(c[0], c[1], SPACING, SEED, RES, OCT, FREQ, AMP)
		var b: PackedFloat32Array = fc.produce_biome_page(c[0], c[1], SPACING, SEED, RES, OCT, FREQ, AMP)
		for z in range(RES - 1):
			for x in range(RES - 1):
				var i := z * RES + x
				var hv = h[i]
				if is_nan(hv) or is_inf(hv):
					_fail("NaN/Inf height in shaped page"); _finish(); return
				var dr = absf(h[i + 1] - hv)
				var dd = absf(h[i + RES] - hv)
				max_step = maxf(max_step, maxf(dr, dd))
				var id := int(round(b[i]))
				rough_sum[id] = rough_sum.get(id, 0.0) + dr + dd
				rough_cnt[id] = rough_cnt.get(id, 0) + 1

	# Mean roughness per biome present.
	var mean := {}
	for id in rough_cnt:
		if rough_cnt[id] > 200:   # ignore biomes with too few cells to be meaningful
			mean[id] = rough_sum[id] / rough_cnt[id]
	var ids := mean.keys(); ids.sort()
	for id in ids:
		print("INFO: biome %d mean local roughness %.3f (%d cells)" % [id, mean[id], rough_cnt[id]])

	# Rugged biome must be (a) present, (b) the single roughest biome, and (c)
	# markedly rougher than the flattest designed-flat biome.
	if not mean.has(RUGGED_ID):
		_fail("rugged biome %d not present in sample (can't prove shaping)" % RUGGED_ID)
	elif not mean.has(FLATTEST_ID):
		_fail("flattest biome %d not present to compare against" % FLATTEST_ID)
	else:
		var rugged: float = mean[RUGGED_ID]
		var flattest: float = mean[FLATTEST_ID]
		# (b) rugged is the maximum-roughness biome present.
		var is_max := true
		for id in mean:
			if mean[id] > rugged:
				is_max = false
		if not is_max:
			_fail("shaping: rugged biome %.3f is not the roughest biome present" % rugged)
		elif rugged < flattest * RUGGED_MIN_RATIO:
			_fail("shaping too weak: rugged %.3f not >= %.1fx flattest %.3f" % [rugged, RUGGED_MIN_RATIO, flattest])
		else:
			print("PASS: per-biome shaping — rugged %.3f is the roughest AND >= %.1fx flattest %.3f (mountains rugged, plains flat)" % [
				rugged, RUGGED_MIN_RATIO, flattest])

	# --- 3. continuity: no cliff across borders ---
	# A generous bound: a single adjacent step shouldn't exceed a large fraction of
	# the amplitude (shared base => borders are roughness steps, not jumps).
	var limit := AMP * 0.5
	if max_step > limit:
		_fail("continuity: max adjacent step %.2f exceeds %.2f (border cliff?)" % [max_step, limit])
	else:
		print("PASS: continuity — max adjacent step %.2f within %.2f (no border cliff)" % [max_step, limit])

	_finish()

func _finish() -> void:
	print("M2.3 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
