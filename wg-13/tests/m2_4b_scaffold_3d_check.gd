extends SceneTree
# M2.4b static 3D review smoke gate.
# Run after exporting BOTH JSONs (window + oracle):
#   cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- export-godot
#   cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- export-godot --source oracle --span-m 64000 --resolution 193 --out wg-13\_captures\m2_4b_scaffold_oracle_3d.json
#   godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_4b_scaffold_3d_check.gd

const MACRO_SCENE := "res://scenes/m2_4b_scaffold_3d_review.tscn"
const PLAYABLE_SCALE_SCENE := "res://scenes/m2_4b_scaffold_playable_scale_review.tscn"
const ORACLE_PLAYABLE_SCENE := "res://scenes/m2_4b_scaffold_oracle_playable_review.tscn"

var _failed := false

func _fail(message: String) -> void:
	_failed = true
	print("FAIL: ", message)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	await _check_scene(MACRO_SCENE, 4, 100000)
	await _check_scene(PLAYABLE_SCALE_SCENE, 1, 30000)
	await _check_scene(ORACLE_PLAYABLE_SCENE, 1, 30000)
	_finish()

func _check_scene(scene_path: String, expected_panels: int, min_vertices: int) -> void:
	var packed: PackedScene = load(scene_path)
	if packed == null:
		_fail("could not load %s" % scene_path)
		return

	var root: Node = packed.instantiate()
	get_root().add_child(root)
	for _i in range(12):
		await process_frame

	if not root.has_method("panel_count") or not root.has_method("total_vertices"):
		_fail("scene root does not expose scaffold review counters")
	elif root.panel_count() != expected_panels:
		_fail("%s expected %d style panels, got %d" % [scene_path, expected_panels, root.panel_count()])
	elif root.total_vertices() < min_vertices:
		_fail("mesh vertex count too small: %d" % root.total_vertices())
	elif not _viewport_has_visible_content():
		_fail("%s rendered viewport is effectively blank" % scene_path)
	else:
		print("PASS: %s built %d panels / %d vertices" % [
			scene_path,
			root.panel_count(),
			root.total_vertices(),
		])

	root.queue_free()
	await process_frame

func _finish() -> void:
	print("M2.4b scaffold 3D RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)

func _viewport_has_visible_content() -> bool:
	var image: Image = get_root().get_texture().get_image()
	if image == null or image.get_width() <= 0 or image.get_height() <= 0:
		return false

	var reference: Color = image.get_pixel(0, 0)
	var varied_samples := 0
	var samples := 0
	var step_y: int = maxi(1, int(float(image.get_height()) / 12.0))
	var step_x: int = maxi(1, int(float(image.get_width()) / 18.0))
	for y in range(0, image.get_height(), step_y):
		for x in range(0, image.get_width(), step_x):
			var c: Color = image.get_pixel(x, y)
			var delta: float = absf(c.r - reference.r) + absf(c.g - reference.g) + absf(c.b - reference.b)
			if delta > 0.08:
				varied_samples += 1
			samples += 1
	return samples > 0 and varied_samples >= 8
