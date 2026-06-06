extends Node3D
# M1.3 — present one GPU-produced height page on screen.
# Thin assembly only (00_ARCHITECTURE §4): build a flat plane, put the
# ring_displace shader on it, feed it the page texture from FieldCompute, add a
# camera + light. The shader PRESENTS the page; it does not generate terrain.

const SHADER := "res://shaders/field_height.glsl"
const RING := "res://shaders/ring_displace.gdshader"

# Page params (match the M1.2 test so shape is the same terrain).
@export var page_res: int = 256
@export var spacing: float = 4.0
@export var seed_val: float = 1234.0
@export var octaves: int = 5
@export var base_freq: float = 0.0015
@export var amplitude: float = 240.0

var _fc: RefCounted

func _ready() -> void:
	var world_size := float(page_res) * spacing

	_fc = ClassDB.instantiate("FieldCompute")
	if _fc == null:
		push_error("M1.3: FieldCompute not registered (extension not loaded).")
		return
	if not _fc.initialize(SHADER):
		push_error("M1.3: FieldCompute.initialize failed (need --rendering-driver vulkan).")
		return

	var tex: ImageTexture = _fc.produce_page_texture(
		0.0, 0.0, spacing, seed_val, page_res, octaves, base_freq, amplitude)
	if tex == null:
		push_error("M1.3: produce_page_texture returned null.")
		return

	# Flat subdivided plane covering the page extent.
	var plane := PlaneMesh.new()
	plane.size = Vector2(world_size, world_size)
	# Enough subdivisions to resolve the page (one quad per ~cell is overkill;
	# cap so the mesh stays light for a single proof page).
	var subdiv := mini(page_res - 1, 200)
	plane.subdivide_width = subdiv
	plane.subdivide_depth = subdiv

	var mat := ShaderMaterial.new()
	mat.shader = load(RING)
	mat.set_shader_parameter("height_tex", tex)
	mat.set_shader_parameter("page_world_size", world_size)
	mat.set_shader_parameter("height_scale", 1.0)
	mat.set_shader_parameter("cell_spacing", spacing)

	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	# Don't let the engine cull it before vertices are displaced upward.
	mi.custom_aabb = AABB(Vector3(-world_size, -amplitude, -world_size),
		Vector3(2.0 * world_size, 4.0 * amplitude, 2.0 * world_size))
	add_child(mi)

	# Camera looking down at the page from a corner, framing the whole patch.
	# Must be in the tree BEFORE look_at (look_at needs a global transform).
	var cam := Camera3D.new()
	cam.far = world_size * 6.0
	add_child(cam)
	cam.global_position = Vector3(world_size * 0.7, amplitude * 2.6, world_size * 0.7)
	cam.look_at(Vector3(0, amplitude * 0.4, 0), Vector3.UP)
	cam.make_current()

	# Sun.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -130, 0)
	sun.light_energy = 1.2
	add_child(sun)

	# Soft ambient so shaded sides aren't black.
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.52, 0.62, 0.74)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.55, 0.6)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)

	print("M1.3: page presented — %dx%d cells, world %.0fm, seed %.0f" % [
		page_res, page_res, world_size, seed_val])
