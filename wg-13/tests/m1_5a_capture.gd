extends SceneTree
# M1.5a capture: pool-driven ring. Wait enough frames for the bounded pool to
# fill the 5x5 ring (25 pages / 4-per-frame ~= 7 frames), then save a PNG.
const VIEW := preload("res://scripts/world_view.gd")
const OUT := "res://_captures/m1_5a_ring.png"
const WARMUP := 40
var _f := 0
func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_captures"))
	var root := Node3D.new()
	root.set_script(VIEW)
	get_root().add_child(root)
func _process(_dt):
	_f += 1
	if _f < WARMUP: return false
	var err := get_root().get_texture().get_image().save_png(OUT)
	print("M1.5a CAPTURE: ", ("saved " + OUT) if err == OK else ("FAIL " + str(err)))
	quit(0 if err == OK else 1)
	return true
