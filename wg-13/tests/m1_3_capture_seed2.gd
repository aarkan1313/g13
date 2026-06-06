extends SceneTree
# M1.3 second capture with a DIFFERENT seed, to show shape is seed-driven
# (the tunable half of the gate). Saves res://_captures/m1_3_page_seed2.png.

const VIEW := preload("res://scripts/m1_3_view.gd")
const OUT := "res://_captures/m1_3_page_seed2.png"
const WARMUP_FRAMES := 8

var _frames := 0

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_captures"))
	var root := Node3D.new()
	root.set_script(VIEW)
	root.set("seed_val", 77777.0)  # different world -> different terrain
	get_root().add_child(root)

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < WARMUP_FRAMES:
		return false
	var img := get_root().get_texture().get_image()
	var err := img.save_png(OUT)
	print("M1.3 CAPTURE seed2: ", ("saved " + OUT) if err == OK else ("FAIL " + str(err)))
	quit(0 if err == OK else 1)
	return true
