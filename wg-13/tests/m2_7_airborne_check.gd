extends SceneTree
# M2.7 (quick-fix guard) — cresting a bump at speed produces a real BALLISTIC ARC,
# not floor-snap glue. Regression test for the "run fast, hit a bump, never fall,
# just stay at terrain height" bug: floor_snap_length was 6m, which yanked the
# capsule back to the surface every frame so it never went airborne.
#
# Method: drop the capsule onto resident terrain, then drive it HORIZONTALLY at
# high speed (turbo) across the terrain for a while. Over undulating ground at
# speed, a real character MUST leave the floor on at least some crests (is_on_floor
# false for a stretch) and its Y must deviate from a pure ground-follow. If the
# capsule stays is_on_floor() EVERY frame for the whole fast run, floor-snap is
# gluing it (the bug). We assert it goes airborne at least a few frames.
# Run: <console> --rendering-driver vulkan --path wg-13 --script res://tests/m2_7_airborne_check.gd

const DEMO := "res://scenes/demo.tscn"

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	var scene: PackedScene = load(DEMO)
	if scene == null: _fail("could not load demo.tscn"); _finish(null); return
	var rootn: Node = scene.instantiate()
	root.add_child(rootn)

	var view: Node3D = rootn.get_node("View")
	var player: CharacterBody3D = rootn.get_node("Player")
	if view == null or player == null:
		_fail("demo.tscn missing View or Player"); _finish(rootn); return

	for _i in range(40):
		await process_frame
	if view._collisions.is_empty():
		_fail("no collision bodies after warmup (need vulkan + M1.7b)"); _finish(rootn); return

	# Drop onto the origin page.
	var span: float = (view.page_res - 1) * view.spacing
	var drop_xz := Vector3(span * 0.5, 0.0, span * 0.5)
	var fly_cam: Camera3D = view._cam
	fly_cam.global_position = Vector3(drop_xz.x, view.amplitude * 2.0, drop_xz.z)
	player._enter_walk()

	# Let it settle first.
	for _i in range(180):
		await physics_frame
		if player.is_on_floor():
			break

	# Now drive it FAST horizontally (turbo + forward) across the terrain and watch
	# whether it ever leaves the floor. auto_move is a local-space dir (-z = forward).
	player._turbo = true
	player.auto_move = Vector3(0.0, 0.0, -1.0)
	var airborne_frames := 0
	var total := 0
	var y_min := 1e30
	var y_max := -1e30
	for _i in range(360):                 # ~6s of fast travel
		await physics_frame
		total += 1
		if not player.is_on_floor():
			airborne_frames += 1
		y_min = minf(y_min, player.global_position.y)
		y_max = maxf(y_max, player.global_position.y)
	player.auto_move = Vector3.ZERO
	player._turbo = false

	print("INFO: fast run %d frames, airborne %d, y range %.1f..%.1f (span %.1f)" % [
		total, airborne_frames, y_min, y_max, y_max - y_min])

	# The bug: airborne_frames == 0 (glued every frame). A real arc leaves the floor
	# on crests. Require at least a handful of airborne frames over a 6s fast run.
	if airborne_frames >= 5:
		print("PASS: real arcs — capsule left the floor %d frames over the fast run (not glued)" % airborne_frames)
	else:
		_fail("floor-snap GLUE: capsule stayed on_floor every frame (airborne=%d) — bumps don't launch it" % airborne_frames)

	_finish(rootn)

func _finish(rootn) -> void:
	if rootn != null:
		rootn.queue_free()
	print("M2.7-airborne RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
