extends SceneTree
# M2.1 climate capture (evidence for the PARKED visual gate). Builds the live
# world_view, lifts the camera HIGH and tilts down so many coarse pages (tens of
# km of world) are in frame, lets streaming settle, then saves three PNGs — one
# per view mode (normal / temperature / moisture) — so the human can eyeball
# "two smooth, large-scale gradients across the world" without relaunching.
# Not a gate; evidence. The definitive visual pass is the live desk flight
# (01_TOOLCHAIN §5: --script viewports render small).
# Run: godot --rendering-driver vulkan --path wg-13 --script res://captures/climate_capture.gd

const VIEW := preload("res://scripts/world_view.gd")
const OUT_DIR := "res://_captures"
const SETTLE_FRAMES := 90        # let the multi-level ring fill before shooting
const MODE_NAMES := ["normal", "temperature", "moisture", "biome"]

var _root: Node3D
var _f := 0
var _shot := -1                  # -1 = settling; 0..2 = which mode we just set

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_root = Node3D.new()
	_root.set_script(VIEW)
	_root.set("show_page_tint", false)
	get_root().add_child(_root)

func _process(_dt: float) -> bool:
	_f += 1
	# Lift the camera VERY high and look down a shallow angle so a large span of
	# world (tens of km) is in frame — climate features are ~40-120 km, so a
	# small frame can't show the gradient. Vantage spans most of the loaded reach.
	var cam := get_root().get_viewport().get_camera_3d()
	if cam and _f == 2:
		cam.global_position = Vector3(0.0, 22000.0, 26000.0)
		cam.look_at(Vector3(0.0, 0.0, -38000.0), Vector3.UP)
		cam.far = 200000.0
	if _f < SETTLE_FRAMES:
		return false

	# After settling, step through the three view modes, one PNG each. We set the
	# mode, wait a couple frames for the material params to apply, then shoot.
	if _shot < 0:
		_shot = 0
		_root.set("_view_mode", _shot)
		_root.call("_apply_view_mode")
		_f = SETTLE_FRAMES - 3        # small wait before the shot
		return false

	if _f < SETTLE_FRAMES:
		return false

	var out := "%s/climate_%s.png" % [OUT_DIR, MODE_NAMES[_shot]]
	var err := get_root().get_texture().get_image().save_png(out)
	print("CAPTURE %s: %s" % [MODE_NAMES[_shot], ("saved " + out) if err == OK else ("FAIL " + str(err))])
	if err != OK:
		quit(1); return true

	_shot += 1
	if _shot >= MODE_NAMES.size():
		quit(0); return true
	# Set the next mode and wait a couple frames.
	_root.set("_view_mode", _shot)
	_root.call("_apply_view_mode")
	_f = SETTLE_FRAMES - 3
	return false
