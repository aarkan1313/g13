extends Node3D
# M1.5 world view — pool-driven terrain. Thin assembly only (00 §4): owns a Rust
# PagePool, requests a ring of pages around the focus, and presents each as a
# displaced plane via ring_displace. Launch-and-fly (fly_camera).
#
# M1.5a: STATIC ring around origin through the pool (proves pool-driven render).
# M1.5b will move the ring with the camera; M1.5c adds coarse levels + never-black.

const SHADER := "res://shaders/field_height.glsl"
const RING := "res://shaders/ring_displace.gdshader"
const FLY := "res://scripts/fly_camera.gd"

@export var page_res: int = 128
@export var spacing: float = 4.0
@export var seed_val: float = 1234.0
@export var octaves: int = 5
@export var base_freq: float = 0.0015
@export var amplitude: float = 240.0
@export var ring_radius: int = 3           # (2*r+1)^2 pages around the camera
@export var evict_margin: int = 1          # hysteresis: keep_radius = ring_radius + this
@export var max_new_per_frame: int = 4

var _pool: RefCounted
var _ring_shader: Resource
var _instances := {}                       # "0:gx:gz" -> MeshInstance3D
var _cam: Camera3D

func _ready() -> void:
	_pool = ClassDB.instantiate("PagePool")
	if _pool == null:
		push_error("M1.5: PagePool not registered."); return
	if not _pool.initialize(SHADER):
		push_error("M1.5: PagePool.initialize failed (need --rendering-driver vulkan)."); return
	_pool.configure(page_res, spacing, seed_val, octaves, base_freq, amplitude, max_new_per_frame)
	_ring_shader = load(RING)

	# Build a static ring around origin (M1.5a). Production is bounded per frame,
	# so over the first few frames the ring fills in; _process keeps requesting
	# missing pages until the static ring is complete.
	_spawn_camera()

func _process(_dt: float) -> void:
	if _cam == null:
		return
	_pool.begin_frame()
	var span: float = _pool.page_span()

	# Page the camera is currently over (level 0).
	var ccx: int = _pool.world_to_page_index(_cam.global_position.x)
	var ccz: int = _pool.world_to_page_index(_cam.global_position.z)

	# 1. Request the ring of pages around the camera; build any not yet present.
	#    Bounded production spreads the work over frames (no stutter).
	for gz in range(ccz - ring_radius, ccz + ring_radius + 1):
		for gx in range(ccx - ring_radius, ccx + ring_radius + 1):
			var key := "0:%d:%d" % [gx, gz]
			if _instances.has(key):
				continue
			var tex = _pool.request_page(0, gx, gz)
			if tex == null:
				continue                    # over budget this frame; retry next
			_instances[key] = _make_page_instance(tex, gx, gz, span)

	# 2. Drop meshes for pages that have left the keep zone (camera moved). Do this
	#    BEFORE pinning so a stale far page isn't pinned and then refused eviction.
	var keep: int = ring_radius + evict_margin
	for key in _instances.keys():
		var parts: PackedStringArray = key.split(":")
		var cheb: int = maxi(absi(int(parts[1]) - ccx), absi(int(parts[2]) - ccz))
		if cheb > keep:
			_instances[key].queue_free()
			_instances.erase(key)

	# 3. Pin everything STILL displayed (all now inside the keep zone).
	for key in _instances.keys():
		var parts: PackedStringArray = key.split(":")
		_pool.pin_page(int(parts[0]), int(parts[1]), int(parts[2]))

	# 4. Evict pool pages outside the keep radius. None are pinned (pins are all
	#    inside the keep zone after step 2), so nothing displayed is dropped.
	_pool.evict_outside(0, ccx, ccz, keep)

func _make_page_instance(tex, gx: int, gz: int, span: float) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = Vector2(span, span)
	plane.subdivide_width = mini(page_res - 1, 160)
	plane.subdivide_depth = mini(page_res - 1, 160)

	var mat := ShaderMaterial.new()
	mat.shader = _ring_shader
	mat.set_shader_parameter("height_tex", tex)
	mat.set_shader_parameter("page_world_size", span)
	mat.set_shader_parameter("height_scale", 1.0)
	mat.set_shader_parameter("cell_spacing", spacing)
	mat.set_shader_parameter("page_tint", 1.0 if (gx + gz) % 2 == 0 else 0.82)

	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	# Page world origin (shared-boundary-cell stride = span). Plane is centered.
	mi.position = Vector3(gx * span + span * 0.5, 0.0, gz * span + span * 0.5)
	mi.custom_aabb = AABB(Vector3(-span, -amplitude, -span),
		Vector3(2.0 * span, 4.0 * amplitude, 2.0 * span))
	add_child(mi)
	return mi

func _spawn_camera() -> void:
	var span: float = _pool.page_span()
	var terrain_y := amplitude * 1.2
	var cam := Camera3D.new()
	cam.far = span * 40.0                       # see far enough across many pages
	cam.set_script(load(FLY))
	add_child(cam)
	# Start above origin looking out over the terrain; fly with WASD to stream.
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

	print("M1.5a: pool-driven %dx%d ring, page span %.0fm" % [
		2 * ring_radius + 1, 2 * ring_radius + 1, span])
