extends Node3D

const FLY_CAMERA := preload("res://scripts/fly_camera.gd")

@export var data_path: String = "res://_captures/m2_4b_scaffold_3d.json"
@export var display_span_m: float = 9000.0
@export var height_scale: float = 1.15
@export var panel_gap_m: float = 900.0

var _panel_count: int = 0
var _total_vertices: int = 0

func _ready() -> void:
	var doc: Dictionary = _load_doc()
	if doc.is_empty():
		return
	_setup_world()
	_build_panels(doc)
	_spawn_camera()
	print("M2.4b scaffold 3D review: %d panels, %d vertices" % [_panel_count, _total_vertices])

func panel_count() -> int:
	return _panel_count

func total_vertices() -> int:
	return _total_vertices

func _load_doc() -> Dictionary:
	if not FileAccess.file_exists(data_path):
		push_error("Missing scaffold 3D data: %s. Run `cargo run --manifest-path rust\\Cargo.toml -p structural_scaffold -- export-godot`." % data_path)
		return {}
	var text: String = FileAccess.get_file_as_string(data_path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Invalid scaffold 3D JSON: %s" % data_path)
		return {}
	return parsed

func _setup_world() -> void:
	var env: WorldEnvironment = WorldEnvironment.new()
	var environment: Environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.55, 0.64, 0.72)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.42, 0.45, 0.48)
	environment.ambient_light_energy = 0.55
	env.environment = environment
	add_child(env)

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 2.0
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	add_child(sun)

func _build_panels(doc: Dictionary) -> void:
	var styles: Array = doc.get("styles", [])
	var res: int = int(doc.get("resolution", 0))
	if styles.is_empty() or res < 2:
		push_error("Scaffold 3D JSON has no usable styles/resolution")
		return

	var total_width: float = float(styles.size()) * display_span_m + float(maxi(styles.size() - 1, 0)) * panel_gap_m
	var start_x: float = -total_width * 0.5 + display_span_m * 0.5
	for i in range(styles.size()):
		var style: Dictionary = styles[i]
		var offset_x: float = start_x + float(i) * (display_span_m + panel_gap_m)
		var mesh: ArrayMesh = _build_mesh(style, res, offset_x)
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = "Scaffold_%s" % String(style.get("key", "style"))
		mi.mesh = mesh
		mi.material_override = _terrain_material()
		add_child(mi)
		_panel_count += 1

		var label: Label3D = Label3D.new()
		label.name = "Label_%s" % String(style.get("key", "style"))
		label.text = String(style.get("key", "style"))
		label.font_size = 90
		label.modulate = Color(0.90, 0.92, 0.90)
		label.outline_size = 8
		label.position = Vector3(offset_x - display_span_m * 0.44, 500.0, -display_span_m * 0.58)
		label.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
		add_child(label)

func _build_mesh(style: Dictionary, res: int, offset_x: float) -> ArrayMesh:
	var heights: Array = style.get("height", [])
	var ranges: Array = style.get("range", [])
	var channels: Array = style.get("channel", [])
	var rocks: Array = style.get("rock", [])
	var snows: Array = style.get("snow", [])
	var valleys: Array = style.get("valley", [])
	var min_h: float = float(style.get("height_min", 0.0))
	var step: float = display_span_m / float(res - 1)
	var half: float = display_span_m * 0.5

	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	vertices.resize(res * res)
	normals.resize(res * res)
	colors.resize(res * res)

	for z in range(res):
		for x in range(res):
			var idx: int = z * res + x
			var y: float = (float(heights[idx]) - min_h) * height_scale
			vertices[idx] = Vector3(offset_x + float(x) * step - half, y, float(z) * step - half)
			normals[idx] = _normal_at(heights, res, x, z, min_h, step)
			colors[idx] = _color_at(
				float(ranges[idx]),
				float(channels[idx]),
				float(rocks[idx]),
				float(snows[idx]),
				float(valleys[idx])
			)

	var indices: PackedInt32Array = PackedInt32Array()
	indices.resize((res - 1) * (res - 1) * 6)
	var out: int = 0
	for z in range(res - 1):
		for x in range(res - 1):
			var a: int = z * res + x
			var b: int = a + 1
			var c: int = a + res
			var d: int = c + 1
			indices[out] = a; out += 1
			indices[out] = c; out += 1
			indices[out] = b; out += 1
			indices[out] = b; out += 1
			indices[out] = c; out += 1
			indices[out] = d; out += 1

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_total_vertices += vertices.size()
	return mesh

func _normal_at(heights: Array, res: int, x: int, z: int, min_h: float, step: float) -> Vector3:
	var xl: int = maxi(x - 1, 0)
	var xr: int = mini(x + 1, res - 1)
	var zu: int = maxi(z - 1, 0)
	var zd: int = mini(z + 1, res - 1)
	var left: float = (float(heights[z * res + xl]) - min_h) * height_scale
	var right: float = (float(heights[z * res + xr]) - min_h) * height_scale
	var up: float = (float(heights[zu * res + x]) - min_h) * height_scale
	var down: float = (float(heights[zd * res + x]) - min_h) * height_scale
	var dx: float = (right - left) / maxf(float(xr - xl) * step, 0.001)
	var dz: float = (down - up) / maxf(float(zd - zu) * step, 0.001)
	return Vector3(-dx, 1.0, -dz).normalized()

func _color_at(range_mask: float, channel: float, rock: float, snow: float, valley: float) -> Color:
	var c: Color = Color(0.31, 0.38, 0.31).lerp(Color(0.52, 0.50, 0.45), clampf(range_mask, 0.0, 1.0))
	c = c.lerp(Color(0.62, 0.61, 0.57), clampf(rock, 0.0, 1.0) * 0.70)
	c = c.lerp(Color(0.19, 0.34, 0.29), clampf(valley, 0.0, 1.0) * 0.65)
	c = c.lerp(Color(0.12, 0.20, 0.23), clampf(channel, 0.0, 1.0) * 0.30)
	c = c.lerp(Color(0.92, 0.91, 0.84), clampf(snow, 0.0, 1.0))
	return c

func _terrain_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mat.albedo_color = Color.WHITE
	return mat

func _spawn_camera() -> void:
	var cam: Camera3D = Camera3D.new()
	cam.name = "FlyCamera"
	cam.set_script(FLY_CAMERA)
	cam.fov = 68.0
	cam.look_at_from_position(
		Vector3(0.0, 4300.0, display_span_m * 1.25),
		Vector3(0.0, 1250.0, 0.0),
		Vector3.UP
	)
	add_child(cam)
	cam.make_current()
