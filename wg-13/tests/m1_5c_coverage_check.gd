extends SceneTree
# M1.5c gate — never-black coverage. Simulates a TIGHT per-frame budget (so fine
# pages can't all be produced) and verifies the coarse blanket still covers the
# whole fine ring: every fine cell has a coarse page present beneath it. This is
# the structural guarantee that fast motion never shows sky/black (00 §3).
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_5c_coverage_check.gd

const SHADER := "res://shaders/field_height.glsl"
const LEVELS := 2
const R := 3              # ring radius per level
const TIGHT_BUDGET := 2   # deliberately too small to fill the fine ring fast

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	var pool = ClassDB.instantiate("PagePool")
	if pool == null: _fail("PagePool not registered"); _finish(); return
	if not pool.initialize(SHADER): _fail("initialize failed (need vulkan)"); _finish(); return
	pool.configure(64, 4.0, 1234.0, 4, 0.0015, 240.0, TIGHT_BUDGET)

	# Camera at origin. ONE frame, tight budget. Coarse (>0) eager, fine (0)
	# bounded — exactly as world_view does. The coarse blanket must fully exist
	# even though the tight budget starves the fine level.
	var have := {}          # "L:gx:gz" -> true (pages produced)
	pool.begin_frame()
	for level in range(LEVELS - 1, -1, -1):
		for gz in range(-R, R + 1):
			for gx in range(-R, R + 1):
				var t = (pool.request_page_eager(level, gx, gz) if level > 0
					else pool.request_page(level, gx, gz))
				if t != null:
					have["%d:%d:%d" % [level, gx, gz]] = true

	# Check: every cell of the FINE ring (level 0) is covered by SOME page —
	# either its own fine page, or the coarse page whose 2x footprint contains it.
	var coarse_span_ratio := 2    # level 1 page spans 2x level 0
	var uncovered := 0
	for gz in range(-R, R + 1):
		for gx in range(-R, R + 1):
			var fine_present: bool = have.has("0:%d:%d" % [gx, gz])
			# coarse page index containing fine (gx,gz): floor(gx/2), floor(gz/2)
			var cgx := int(floor(float(gx) / coarse_span_ratio))
			var cgz := int(floor(float(gz) / coarse_span_ratio))
			var coarse_present: bool = have.has("1:%d:%d" % [cgx, cgz])
			if not fine_present and not coarse_present:
				uncovered += 1

	if uncovered > 0:
		_fail("never-black: %d fine cells had NEITHER fine nor coarse coverage (would show black)" % uncovered)
	else:
		print("PASS: never-black — under tight budget, every fine cell is backed by fine or coarse coverage")

	# Sanity: the tight budget really did starve some fine pages (else the test
	# proves nothing). Count produced fine pages vs the full ring.
	var fine_ring := (2 * R + 1) * (2 * R + 1)
	var fine_made := 0
	for k in have.keys():
		if k.begins_with("0:"): fine_made += 1
	if fine_made >= fine_ring:
		print("INFO: budget wasn't tight enough to starve fine pages (%d/%d) — coverage still holds, but consider lowering budget" % [fine_made, fine_ring])
	else:
		print("PASS: budget genuinely starved fine pages (%d/%d produced) — coarse blanket carried the rest" % [fine_made, fine_ring])

	print("INFO: resident=%d produced=%d" % [pool.resident_count(), pool.total_produced()])
	_finish()

func _finish() -> void:
	print("M1.5c RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
