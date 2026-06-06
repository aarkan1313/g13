extends SceneTree
# M1.5b gate — camera-following streaming invariants, driven directly on the pool
# (no rendering needed). Simulates the camera walking east across many pages and
# checks: residency stays bounded, eviction happens, pinned pages never evicted,
# production stays under budget.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_5b_stream_check.gd

const SHADER := "res://shaders/field_height.glsl"
const R := 3            # ring radius
const KEEP := 4         # keep radius (ring + margin)
const MAXNEW := 8       # generous so the ring can fill within a few sim-frames

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	var pool = ClassDB.instantiate("PagePool")
	if pool == null: _fail("PagePool not registered"); _finish(); return
	if not pool.initialize(SHADER): _fail("initialize failed (need vulkan)"); _finish(); return
	pool.configure(64, 4.0, 1234.0, 4, 0.0015, 240.0, MAXNEW)

	var displayed := {}     # "gx:gz" -> true, the view's mesh set (simulated)
	var max_resident := 0
	var ring_cells := (2 * R + 1) * (2 * R + 1)

	# Walk the camera east over 40 page-steps. Each step = several frames so the
	# bounded pool can fill the ring; we run a few begin_frame cycles per step.
	for step in range(40):
		var ccx := step      # camera centered on page (step, 0)
		var ccz := 0
		# Let the ring fill over up to 8 frames at this position.
		for _frame in range(8):
			pool.begin_frame()
			# request ring
			for gz in range(ccz - R, ccz + R + 1):
				for gx in range(ccx - R, ccx + R + 1):
					var t = pool.request_page(0, gx, gz)
					if t != null:
						displayed["%d:%d" % [gx, gz]] = true
			# bound check every frame
			if pool.produced_this_frame() > MAXNEW:
				_fail("frame produced %d > cap %d" % [pool.produced_this_frame(), MAXNEW])
			# correct order (mirrors world_view): drop stale meshes -> pin -> evict
			# 1. drop simulated meshes outside keep radius (camera moved)
			for k in displayed.keys():
				var p2: PackedStringArray = k.split(":")
				var cheb: int = maxi(absi(int(p2[0]) - ccx), absi(int(p2[1]) - ccz))
				if cheb > KEEP:
					displayed.erase(k)
			# 2. pin everything still displayed (all inside keep zone now)
			for k in displayed.keys():
				var p: PackedStringArray = k.split(":")
				pool.pin_page(0, int(p[0]), int(p[1]))
			# 3. evict pool pages outside keep radius (none pinned)
			pool.evict_outside(0, ccx, ccz, KEEP)
		max_resident = maxi(max_resident, pool.resident_count())

	# --- invariants ---
	if pool.had_pin_violation():
		_fail("a PINNED (displayed) page was targeted for eviction")
	else:
		print("PASS: pins honored — no displayed page was ever evicted")

	if pool.evicted_count() <= 0:
		_fail("nothing was ever evicted despite 40 pages of travel (leak)")
	else:
		print("PASS: eviction occurred — %d pages evicted over the walk" % pool.evicted_count())

	# Residency must stay bounded ~ (2*KEEP+1)^2, not grow with distance traveled.
	var bound := (2 * KEEP + 1) * (2 * KEEP + 1)
	if pool.resident_count() > bound:
		_fail("residency %d exceeds bound %d (memory not flat)" % [pool.resident_count(), bound])
	else:
		print("PASS: bounded residency — %d resident <= %d (flat memory)" % [pool.resident_count(), bound])

	print("INFO: ring_cells=%d max_resident=%d evicted=%d produced=%d" % [
		ring_cells, max_resident, pool.evicted_count(), pool.total_produced()])
	_finish()

func _finish() -> void:
	print("M1.5b RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
