extends SceneTree
# Streaming capture tool. Builds the live world_view, flies the camera forward a
# few pages so streaming has happened, then saves a PNG. Confirms terrain stays
# continuous after the ring recenters (not just at origin). Not a gate — evidence.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://captures/stream_capture.gd
# Note: --script viewports render small (see 01_TOOLCHAIN §5); the live editor
# scene is the definitive visual.

const VIEW := preload("res://scripts/world_view.gd")
const OUT := "res://_captures/streamed.png"
const FLY_FRAMES := 60          # ~15 pages of travel + fill before the shot

var _f := 0

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_captures"))
	var root := Node3D.new()
	root.set_script(VIEW)
	root.set("show_page_tint", false)   # clean look: no debug checkerboard
	get_root().add_child(root)

func _process(_dt: float) -> bool:
	_f += 1
	var cam := get_root().get_viewport().get_camera_3d()
	if cam:
		cam.global_position += Vector3(120, 0, -120)   # fly diagonally so the ring streams
	if _f < FLY_FRAMES:
		return false
	var err := get_root().get_texture().get_image().save_png(OUT)
	print("CAPTURE: ", ("saved " + OUT) if err == OK else ("FAIL " + str(err)))
	quit(0 if err == OK else 1)
	return true
