extends SceneTree
# M1.4 visual-capture: build the 3x3 page block, render a few frames, save PNG.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_4_capture.gd

const VIEW := preload("res://scripts/m1_4_grid_view.gd")
const OUT := "res://_captures/m1_4_grid3x3.png"
const WARMUP_FRAMES := 10

var _frames := 0

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_captures"))
	var root := Node3D.new()
	root.set_script(VIEW)
	get_root().add_child(root)

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < WARMUP_FRAMES:
		return false
	var img := get_root().get_texture().get_image()
	var err := img.save_png(OUT)
	if err == OK:
		print("M1.4 CAPTURE: saved ", OUT, " (", img.get_width(), "x", img.get_height(), ")")
	else:
		print("M1.4 CAPTURE: FAILED (", err, ")")
	quit(0 if err == OK else 1)
	return true
