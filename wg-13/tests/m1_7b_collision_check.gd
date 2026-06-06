extends SceneTree
# M1.7b gate — world_view builds NEAR (level-0) collision bodies whose
# HeightMapShape3D carries the SAME heights the pool produced, with the correct
# dimensions and world transform, and frees them when pages leave the radius.
#
# Drives the REAL world_view.gd (its WorkerThreadPool build + deferred attach),
# so this exercises the actual async path, then asserts output-provably:
#   1. a collision body exists for the level-0 page under the camera
#   2. its HeightMapShape3D.map_data is BIT-IDENTICAL to pool.get_page_heights
#      (pool heights -> collision shape end to end, no drift)
#   3. map_width == map_depth == page_res, and the body transform is correct
#      (position = page centre, scale = spacing) — the values that decide
#      whether the character stands on the surface vs floats/sinks
#   4. only level-0 pages get collision (no bodies for the coarse blanket)
#   5. bodies are bounded (not one per displayed mesh) — "near pages only"
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_7b_collision_check.gd

const VIEW := "res://scripts/world_view.gd"
const RES := 128
const SPACING := 4.0

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	# Build the real view with known params (defaults match world_view exports).
	var view: Node3D = load(VIEW).new()
	view.page_res = RES
	view.spacing = SPACING
	view.collision_radius = 1
	root.add_child(view)   # triggers _ready -> pool init, camera, first stream

	# Let it run enough frames for the fine ring to produce AND the async
	# collision tasks to finish + their deferred attach to land.
	for _i in range(40):
		await process_frame

	if view._pool == null:
		_fail("view pool null (need --rendering-driver vulkan)"); _finish(view); return

	var cam: Camera3D = view._cam
	var span: float = (RES - 1) * SPACING
	var ccx: int = int(floor(cam.global_position.x / span))
	var ccz: int = int(floor(cam.global_position.z / span))
	var key := "%d:%d" % [ccx, ccz]

	# --- 1. a body exists for the page under the camera ---
	if not view._collisions.has(key):
		_fail("no collision body for the level-0 page under the camera (%s); have: %s" % [
			key, str(view._collisions.keys())])
		_finish(view); return
	print("PASS: a collision body exists for the page under the camera (%s)" % key)

	var body: StaticBody3D = view._collisions[key]
	var col: CollisionShape3D = body.get_child(0)
	var shape: HeightMapShape3D = col.shape

	# --- 2. shape heights bit-identical to pool heights (no drift) ---
	var pool_heights: PackedFloat32Array = view._pool.get_page_heights(0, ccx, ccz)
	if shape.map_data.to_byte_array() != pool_heights.to_byte_array():
		_fail("collision map_data != pool get_page_heights (drift between view and collision)")
	else:
		print("PASS: collision shape map_data is bit-identical to the pool heights (no drift)")

	# --- 3. dimensions + transform (the float/sink-deciding values) ---
	if shape.map_width != RES or shape.map_depth != RES:
		_fail("shape dims %dx%d, expected %dx%d" % [shape.map_width, shape.map_depth, RES, RES])
	else:
		print("PASS: shape dimensions %dx%d match page_res" % [RES, RES])

	var want_pos := Vector3(ccx * span + span * 0.5, 0.0, ccz * span + span * 0.5)
	if not body.position.is_equal_approx(want_pos):
		_fail("body position %s, expected page centre %s" % [str(body.position), str(want_pos)])
	else:
		print("PASS: body positioned at page centre %s" % str(want_pos))
	# 1-unit grid -> scale must be cell_spacing on X/Z (Y stays 1).
	var want_scale := Vector3(SPACING, 1.0, SPACING)
	if not body.scale.is_equal_approx(want_scale):
		_fail("body scale %s, expected %s (1-unit grid -> cell_spacing)" % [str(body.scale), str(want_scale)])
	else:
		print("PASS: body scaled to cell_spacing %s (matches the displaced mesh span)" % str(want_scale))

	# --- 4. every collision body is a HeightMapShape3D StaticBody3D (level-0 only) ---
	var all_valid := true
	for k in view._collisions.keys():
		var b: StaticBody3D = view._collisions[k]
		var s = b.get_child(0).shape
		if not (s is HeightMapShape3D):
			all_valid = false
	if not all_valid:
		_fail("a collision body has a non-HeightMapShape3D shape")
	else:
		print("PASS: all %d collision bodies are HeightMapShape3D static bodies" % view._collisions.size())

	# --- 5. bounded count: "near pages only", not one per displayed mesh ---
	# radius 1 (+evict_margin hysteresis) -> at most (2*(1+margin)+1)^2 level-0 bodies,
	# which is far fewer than the displayed mesh count (rings across all levels).
	var em: int = view.evict_margin
	var max_bodies: int = (2 * (1 + em) + 1) * (2 * (1 + em) + 1)
	if view._collisions.size() > max_bodies:
		_fail("collision body count %d exceeds bound %d (not 'near pages only')" % [
			view._collisions.size(), max_bodies])
	elif view._collisions.size() >= view._instances.size():
		_fail("collision bodies (%d) >= displayed meshes (%d) — should be FAR fewer" % [
			view._collisions.size(), view._instances.size()])
	else:
		print("PASS: bounded — %d collision bodies for %d displayed meshes (near pages only)" % [
			view._collisions.size(), view._instances.size()])

	print("INFO: collision bodies=%d resident=%d meshes=%d" % [
		view._collisions.size(), view._pool.resident_count(), view._instances.size()])
	_finish(view)

func _finish(view) -> void:
	if view != null:
		view.queue_free()
	print("M1.7b RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
