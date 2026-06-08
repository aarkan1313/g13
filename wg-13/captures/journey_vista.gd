extends SceneTree
# THROWAWAY journey vista — render the M2.5b regional-archetype probe terrain from
# several spots across the world (a "journey") to judge regional VARIETY by eye.
# Eye high, looking out, so we see the regional character + transitions. Delete after.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://captures/journey_vista.gd
const VIEW := preload("res://scripts/world_view.gd")
const OUT_DIR := "res://_captures"
const SETTLE := 200
const SPACING := 4.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0
const RES := 32

# A transect of vantage points across the world (km apart) to sample different regions.
const SPOTS := [
	Vector2(0.0, 0.0),
	Vector2(45000.0, 12000.0),
	Vector2(95000.0, -30000.0),
	Vector2(-60000.0, 70000.0),
	Vector2(150000.0, 150000.0),
]

var _fc
var _root: Node3D
var _f := 0
var _shot := 0

func _height_at(wx: float, wz: float) -> float:
	var h: PackedFloat32Array = _fc.produce_page(wx, wz, SPACING, SEED, RES, OCT, FREQ, AMP)
	return h[0] if h.size() > 0 else 0.0

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_fc = ClassDB.instantiate("FieldCompute")
	if _fc == null or not _fc.initialize("res://shaders/field_height_probe.glsl"):
		print("init failed (need vulkan)"); quit(1); return
	_root = Node3D.new()
	_root.set_script(VIEW)
	_root.set("show_page_tint", false)
	get_root().add_child(_root)

func _process(_dt: float) -> bool:
	_f += 1
	var cam := get_root().get_viewport().get_camera_3d()
	if cam == null:
		return false
	if _f == 3:
		var s: Vector2 = SPOTS[_shot]
		var gy := _height_at(s.x, s.y)
		var eye := Vector3(s.x, max(gy, 0.0) + 900.0, s.y)
		cam.global_position = eye
		cam.look_at(eye + Vector3(1.0, -0.10, 0.5).normalized() * 12000.0, Vector3.UP)
	if _f < SETTLE:
		return false
	var out := "%s/journey_%d.png" % [OUT_DIR, _shot]
	var err := get_root().get_texture().get_image().save_png(out)
	print("JOURNEY %d @ (%.0f,%.0f): %s" % [_shot, SPOTS[_shot].x, SPOTS[_shot].y, ("saved" if err == OK else "FAIL")])
	_shot += 1
	_f = 0
	if _shot >= SPOTS.size() or err != OK:
		quit(0 if err == OK else 1)
		return true
	return false
