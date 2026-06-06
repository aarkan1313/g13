extends SceneTree
# M1.3 visual-capture (01_TOOLCHAIN §5): build the page view, let it render a
# few frames, save a PNG to res://_captures/, and quit. Produces the evidence
# artifact the human reviews for the M1.3 visual gate. Run:
#   godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_3_capture.gd

const VIEW := preload("res://scripts/m1_3_view.gd")
const OUT_DIR := "res://_captures"
const OUT := "res://_captures/m1_3_page.png"
const WARMUP_FRAMES := 8

var _frames := 0
var _root: Node3D

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_root = Node3D.new()
	_root.set_script(VIEW)
	get_root().add_child(_root)

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < WARMUP_FRAMES:
		return false
	var img := get_root().get_texture().get_image()
	var err := img.save_png(OUT)
	if err == OK:
		print("M1.3 CAPTURE: saved ", OUT, " (", img.get_width(), "x", img.get_height(), ")")
	else:
		print("M1.3 CAPTURE: FAILED to save (", err, ")")
	quit(0 if err == OK else 1)
	return true
