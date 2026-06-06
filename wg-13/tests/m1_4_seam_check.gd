extends SceneTree
# M1.4 gate — adjacent pages share their boundary edge to the bit.
# Proves the world-space sampling + shared-boundary-cell convention (00 §5.1):
# the east neighbor's column 0 == this page's column N-1 (same world X), and the
# south neighbor's row 0 == this page's row N-1. No stitching, no seam.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_4_seam_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 4.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0

# Shared-boundary-cell convention: page covers (RES-1)*SPACING; neighbor origin
# offsets by exactly that so the boundary cell is shared.
const STRIDE := (RES - 1) * SPACING

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _page(fc, ox, oz):
	return fc.produce_page(ox, oz, SPACING, SEED, RES, OCT, FREQ, AMP)

func _init() -> void:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null: _fail("FieldCompute not registered"); _finish(); return
	if not fc.initialize(SHADER): _fail("initialize failed (need vulkan driver)"); _finish(); return

	var p0 = _page(fc, 0.0, 0.0)             # page (0,0)
	var pe = _page(fc, STRIDE, 0.0)          # east neighbor (1,0)
	var ps = _page(fc, 0.0, STRIDE)          # south neighbor (0,1)

	if p0.size() != RES * RES:
		_fail("page size %d != %d" % [p0.size(), RES*RES]); _finish(); return

	# East seam: p0 column (RES-1) vs pe column 0, for every row z.
	var east_mismatch := 0
	var east_maxdiff := 0.0
	for z in range(RES):
		var a = p0[z * RES + (RES - 1)]
		var b = pe[z * RES + 0]
		if a != b:
			east_mismatch += 1
			east_maxdiff = max(east_maxdiff, abs(a - b))
	if east_mismatch == 0:
		print("PASS: east seam — %d shared-edge cells identical to the bit" % RES)
	else:
		_fail("east seam — %d/%d cells differ (max diff %.6f)" % [east_mismatch, RES, east_maxdiff])

	# South seam: p0 row (RES-1) vs ps row 0, for every column x.
	var south_mismatch := 0
	var south_maxdiff := 0.0
	for x in range(RES):
		var a = p0[(RES - 1) * RES + x]
		var b = ps[0 * RES + x]
		if a != b:
			south_mismatch += 1
			south_maxdiff = max(south_maxdiff, abs(a - b))
	if south_mismatch == 0:
		print("PASS: south seam — %d shared-edge cells identical to the bit" % RES)
	else:
		_fail("south seam — %d/%d cells differ (max diff %.6f)" % [south_mismatch, RES, south_maxdiff])

	# Sanity: the WRONG convention (stride = RES*SPACING) should NOT match — proves
	# the test has teeth and the convention is load-bearing.
	var pe_wrong = _page(fc, RES * SPACING, 0.0)
	var wrong_identical := true
	for z in range(RES):
		if p0[z * RES + (RES - 1)] != pe_wrong[z * RES + 0]:
			wrong_identical = false; break
	if wrong_identical:
		_fail("teeth check — wrong-stride edge ALSO matched (test not discriminating)")
	else:
		print("PASS: teeth check — wrong stride does NOT match (test is discriminating)")

	_finish()

func _finish() -> void:
	print("M1.4 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
