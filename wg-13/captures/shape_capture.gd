extends SceneTree
# Terrain SHAPE capture — LOW altitude, to judge relief (lowlands, hills, ranges,
# valleys) at the scale you fly. Saves _captures/shape_lowN.png at a few regions.
# Evidence only; live walking is the real judge (01_TOOLCHAIN §5).
#
# GROUND-AWARE (M2.3): terrain relief is now tall + varied, so a fixed-y camera
# would sit buried inside a peak. We SAMPLE the field height at each spot via
# FieldCompute and place the eye a fixed amount ABOVE local ground, aimed at an
# on-ground point ahead. Valid at any relief scale.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://captures/shape_capture.gd

const VIEW := preload("res://scripts/world_view.gd")
const OUT_DIR := "res://_captures"
const SETTLE := 120
const SPACING := 4.0          # match world_view live params (sampled==rendered)
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0
const RES := 32
const EYE_ABOVE := 130.0
const LOOK_AHEAD := 1500.0

# (x,z) vantages; y filled from sampled ground. Aimed at a known mountain region
# (peaks ~1.5km near (39000,30000)) so the captures show the RANGES, plus the
# range-to-lowland transition. (Lowland-only spots looked gentle+fine already.)
const SPOTS_XZ := [
	Vector2(37000.0, 28000.0),   # inside the range -> ridges/peaks up close
	Vector2(33000.0, 24000.0),   # range flank -> slopes into valley
	Vector2(30000.0, 18000.0),   # range -> lowland transition (foothills)
]

var _root: Node3D
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
	if _fc == null or not _fc.initialize("res://shaders/field_height.glsl"):
		print("CAPTURE init failed (need vulkan)"); quit(1); return
	var dir: Vector2 = Vector2(1.0, -0.3).normalized()
	for p in SPOTS_XZ:
		var gy: float = _height_at(p.x, p.y)
		var eye := Vector3(p.x, gy + EYE_ABOVE, p.y)
		var ahead: Vector2 = p + dir * LOOK_AHEAD
		var ty: float = _height_at(ahead.x, ahead.y)
		var tgt := Vector3(ahead.x, ty + EYE_ABOVE * 0.4, ahead.y)
		_eyes.append(eye); _tgts.append(tgt)
		print("SPOT (%.0f,%.0f): ground %.0fm -> eye y %.0f" % [p.x, p.y, gy, eye.y])
	_root = Node3D.new()
	_root.set_script(VIEW)
	_root.set("show_page_tint", false)
	get_root().add_child(_root)

func _process(_dt: float) -> bool:
	_f += 1
	var cam := get_root().get_viewport().get_camera_3d()
	if cam and _f == 2:
		cam.global_position = _eyes[_shot]
		cam.look_at(_tgts[_shot], Vector3.UP)
		cam.far = 60000.0
	if _f < SETTLE:
		return false
	var out := "%s/shape_low%d.png" % [OUT_DIR, _shot]
	var err := get_root().get_texture().get_image().save_png(out)
	print("CAPTURE %d: %s" % [_shot, ("saved " + out) if err == OK else ("FAIL " + str(err))])
	_shot += 1
	if _shot >= _eyes.size() or err != OK:
		quit(0 if err == OK else 1)
		return true
	_f = 0   # re-settle at the next spot (camera teleports -> ring refills)
	return false
