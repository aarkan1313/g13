extends SceneTree
# M1.5b capture: build the streaming view, fly the camera east a few pages so
# streaming has happened, then shoot. Confirms terrain is continuous after the
# ring has recentered (not just at origin).
const VIEW := preload("res://scripts/world_view.gd")
const OUT := "res://_captures/m1_5b_streamed.png"
var _f := 0
var _root: Node3D
func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_captures"))
	_root = Node3D.new()
	_root.set_script(VIEW)
	get_root().add_child(_root)
func _process(_dt):
	_f += 1
	# Drive the camera east/forward so the ring recenters and streams.
	var cam := get_root().get_viewport().get_camera_3d()
	if cam:
		cam.global_position += Vector3(120, 0, -120)   # move ~1/4 page per frame
	if _f < 60: return false                            # ~15 pages of travel + fill
	var err := get_root().get_texture().get_image().save_png(OUT)
	print("M1.5b CAPTURE: ", ("saved " + OUT) if err == OK else ("FAIL " + str(err)))
	quit(0 if err == OK else 1)
	return true
