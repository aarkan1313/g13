extends SceneTree
# M1.7c gate (output-provable core) — the capsule DROPS ONTO the terrain and
# COMES TO REST on the surface, instead of falling through. Loads the real
# demo.tscn (WorldRoot + world_view + player capsule), waits for collision to
# stream in, enters WALK, lets gravity act, then asserts the capsule settled at
# ~terrain height with is_on_floor() true.
#
# This proves the "doesn't fall through" core without eyes. The remaining VISUAL
# part (does walking FEEL right, does it hold on a freshly-streamed page as you
# fly) is parked for the human in DRIFT_LOG.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_7c_stand_check.gd

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
		_fail("demo.tscn missing View or Player node"); _finish(rootn); return

	# Let terrain + level-0 collision stream in around origin.
	for _i in range(40):
		await process_frame
	if view._collisions.is_empty():
		_fail("no collision bodies built after warmup (need vulkan + M1.7b)")
		_finish(rootn); return

	# Place the fly-cam (and thus the drop point) over the origin page, well above
	# the terrain, then enter WALK so the capsule falls onto the surface there.
	var span: float = (view.page_res - 1) * view.spacing
	var drop_xz := Vector3(span * 0.5, 0.0, span * 0.5)   # centre of page (0,0)
	var fly_cam: Camera3D = view._cam
	fly_cam.global_position = Vector3(drop_xz.x, view.amplitude * 2.0, drop_xz.z)
	player._enter_walk()                                   # snaps capsule under the fly-cam, gravity on

	# Sample the resident terrain height at the drop column (from the SAME pool
	# heights collision uses) so we know where the floor should be.
	var heights: PackedFloat32Array = view._pool.get_page_heights(0, 0, 0)
	if heights.size() != view.page_res * view.page_res:
		_fail("origin page heights not resident for the expected floor calc"); _finish(rootn); return
	# Cell nearest the drop XZ within page (0,0): index from world->cell.
	var cx: int = clampi(int(round(drop_xz.x / view.spacing)), 0, view.page_res - 1)
	var cz: int = clampi(int(round(drop_xz.z / view.spacing)), 0, view.page_res - 1)
	var floor_h: float = heights[cz * view.page_res + cx]

	# Let it fall and settle. Log the trajectory so a "didn't reach the floor"
	# failure is distinguishable from "fell through".
	var settled_y := 999999.0
	var start_y: float = player.global_position.y
	for _i in range(600):                                  # up to ~10s of physics at 60hz
		await physics_frame
		settled_y = player.global_position.y
		if _i % 60 == 0:
			print("  t=%.1fs y=%.2f on_floor=%s vy=%.2f" % [
				_i / 60.0, settled_y, str(player.is_on_floor()), player.velocity.y])
		if player.is_on_floor():
			break
	print("INFO: dropped from y=%.1f, settled at y=%.2f" % [start_y, settled_y])

	# --- 1. did not fall through (didn't plummet far below the surface) ---
	if settled_y < floor_h - 50.0:
		_fail("capsule fell THROUGH: y=%.1f, terrain here ~%.1f" % [settled_y, floor_h])
		_finish(rootn); return
	print("PASS: did not fall through — capsule y=%.1f stayed at/above terrain ~%.1f" % [settled_y, floor_h])

	# --- 2. came to rest ON the surface (capsule centre ~ floor + half height) ---
	# CharacterBody3D capsule rests with its centre about (height/2 + radius?) above
	# the contact; allow a generous band so this isn't brittle to capsule maths.
	var expected_rest: float = floor_h + player.capsule_height * 0.5
	if abs(settled_y - expected_rest) > 4.0:
		_fail("capsule did not settle on the surface: y=%.1f, expected ~%.1f (floor %.1f)" % [
			settled_y, expected_rest, floor_h])
	else:
		print("PASS: rests on the surface — y=%.1f within band of expected ~%.1f (floor %.1f)" % [
			settled_y, expected_rest, floor_h])

	# --- 3. is_on_floor() true (actually standing, not tunnelling/jittering) ---
	if not player.is_on_floor():
		_fail("is_on_floor() is false after settling — not standing on the collision")
	else:
		print("PASS: is_on_floor() true — standing on the HeightMapShape3D")

	print("INFO: settled_y=%.2f floor_h=%.2f bodies=%d" % [settled_y, floor_h, view._collisions.size()])
	_finish(rootn)

func _finish(rootn) -> void:
	if rootn != null:
		rootn.queue_free()
	print("M1.7c RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
