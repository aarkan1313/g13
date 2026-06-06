extends SceneTree
# M2.2 gate — biome assignment (nearest-centroid Whittaker over temp/moist/alt),
# proven by readback (00_ARCHITECTURE §2.1: the GPU output is the oracle).
#
# Proves, output-provably:
#   1. DETERMINISM — same world page + seed -> bit-identical biome ids (§5).
#   2. VALID IDS — every id is an integer in [0, biome_count) (no NaN/garbage,
#      no float-encoding drift; nearest-centroid is gapless so every cell maps).
#   3. CONTIGUITY (anti-"confetti", MILESTONE_2 §2) — within a page, adjacent
#      cells are almost always the SAME biome (borders are rare), and a single
#      508 m page holds only a FEW distinct biomes. Confetti would mean many
#      biomes per page and a high adjacent-differ rate.
#   4. GLOBAL VARIETY — across distant pages, MORE THAN ONE biome appears (the
#      classifier isn't collapsed onto a single biome everywhere).
#   5. SEED SENSITIVITY — a different seed changes the biome map (it's seeded).
#
# Run (GPU compute needs a real driver, NOT --headless — 01_TOOLCHAIN §4):
#   godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_2_biome_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 4.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0
const BIOME_COUNT := 10   # must match the Rust BIOME_CENTROIDS roster length

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

func _biomes(fc, ox: float, oz: float, seed: float) -> PackedFloat32Array:
	return fc.produce_biome_page(ox, oz, SPACING, seed, RES, OCT, FREQ, AMP)

# Set of distinct (rounded) ids in a page.
func _distinct(a: PackedFloat32Array) -> Dictionary:
	var d := {}
	for v in a:
		d[int(round(v))] = true
	return d

func _init() -> void:
	var fc = _make()
	if fc == null:
		_finish(); return

	var a := _biomes(fc, 0.0, 0.0, SEED)
	if a.size() != RES * RES:
		_fail("biome page size %d != %d" % [a.size(), RES * RES])
		_finish(); return

	# --- 1. determinism ---
	var b := _biomes(fc, 0.0, 0.0, SEED)
	if a != b:
		var diffs := 0
		for i in range(a.size()):
			if a[i] != b[i]: diffs += 1
		_fail("determinism: same seed produced different biome ids (%d/%d differ)" % [diffs, a.size()])
	else:
		print("PASS: determinism — same seed -> identical biome page (%d cells)" % a.size())

	# --- 2. valid ids: integer-encoded, in [0, BIOME_COUNT) ---
	var bad := false
	for i in range(a.size()):
		var v = a[i]
		if is_nan(v) or is_inf(v):
			_fail("valid ids: NaN/Inf at cell %d" % i); bad = true; break
		var id := int(round(v))
		if absf(v - float(id)) > 0.01:
			_fail("valid ids: cell %d not integer-encoded (%.4f)" % [i, v]); bad = true; break
		if id < 0 or id >= BIOME_COUNT:
			_fail("valid ids: cell %d id %d out of [0,%d)" % [i, id, BIOME_COUNT]); bad = true; break
	if not bad:
		print("PASS: valid ids — all cells integer ids in [0,%d)" % BIOME_COUNT)

	# --- 3. contiguity (anti-confetti) ---
	# Adjacent-differ rate: fraction of horizontally/vertically adjacent cell
	# pairs whose biome id differs. Large contiguous regions => only border cells
	# differ => a small rate. Confetti => a large rate.
	var pairs := 0
	var diff := 0
	for z in range(RES):
		for x in range(RES - 1):
			pairs += 1
			if int(round(a[z * RES + x])) != int(round(a[z * RES + x + 1])): diff += 1
	for z in range(RES - 1):
		for x in range(RES):
			pairs += 1
			if int(round(a[z * RES + x])) != int(round(a[(z + 1) * RES + x])): diff += 1
	var differ_rate := float(diff) / float(pairs)
	var distinct_here := _distinct(a).size()
	# Thresholds: a 508 m page is a fraction of the ~tens-of-km climate scale, so
	# it should be nearly one biome. Allow generous slack (this is a placeholder
	# field; M2.4 adds blending). > 15% adjacent-differ or > 5 biomes in one page
	# would read as confetti.
	if differ_rate > 0.15:
		_fail("contiguity: %.1f%% of adjacent cells differ (>15%% = confetti)" % [differ_rate * 100.0])
	elif distinct_here > 5:
		_fail("contiguity: %d distinct biomes in one 508m page (>5 = confetti)" % distinct_here)
	else:
		print("PASS: contiguity — %.2f%% adjacent differ, %d biomes in this page (large regions)" % [
			differ_rate * 100.0, distinct_here])

	# --- 4. global variety: sample distant pages, expect > 1 biome overall ---
	var global := {}
	var coords := [[0.0,0.0],[40000.0,0.0],[0.0,40000.0],[80000.0,80000.0],
		[-50000.0,20000.0],[20000.0,-60000.0],[-30000.0,-30000.0]]
	for c in coords:
		var pg := _biomes(fc, c[0], c[1], SEED)
		for id in _distinct(pg):
			global[id] = true
	if global.size() < 2:
		_fail("global variety: only %d biome(s) across the whole sampled world" % global.size())
	else:
		var ids := global.keys()
		ids.sort()
		print("PASS: global variety — %d distinct biomes across distant pages: %s" % [global.size(), str(ids)])

	# --- 5. seed sensitivity ---
	var c2 := _biomes(fc, 0.0, 0.0, 9999.0)
	if a == c2:
		_fail("seed sensitivity: different seed produced identical biome map")
	else:
		print("PASS: seed sensitivity — different seed -> different biome map")

	_finish()

func _finish() -> void:
	print("M2.2 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
