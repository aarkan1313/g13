extends SceneTree

const VIEW := preload("res://scripts/dem_grounded_world_view.gd")
const OUT_DIR := "res://_captures"
const SETTLE := 120
const SPACING := 4.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0
const RES := 32
const EYE_ABOVE := 220.0
const LOOK_AHEAD := 1800.0
const DEM_KERNEL := "res://../archive/from_workflows_worldgen10_wg10/worldgen_terrain/packs/dem_v1/kernels/badlands__cop30_badlands_utah_canyonlands_109_7_38_25.npy"
const DEM_REVIEW_FOOTPRINT_M := 32768.0
const DEM_SOURCE_RELIEF_M := 1600.0
const DEM_REVIEW_AMPLITUDE_M := 520.0

const SPOTS_XZ := [
	Vector2(37000.0, 28000.0),
	Vector2(33000.0, 24000.0),
	Vector2(30000.0, 18000.0),
]

var _fc
var _f := 0
var _shot := 0
var _eyes: Array[Vector3] = []
var _tgts: Array[Vector3] = []

func _height_at(wx: float, wz: float) -> float:
	var h: PackedFloat32Array = _fc.produce_page(wx, wz, SPACING, SEED, RES, OCT, FREQ, AMP)
	return h[0] if h.size() > 0 else 0.0

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_fc = ClassDB.instantiate("FieldCompute")
	if _fc == null or not _fc.initialize("res://shaders/field_height_dem_grounded.glsl"):
		print("DEM CAPTURE init failed (need vulkan)")
		quit(1)
		return
	if _fc.has_method("load_dem_kernel_npy"):
		_fc.load_dem_kernel_npy(DEM_KERNEL, DEM_REVIEW_FOOTPRINT_M, DEM_SOURCE_RELIEF_M, DEM_REVIEW_AMPLITUDE_M)
	var dir: Vector2 = Vector2(1.0, -0.3).normalized()
	for p in SPOTS_XZ:
		var gy: float = _height_at(p.x, p.y)
		var eye := Vector3(p.x, gy + EYE_ABOVE, p.y)
		var ahead: Vector2 = p + dir * LOOK_AHEAD
		var ty: float = _height_at(ahead.x, ahead.y)
		var tgt := Vector3(ahead.x, ty + EYE_ABOVE * 0.35, ahead.y)
		_eyes.append(eye)
		_tgts.append(tgt)
		print("DEM SPOT (%.0f,%.0f): ground %.0fm -> eye y %.0f" % [p.x, p.y, gy, eye.y])
	var root := Node3D.new()
	root.set_script(VIEW)
	root.set("show_page_tint", false)
	get_root().add_child(root)

func _process(_dt: float) -> bool:
	_f += 1
	var cam := get_root().get_viewport().get_camera_3d()
	if cam and _f == 2:
		cam.global_position = _eyes[_shot]
		cam.look_at(_tgts[_shot], Vector3.UP)
		cam.far = 60000.0
	if _f < SETTLE:
		return false
	var out := "%s/dem_grounded_shape_low%d.png" % [OUT_DIR, _shot]
	var err := get_root().get_texture().get_image().save_png(out)
	print("DEM CAPTURE %d: %s" % [_shot, ("saved " + out) if err == OK else ("FAIL " + str(err))])
	_shot += 1
	if _shot >= _eyes.size() or err != OK:
		quit(0 if err == OK else 1)
		return true
	_f = 0
	return false
