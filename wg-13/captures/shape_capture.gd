extends SceneTree
# M2.3b shape capture — LOW altitude, normal view, to judge terrain SHAPE (ridges,
# valleys, per-biome relief) at the scale you fly. Saves _captures/shape_lowN.png at
# a few spots. Evidence only; live flight is the real judge (01_TOOLCHAIN §5).
# Run: godot --rendering-driver vulkan --path wg-13 --script res://captures/shape_capture.gd

const VIEW := preload("res://scripts/world_view.gd")
const OUT_DIR := "res://_captures"
const SETTLE := 70

var _root: Node3D
var _f := 0
var _shot := 0
# A few low vantages over different world regions to catch varied biomes/relief.
const SPOTS := [
	[Vector3(0.0, 700.0, 0.0), Vector3(1500.0, 200.0, -1500.0)],
	[Vector3(40000.0, 900.0, 0.0), Vector3(41500.0, 250.0, -1500.0)],
	[Vector3(0.0, 1200.0, 40000.0), Vector3(1500.0, 400.0, 38500.0)],
]

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_root = Node3D.new()
	_root.set_script(VIEW)
	_root.set("show_page_tint", false)
	get_root().add_child(_root)

func _process(_dt: float) -> bool:
	_f += 1
	var cam := get_root().get_viewport().get_camera_3d()
	if cam and _f == 2:
		cam.global_position = SPOTS[_shot][0]
		cam.look_at(SPOTS[_shot][1], Vector3.UP)
		cam.far = 60000.0
	if _f < SETTLE:
		return false
	var out := "%s/shape_low%d.png" % [OUT_DIR, _shot]
	var err := get_root().get_texture().get_image().save_png(out)
	print("CAPTURE %d: %s" % [_shot, ("saved " + out) if err == OK else ("FAIL " + str(err))])
	_shot += 1
	if _shot >= SPOTS.size() or err != OK:
		quit(0 if err == OK else 1)
		return true
	_f = 0   # re-settle at the next spot (camera teleports -> ring refills)
	return false
