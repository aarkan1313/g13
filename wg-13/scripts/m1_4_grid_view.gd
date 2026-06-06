extends Node3D
# M1.4 — present a 3x3 block of pages with the shared-boundary-cell convention
# (00 §5.1). If world-space sampling is correct, the 9 patches form one
# continuous surface with no cracks at the boundaries. Thin assembly only.

const SHADER := "res://shaders/field_height.glsl"
const RING := "res://shaders/ring_displace.gdshader"

@export var page_res: int = 128
@export var spacing: float = 4.0
@export var seed_val: float = 1234.0
@export var octaves: int = 5
@export var base_freq: float = 0.004   # higher -> more structure per page (clearer seam check)
@export var amplitude: float = 240.0
@export var grid: int = 3   # NxN pages

var _fc: RefCounted

func _ready() -> void:
	_fc = ClassDB.instantiate("FieldCompute")
	if _fc == null:
		push_error("M1.4: FieldCompute not registered."); return
	if not _fc.initialize(SHADER):
		push_error("M1.4: initialize failed (need --rendering-driver vulkan)."); return

	var span := float(page_res - 1) * spacing   # world span ONE page covers
	var ring_shader := load(RING)

	# Center the block on origin: grid indices range over [-(grid-1)/2 .. +].
	var half := (grid - 1) / 2.0

	for gz in range(grid):
		for gx in range(grid):
			# Shared-boundary-cell convention: origin strides by span (= (N-1)*s).
			var ox := (gx - half) * span
			var oz := (gz - half) * span
			var tex: ImageTexture = _fc.produce_page_texture(
				ox, oz, spacing, seed_val, page_res, octaves, base_freq, amplitude)
			if tex == null:
				push_error("M1.4: null page at (%d,%d)" % [gx, gz]); continue

			var plane := PlaneMesh.new()
			plane.size = Vector2(span, span)
			var subdiv := mini(page_res - 1, 160)
			plane.subdivide_width = subdiv
			plane.subdivide_depth = subdiv

			var mat := ShaderMaterial.new()
			mat.shader = ring_shader
			mat.set_shader_parameter("height_tex", tex)
			mat.set_shader_parameter("page_world_size", span)
			mat.set_shader_parameter("height_scale", 1.0)
			mat.set_shader_parameter("cell_spacing", spacing)
			# Checkerboard so page boundaries are VISIBLE -> seams verifiable: if the
			# surface is continuous across a tint change, there's no crack. (Strong
			# enough to see; this is a debug aid, not final look.)
			var checker := (gx + gz) % 2 == 0
			mat.set_shader_parameter("page_tint", 1.0 if checker else 0.72)

			var mi := MeshInstance3D.new()
			mi.mesh = plane
			mi.material_override = mat   # <-- without this the plane renders default white, undisplaced
			# Position this page's plane center at the page's world center.
			# PlaneMesh is centered, so center = origin + span/2.
			mi.position = Vector3(ox + span * 0.5, 0.0, oz + span * 0.5)
			mi.custom_aabb = AABB(Vector3(-span, -amplitude, -span),
				Vector3(2.0 * span, 4.0 * amplitude, 2.0 * span))
			add_child(mi)

	# Camera framing the whole block from above-corner, looking down at center.
	# The fBM sits on a DC pedestal (~amplitude), so aim at the real terrain
	# altitude, not at y=0 (that was why earlier frames saw the flat underside).
	var total := grid * span                  # full block extent
	var terrain_y := amplitude * 1.2          # approx mid altitude of the surface
	var cam := Camera3D.new()
	cam.far = total * 8.0
	add_child(cam)
	# High angled view so the 3x3 page layout (checkerboard) is legible and the
	# whole block is framed — this is the seam-verification shot. Aimed at the
	# real terrain altitude, not y=0.
	cam.global_position = Vector3(total * 0.55, terrain_y + total * 0.75, total * 0.55)
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

	print("M1.4: %dx%d page block presented — page span %.0fm, total %.0fm" % [
		grid, grid, span, total])
