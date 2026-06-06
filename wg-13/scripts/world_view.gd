extends Node3D
# M1.5 world view — pool-driven, multi-level clipmap with never-black coverage.
# Thin assembly only (00 §4): owns a Rust PagePool, keeps a ring of pages PER
# LEVEL around the camera, presents each as a displaced plane via ring_displace.
# Launch-and-fly (fly_camera).
#
# M1.5c: NUM_LEVELS rings. Level L pages span base_span * 2^L. Coarse levels
# render UNDER fine ones (lower render_priority + tiny downward bias), so when a
# fine page isn't produced yet, the coarse blanket beneath shows through instead
# of sky -> NEVER BLACK. num_levels is a parameter; M1.6 scales it to ~30 km
# view distance with no rewrite (just more levels + tuned radii).

const SHADER := "res://shaders/field_height.glsl"
const RING := "res://shaders/ring_displace.gdshader"
const FLY := "res://scripts/fly_camera.gd"

@export var page_res: int = 128
@export var spacing: float = 4.0
@export var seed_val: float = 1234.0
@export var octaves: int = 5
@export var base_freq: float = 0.0015
@export var amplitude: float = 240.0
@export var num_levels: int = 2            # fine (0) + coarse blankets. M1.6 scales up.
@export var ring_radius: int = 3           # pages each side, per level, around camera
@export var evict_margin: int = 1          # hysteresis: keep_radius = ring_radius + margin
@export var max_new_per_frame: int = 4
@export var show_page_tint: bool = true    # debug checkerboard marking page edges

var _pool: RefCounted
var _ring_shader: Resource
var _instances := {}                       # "L:gx:gz" -> MeshInstance3D
var _cam: Camera3D

func _ready() -> void:
	_pool = ClassDB.instantiate("PagePool")
	if _pool == null:
		push_error("M1.5: PagePool not registered."); return
	if not _pool.initialize(SHADER):
		push_error("M1.5: PagePool.initialize failed (need --rendering-driver vulkan)."); return
	_pool.configure(page_res, spacing, seed_val, octaves, base_freq, amplitude, max_new_per_frame)
	_ring_shader = load(RING)
	_spawn_camera()
	print("M1.5c: %d-level clipmap, ring_radius %d, base span %.0fm" % [
		num_levels, ring_radius, _pool.page_span()])

func _process(_dt: float) -> void:
	if _cam == null:
		return
	_pool.begin_frame()
	var base_span: float = _pool.page_span()
	var keep: int = ring_radius + evict_margin
	var cam_x: float = _cam.global_position.x
	var cam_z: float = _cam.global_position.z

	# Request coarsest first. COARSE levels (>0) are produced EAGERLY (unbounded):
	# they're cheap, few, and are the never-black blanket, so they must always be
	# complete. Only the FINEST level (0) is bounded per frame — that's the
	# expensive detail whose burst would stutter. (00 §3; budget caps detail, not
	# the blanket.)
	for level in range(num_levels - 1, -1, -1):
		var span: float = base_span * pow(2.0, level)
		var ccx: int = int(floor(cam_x / span))
		var ccz: int = int(floor(cam_z / span))
		for gz in range(ccz - ring_radius, ccz + ring_radius + 1):
			for gx in range(ccx - ring_radius, ccx + ring_radius + 1):
				var key := "%d:%d:%d" % [level, gx, gz]
				if _instances.has(key):
					continue
				var tex = (_pool.request_page_eager(level, gx, gz) if level > 0
					else _pool.request_page(level, gx, gz))
				if tex == null:
					continue                  # fine over budget; coarse blanket covers it
				_instances[key] = _make_page_instance(tex, level, gx, gz, span)

	# Per level: drop stale meshes -> pin remaining -> evict pool pages outside keep.
	# (Order matters: drop before pin so a stale page isn't pinned then evicted.)
	for level in range(num_levels):
		var span: float = base_span * pow(2.0, level)
		var ccx: int = int(floor(cam_x / span))
		var ccz: int = int(floor(cam_z / span))
		# 1. drop meshes outside keep zone at this level
		for key in _instances.keys():
			var p: PackedStringArray = key.split(":")
			if int(p[0]) != level:
				continue
			var cheb: int = maxi(absi(int(p[1]) - ccx), absi(int(p[2]) - ccz))
			if cheb > keep:
				_instances[key].queue_free()
				_instances.erase(key)
		# 2. pin everything still displayed at this level
		for key in _instances.keys():
			var p2: PackedStringArray = key.split(":")
			if int(p2[0]) == level:
				_pool.pin_page(level, int(p2[1]), int(p2[2]))
		# 3. evict pool pages outside keep radius at this level
		_pool.evict_outside(level, ccx, ccz, keep)

	_update_annulus_visibility()

