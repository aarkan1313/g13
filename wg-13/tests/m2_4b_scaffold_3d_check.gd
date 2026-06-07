extends SceneTree
# M2.4b static 3D review smoke gate.
# Run after exporting the JSON:
#   cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- export-godot
#   godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_4b_scaffold_3d_check.gd

const SCENE := "res://scenes/m2_4b_scaffold_3d_review.tscn"

var _failed := false

func _fail(message: String) -> void:
	_failed = true
	print("FAIL: ", message)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed: PackedScene = load(SCENE)
	if packed == null:
		_fail("could not load %s" % SCENE)
		_finish()
		return

	var root: Node = packed.instantiate()
	get_root().add_child(root)
	for _i in range(4):
		await process_frame

	if not root.has_method("panel_count") or not root.has_method("total_vertices"):
		_fail("scene root does not expose scaffold review counters")
	elif root.panel_count() != 4:
		_fail("expected 4 style panels, got %d" % root.panel_count())
	elif root.total_vertices() < 100000:
		_fail("mesh vertex count too small: %d" % root.total_vertices())
	else:
		print("PASS: scaffold 3D scene built %d panels / %d vertices" % [
			root.panel_count(),
			root.total_vertices(),
		])

	root.queue_free()
	_finish()

func _finish() -> void:
	print("M2.4b scaffold 3D RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
