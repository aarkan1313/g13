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
@export var ring_radius: int = 2          # (2*r+1)^2 pages around origin -> 5x5
@export var max_new_per_frame: int = 4

var _pool: RefCounted
var _ring_shader: Resource
var _instances := {}                       # PageKey string -> MeshInstance3D

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
	# Each frame, ask the pool for any ring pages not yet built. Bounded
	# production means this naturally spreads over a few frames with no stutter.
	_pool.begin_frame()
	var span: float = _pool.page_span()
	for gz in range(-ring_radius, ring_radius + 1):
		for gx in range(-ring_radius, ring_radius + 1):
			var key := "0:%d:%d" % [gx, gz]
			if _instances.has(key):
				continue
			var tex = _pool.request_page(0, gx, gz)
			if tex == null:
				continue                    # over budget this frame; try next frame
			_instances[key] = _make_page_instance(tex, gx, gz, span)

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
	var extent: float = (2 * ring_radius + 1) * span
	var terrain_y := amplitude * 1.2
	var cam := Camera3D.new()
	cam.far = extent * 8.0
	cam.set_script(load(FLY))
	add_child(cam)
	cam.global_position = Vector3(extent * 0.5, terrain_y + extent * 0.6, extent * 0.5)
	cam.look_at(Vector3(0.0, terrain_y, 0.0), Vector3.UP)
	cam.make_current()

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