# Annulus rule (no overlap -> no z-fighting): a coarse page is VISIBLE only where
# the finer level does NOT fully cover it. A coarse page (L, cgx, cgz) covers the
# 2x2 footprint of level L-1 pages (2cgx..+1, 2cgz..+1); if ALL of those finer
# pages are currently displayed, hide the coarse page (fine has it); otherwise
# show it (it's the blanket filling a not-yet-loaded hole -> never black).
func _update_annulus_visibility() -> void:
	# Build a fast lookup of which pages are displayed, per level.
	var displayed := {}                        # "L:gx:gz" -> true
	for key in _instances.keys():
		displayed[key] = true
	for key in _instances.keys():
		var p: PackedStringArray = key.split(":")
		var level := int(p[0])
		if level == 0:
			_instances[key].visible = true     # finest is always shown
			continue
		var cgx := int(p[1])
		var cgz := int(p[2])
		# Is the entire finer (level-1) footprint displayed?
		var finer_covers := true
		for dz in range(2):
			for dx in range(2):
				if not displayed.has("%d:%d:%d" % [level - 1, 2 * cgx + dx, 2 * cgz + dz]):
					finer_covers = false
		_instances[key].visible = not finer_covers

func _make_page_instance(tex, level: int, gx: int, gz: int, span: float) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = Vector2(span, span)
	plane.subdivide_width = mini(page_res - 1, 160)
	plane.subdivide_depth = mini(page_res - 1, 160)

	var mat := ShaderMaterial.new()
	mat.shader = _ring_shader
	mat.set_shader_parameter("height_tex", tex)
	mat.set_shader_parameter("page_world_size", span)
	mat.set_shader_parameter("height_scale", 1.0)
	mat.set_shader_parameter("cell_spacing", spacing * pow(2.0, level))
	mat.set_shader_parameter("page_tint",
		(1.0 if (gx + gz) % 2 == 0 else 0.82) if show_page_tint else 1.0)
	# No overlap (annulus): coarse pages are hidden where fine fully covers (see
	# _update_annulus_visibility), so levels never render the same ground -> no
	# z-fighting. No Y bias / render_priority hacks needed.
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	mi.position = Vector3(gx * span + span * 0.5, 0.0, gz * span + span * 0.5)
	mi.custom_aabb = AABB(Vector3(-span, -amplitude, -span),
		Vector3(2.0 * span, 4.0 * amplitude, 2.0 * span))
	add_child(mi)
	return mi

func _spawn_camera() -> void:
	var span: float = _pool.page_span()
	var terrain_y := amplitude * 1.2
	var cam := Camera3D.new()
	cam.far = span * 60.0
	cam.set_script(load(FLY))
	add_child(cam)
	cam.global_position = Vector3(0.0, terrain_y + span * 0.5, span * 0.8)
	cam.look_at(Vector3(0.0, terrain_y * 0.9, -span), Vector3.UP)
	cam.make_current()
	_cam = cam

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -130, 0)
	sun.light_energy = 1.2
	add_child(sun)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.52, 0.62, 0.74)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.55, 0.6)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)
