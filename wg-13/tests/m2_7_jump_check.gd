extends SceneTree
# M2.7 (quick-fix guard) — JUMP works: pressing Space while grounded launches the
# capsule upward and it then falls back under gravity. Regression test for the user
# report "still not jumping or falling". Drives the REAL input path: injects a
# physical Space key event via Input.parse_input_event (so is_key_pressed(KEY_SPACE)
# reads true, exactly as a live keypress), runs physics, and asserts:
#   1. capsule LEAVES the ground (y rises by a clear margin, is_on_floor goes false)
#   2. capsule FALLS back and re-lands (y returns near the floor, on_floor true)
# Run: <console> --rendering-driver vulkan --path wg-13 --script res://tests/m2_7_jump_check.gd

const DEMO := "res://scenes/demo.tscn"

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _press_space(pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_SPACE
	ev.physical_keycode = KEY_SPACE
	ev.pressed = pressed
	Input.parse_input_event(ev)

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

	# Drop onto the origin page and let it settle on the ground.
	var span: float = (view.page_res - 1) * view.spacing
	var drop_xz := Vector3(span * 0.5, 0.0, span * 0.5)
	var fly_cam: Camera3D = view._cam
	fly_cam.global_position = Vector3(drop_xz.x, view.amplitude * 2.0, drop_xz.z)
	player._enter_walk()
	var grounded_y := 1e30
	for _i in range(240):
		await physics_frame
		if player.is_on_floor():
			grounded_y = player.global_position.y
			break
	if grounded_y > 1e29:
		_fail("capsule never settled on the ground before jump test"); _finish(rootn); return
	print("INFO: settled on ground at y=%.2f, on_floor=%s" % [grounded_y, str(player.is_on_floor())])

	# --- JUMP: hold Space for a few frames, then release. ---
	_press_space(true)
	var peak_y := grounded_y
	var went_airborne := false
	for _i in range(8):
		await physics_frame
		peak_y = maxf(peak_y, player.global_position.y)
		if not player.is_on_floor():
			went_airborne = true
	_press_space(false)
	# Let it arc up + fall back down.
	for _i in range(180):
		await physics_frame
		peak_y = maxf(peak_y, player.global_position.y)
		if player.is_on_floor() and player.global_position.y < peak_y - 1.0:
			break
	var rise := peak_y - grounded_y
	print("INFO: after Space — peak_y=%.2f (rose %.2fm), airborne_seen=%s, landed_on_floor=%s final_y=%.2f" % [
		peak_y, rise, str(went_airborne), str(player.is_on_floor()), player.global_position.y])

	# 1. Did it actually jump (leave the ground by a clear margin)?
	if rise < 2.0:
		_fail("JUMP did nothing: capsule rose only %.2fm on Space (expected a real hop)" % rise)
	else:
		print("PASS: jump launches — capsule rose %.2fm and went airborne" % rise)

	# 2. Did it come back down (gravity)?
	if not player.is_on_floor():
		_fail("capsule did not land back after the jump (still airborne / floating)")
	else:
		print("PASS: gravity returns it — capsule fell back and re-landed on the floor")

	_finish(rootn)

func _finish(rootn) -> void:
	if rootn != null:
		rootn.queue_free()
	print("M2.7-jump RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
