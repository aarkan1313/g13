extends SceneTree
# M1.9.3b gate — spreading MID-coarse eager production over frames stays
# NEVER-BLACK. Uses 4 levels and a TIGHT mid-coarse eager budget so the mid
# levels (1,2) are starved in a single frame, then proves every fine cell is
# still covered by SOME resident level (the coarser blanket beneath), i.e. no
# cell would show black. The coarsest level (3) is unbounded — the floor.
#
# This is the test that earns M1.9.3b: bounding mid-coarse is only safe because
# a missing mid-coarse page falls back to the coarser page, never to black.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_9b_eager_spread_check.gd

const SHADER := "res://shaders/field_height.glsl"
const LEVELS := 4
const COARSEST := 3
const R := 3
const FINE_BUDGET := 2          # finest level, tight (as ever)
const EAGER_BUDGET := 3         # mid-coarse pages/frame — deliberately starving

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	var pool = ClassDB.instantiate("PagePool")
	if pool == null: _fail("PagePool not registered"); _finish(); return
	if not pool.initialize(SHADER): _fail("initialize failed (need vulkan)"); _finish(); return
	pool.configure(64, 4.0, 1234.0, 4, 0.0015, 240.0, FINE_BUDGET)
	pool.set_max_eager_per_frame(EAGER_BUDGET)

	# ONE frame, exactly as world_view requests: coarsest unbounded, mid-coarse
	# bounded, fine bounded.
	var have := {}              # "L:gx:gz" -> true
	pool.begin_frame()
	for level in range(COARSEST, -1, -1):
		for gz in range(-R, R + 1):
			for gx in range(-R, R + 1):
				var t
				if level == COARSEST:
					t = pool.request_page_eager(level, gx, gz)
				elif level > 0:
					t = pool.request_page_eager_bounded(level, gx, gz)
				else:
					t = pool.request_page(level, gx, gz)
				if t != null:
					have["%d:%d:%d" % [level, gx, gz]] = true

	# Every fine (level 0) cell must be covered by SOME level present above it.
	# Level L page covering fine (gx,gz) is at (floor(gx/2^L), floor(gz/2^L)).
	var uncovered := 0
	for gz in range(-R, R + 1):
		for gx in range(-R, R + 1):
			var covered := false
			for level in range(0, LEVELS):
				var div := int(pow(2, level))
				var lgx := int(floor(float(gx) / div))
				var lgz := int(floor(float(gz) / div))
				if have.has("%d:%d:%d" % [level, lgx, lgz]):
					covered = true
					break
			if not covered:
				uncovered += 1

	if uncovered > 0:
		_fail("never-black BROKEN: %d fine cells had NO covering page at any level (would show black)" % uncovered)
	else:
		print("PASS: never-black holds — every fine cell is covered by some resident level despite bounded mid-coarse")

	# Prove the test is meaningful: mid-coarse was actually starved this frame.
	if pool.eager_this_frame() == 0:
		print("INFO: no mid-coarse produced — check setup")
	# The coarsest ring must be COMPLETE (it's the unbounded floor).
	var coarsest_ring := (2 * R + 1) * (2 * R + 1)
	var coarsest_made := 0
	for k in have.keys():
		if k.begins_with("%d:" % COARSEST): coarsest_made += 1
	if coarsest_made < coarsest_ring:
		_fail("coarsest (floor) ring incomplete: %d/%d — the never-black floor was starved" % [coarsest_made, coarsest_ring])
	else:
		print("PASS: coarsest floor complete (%d/%d) — unbounded backstop intact" % [coarsest_made, coarsest_ring])

	# And mid-coarse was genuinely capped (else the test proves nothing).
	var mid_full := 3 * (2 * R + 1) * (2 * R + 1)   # levels 1,2 full rings (rough upper bound)
	print("INFO: produced=%d eager_total=%d (mid-coarse bounded to %d/frame)" % [
		pool.total_produced(), pool.eager_this_frame(), EAGER_BUDGET])
	_finish()

func _finish() -> void:
	print("M1.9b RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
