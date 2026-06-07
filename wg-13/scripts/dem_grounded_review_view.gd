extends Node3D
# Review-only 3D prototype for the DEM-grounded terrain direction.
# It copies the demo-scene ergonomics (fly camera, Player compatibility, HUD
# compatibility) but does not touch the live streaming WorldView or GLSL field.

const FLY := "res://scripts/fly_camera.gd"

@export var seed_val: int = 13013
@export var terrain_res: int = 193
@export var terrain_span: float = 4096.0
@export var surface_gap: float = 5400.0
@export var height_scale: float = 1200.0
@export var coarse_cells: int = 17

var _cam: Camera3D
var _pool = null
var prof_process_us: int = 0
var prof_mesh_us: int = 0
var _collisions: Dictionary = {}

var _track: Node3D
var _features: Dictionary = {}
var _candidate_origin: Vector3 = Vector3.ZERO
var _coarse_origin: Vector3 = Vector3.ZERO

func _ready() -> void:
	_candidate_origin = Vector3(surface_gap * 0.5, 0.0, 0.0)
	_coarse_origin = Vector3(-surface_gap * 0.5, 0.0, 0.0)
	_features = _build_features(seed_val)
	_add_environment()
	_build_surface("Coarse256mCache", _coarse_origin, true)
	_build_surface("ContinuousCandidate", _candidate_origin, false)
	_add_feature_lines()
	_add_labels()
	_spawn_camera()
	_track = _cam
	print("DEM-GROUNDED REVIEW: left = 256m cache failure, right = continuous scaffold candidate")

func _process(_dt: float) -> void:
	var t0: int = Time.get_ticks_usec()
	prof_mesh_us = 0
	prof_process_us = Time.get_ticks_usec() - t0

func page_span_value() -> float:
	return terrain_span

func set_track_target(target: Node3D) -> void:
	_track = target if target != null else _cam

func view_mode() -> int:
	return 0

func view_mode_name() -> String:
	return "dem review"

func page_terrain_height(wx: float, wz: float) -> float:
	var best_dist := INF
	var best_height := NAN
	for item in [
		{"origin": _candidate_origin, "coarse": false},
		{"origin": _coarse_origin, "coarse": true},
	]:
		var origin: Vector3 = item["origin"]
		var lx := (wx - origin.x) / (terrain_span * 0.5)
		var lz := (wz - origin.z) / (terrain_span * 0.5)
		var dx := maxf(absf(lx) - 1.0, 0.0)
		var dz := maxf(absf(lz) - 1.0, 0.0)
		var dist := dx * dx + dz * dz
		if dist < best_dist:
			best_dist = dist
			lx = clampf(lx, -1.0, 1.0)
			lz = clampf(lz, -1.0, 1.0)
			best_height = _height_coarse(lx, lz) if item["coarse"] else _height_candidate(lx, lz)
	return best_height

func _add_environment() -> void:
	var light := DirectionalLight3D.new()
	light.name = "ReviewSun"
	light.light_energy = 2.2
	light.rotation_degrees = Vector3(-48.0, -34.0, 0.0)
	add_child(light)

	var fill := DirectionalLight3D.new()
	fill.name = "ReviewFill"
	fill.light_energy = 0.55
	fill.rotation_degrees = Vector3(-28.0, 135.0, 0.0)
	add_child(fill)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.58, 0.69, 0.78)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.48, 0.52, 0.56)
	environment.ambient_light_energy = 0.72
	env.environment = environment
	add_child(env)

func _spawn_camera() -> void:
	_cam = Camera3D.new()
	_cam.name = "FlyCamera"
	_cam.far = 60000.0
	_cam.near = 0.1
	_cam.set_script(load(FLY))
	_cam.set("speed", 520.0)
	_cam.set("boost_mult", 5.0)
	add_child(_cam)
	_cam.global_position = _candidate_origin + Vector3(-700.0, 950.0, -1950.0)
	_cam.look_at(_candidate_origin + Vector3(250.0, 130.0, 450.0), Vector3.UP)
	_cam.make_current()

func _build_surface(name: String, origin: Vector3, coarse: bool) -> void:
	var t0: int = Time.get_ticks_usec()
	var res: int = maxi(terrain_res, 33)
	var step: float = terrain_span / float(res - 1)
	var heights := PackedFloat32Array()
	heights.resize(res * res)
	var min_h: float = INF
	var max_h: float = -INF

	for z in range(res):
		var lz := _coord01_to_local(float(z) / float(res - 1))
		for x in range(res):
			var lx := _coord01_to_local(float(x) / float(res - 1))
			var h: float = _height_coarse(lx, lz) if coarse else _height_candidate(lx, lz)
			var idx: int = z * res + x
			heights[idx] = h
			min_h = minf(min_h, h)
			max_h = maxf(max_h, h)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	vertices.resize(res * res)
	normals.resize(res * res)
	colors.resize(res * res)
	uvs.resize(res * res)

	for z in range(res):
		for x in range(res):
			var idx: int = z * res + x
			var wx: float = origin.x - terrain_span * 0.5 + float(x) * step
			var wz: float = origin.z - terrain_span * 0.5 + float(z) * step
			var h: float = heights[idx]
			vertices[idx] = Vector3(wx, h, wz)
			normals[idx] = _normal_from_grid(heights, res, x, z, step)
			colors[idx] = _height_color(h, min_h, max_h, coarse)
			uvs[idx] = Vector2(float(x) / float(res - 1), float(z) / float(res - 1))

	var indices := PackedInt32Array()
	indices.resize((res - 1) * (res - 1) * 6)
	var ii: int = 0
	for z in range(res - 1):
		for x in range(res - 1):
			var a: int = z * res + x
			var b: int = a + 1
			var c: int = a + res
			var d: int = c + 1
			indices[ii] = a; ii += 1
			indices[ii] = c; ii += 1
			indices[ii] = b; ii += 1
			indices[ii] = b; ii += 1
			indices[ii] = c; ii += 1
			indices[ii] = d; ii += 1

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.material_override = _terrain_material()
	add_child(mi)
	_add_trimesh_collision(mesh, name + "Collision")
	if coarse:
		_add_coarse_grid(origin)
	prof_mesh_us += Time.get_ticks_usec() - t0

func _add_trimesh_collision(mesh: ArrayMesh, name: String) -> void:
	var shape := mesh.create_trimesh_shape()
	if shape == null:
		return
	var body := StaticBody3D.new()
	body.name = name
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	add_child(body)

func _terrain_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.92
	mat.metallic = 0.0
	return mat

func _line_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = false
	return mat

func _add_feature_lines() -> void:
	var mesh := ImmediateMesh.new()
	var mat := _line_material()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for ridge in _features["ridges"]:
		mesh.surface_set_color(Color(0.92, 0.88, 0.78, 0.92))
		_add_line_sampled(mesh, _candidate_origin, ridge["ax"], ridge["az"], ridge["bx"], ridge["bz"], 32, 18.0)
	for channel in _features["channels"]:
		mesh.surface_set_color(Color(0.07, 0.24, 0.56, 0.95))
		var pts: Array = channel["points"]
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			_add_line_sampled(mesh, _candidate_origin, a.x, a.y, b.x, b.y, 18, 13.0)
	mesh.surface_end()

	var mi := MeshInstance3D.new()
	mi.name = "CandidateRidgeDrainageOverlay"
	mi.mesh = mesh
	add_child(mi)

func _add_coarse_grid(origin: Vector3) -> void:
	var mesh := ImmediateMesh.new()
	var mat := _line_material()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	mesh.surface_set_color(Color(1.0, 1.0, 1.0, 0.58))
	var cells: int = maxi(coarse_cells - 1, 2)
	for i in range(cells + 1):
		var t := float(i) / float(cells)
		var l := _coord01_to_local(t)
		_add_line_sampled(mesh, origin, l, -1.0, l, 1.0, 64, 16.0, true)
		_add_line_sampled(mesh, origin, -1.0, l, 1.0, l, 64, 16.0, true)
	mesh.surface_end()

	var mi := MeshInstance3D.new()
	mi.name = "CoarseCacheSampleGrid"
	mi.mesh = mesh
	add_child(mi)

func _add_line_sampled(mesh: ImmediateMesh, origin: Vector3, ax: float, az: float, bx: float, bz: float, steps: int, lift: float, coarse := false) -> void:
	for i in range(steps):
		var t0 := float(i) / float(steps)
		var t1 := float(i + 1) / float(steps)
		var x0 := lerpf(ax, bx, t0)
		var z0 := lerpf(az, bz, t0)
		var x1 := lerpf(ax, bx, t1)
		var z1 := lerpf(az, bz, t1)
		var h0 := _height_coarse(x0, z0) if coarse else _height_candidate(x0, z0)
		var h1 := _height_coarse(x1, z1) if coarse else _height_candidate(x1, z1)
		mesh.surface_add_vertex(origin + Vector3(x0 * terrain_span * 0.5, h0 + lift, z0 * terrain_span * 0.5))
		mesh.surface_add_vertex(origin + Vector3(x1 * terrain_span * 0.5, h1 + lift, z1 * terrain_span * 0.5))

func _add_labels() -> void:
	_add_label("256 m cached macro\nblocky at altitude", _coarse_origin + Vector3(0.0, 950.0, -terrain_span * 0.56), Color(1.0, 0.92, 0.72))
	_add_label("DEM-grounded candidate\nscaffold + drainage + residual", _candidate_origin + Vector3(0.0, 950.0, -terrain_span * 0.56), Color(0.82, 0.94, 1.0))
	_add_label("G = walk, F = fly, T = auto-tour", Vector3(0.0, 1050.0, terrain_span * 0.62), Color(0.95, 0.98, 1.0))

func _add_label(text: String, pos: Vector3, color: Color) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 42
	label.outline_size = 8
	label.modulate = color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
	label.global_position = pos

func _normal_from_grid(heights: PackedFloat32Array, res: int, x: int, z: int, step: float) -> Vector3:
	var xl := maxi(x - 1, 0)
	var xr := mini(x + 1, res - 1)
	var zu := maxi(z - 1, 0)
	var zd := mini(z + 1, res - 1)
	var h_l := heights[z * res + xl]
	var h_r := heights[z * res + xr]
	var h_u := heights[zu * res + x]
	var h_d := heights[zd * res + x]
	return Vector3(h_l - h_r, step * 2.0, h_u - h_d).normalized()

func _height_color(h: float, min_h: float, max_h: float, coarse: bool) -> Color:
	var t := _safe01((h - min_h) / maxf(max_h - min_h, 0.001))
	var c: Color
	if t < 0.22:
		c = Color(0.16, 0.33, 0.34).lerp(Color(0.22, 0.48, 0.38), t / 0.22)
	elif t < 0.48:
		c = Color(0.22, 0.48, 0.38).lerp(Color(0.48, 0.55, 0.28), (t - 0.22) / 0.26)
	elif t < 0.70:
		c = Color(0.48, 0.55, 0.28).lerp(Color(0.59, 0.48, 0.34), (t - 0.48) / 0.22)
	elif t < 0.88:
		c = Color(0.59, 0.48, 0.34).lerp(Color(0.52, 0.50, 0.48), (t - 0.70) / 0.18)
	else:
		c = Color(0.52, 0.50, 0.48).lerp(Color(0.92, 0.93, 0.88), (t - 0.88) / 0.12)
	if coarse:
		c = c.lerp(Color(0.80, 0.76, 0.62), 0.22)
	return c

func _height_candidate(lx: float, lz: float) -> float:
	var scaffold := _macro_scaffold(lx, lz)
	var structure := _structure_height(lx, lz)
	var residual := _residual_detail(lx, lz, scaffold, structure)
	return (scaffold * 1.12 + structure * 0.66 + residual) * height_scale

func _height_coarse(lx: float, lz: float) -> float:
	var cells: int = maxi(coarse_cells, 3)
	var gx := (lx * 0.5 + 0.5) * float(cells - 1)
	var gz := (lz * 0.5 + 0.5) * float(cells - 1)
	var x0 := clampi(int(floor(gx)), 0, cells - 1)
	var z0 := clampi(int(floor(gz)), 0, cells - 1)
	var x1 := mini(x0 + 1, cells - 1)
	var z1 := mini(z0 + 1, cells - 1)
	var tx := gx - float(x0)
	var tz := gz - float(z0)
	var a := _height_candidate(_grid_to_local(x0, cells), _grid_to_local(z0, cells))
	var b := _height_candidate(_grid_to_local(x1, cells), _grid_to_local(z0, cells))
	var c := _height_candidate(_grid_to_local(x0, cells), _grid_to_local(z1, cells))
	var d := _height_candidate(_grid_to_local(x1, cells), _grid_to_local(z1, cells))
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)

func _macro_scaffold(lx: float, lz: float) -> float:
	var wx := lx + _signed_fbm(lx + 17.3, lz - 4.2, seed_val + 300, 1.2, 3, 0.5, 2.1) * 0.22
	var wz := lz + _signed_fbm(lx - 8.6, lz + 9.5, seed_val + 460, 1.0, 3, 0.5, 2.0) * 0.22
	var broad := _smoothstep(0.36, 0.82, _fbm(wx, wz, seed_val + 3, 1.15, 4, 0.52, 2.0))
	var range := 0.0
	for ridge in _features["ridges"]:
		var d := _dist_segment(wx, wz, ridge["ax"], ridge["az"], ridge["bx"], ridge["bz"])
		range = maxf(range, exp(-pow(d / (ridge["width"] * 8.0), 2.0)) * ridge["amp"])
	var lowland := 0.18 * _signed_fbm(wx, wz, seed_val + 900, 1.8, 3, 0.48, 2.0)
	return _safe01(0.14 + broad * 0.45 + range * 0.74 + lowland)

func _structure_height(lx: float, lz: float) -> float:
	var ridges := 0.0
	var valleys := 0.0
	for ridge in _features["ridges"]:
		var d := _dist_segment(lx, lz, ridge["ax"], ridge["az"], ridge["bx"], ridge["bz"])
		var crest := exp(-pow(d / ridge["width"], 2.0))
		var shoulder := exp(-pow(d / (ridge["width"] * 3.0), 2.0)) * 0.42
		ridges += (crest + shoulder) * ridge["amp"]
	for channel in _features["channels"]:
		var d := _dist_polyline(lx, lz, channel["points"])
		var floor_v := exp(-pow(d / channel["width"], 2.0))
		var valley := exp(-pow(d / (channel["width"] * 4.2), 2.0)) * 0.5
		var order_boost := 0.78 + float(channel["order"]) * 0.13
		valleys += (floor_v + valley) * channel["amp"] * order_boost
	return ridges - valleys

func _residual_detail(lx: float, lz: float, scaffold: float, structure: float) -> float:
	var slope_proxy := _safe01(absf(structure) * 1.6 + scaffold * 0.45)
	var amp := lerpf(0.018, 0.13, slope_proxy)
	var aligned := _signed_fbm(lx * 1.7 + lz * 0.25, lz * 0.8 - lx * 0.2, seed_val + 2000, 10.0, 4, 0.47, 2.04)
	var gullies := absf(_signed_fbm(lx, lz, seed_val + 2200, 19.0, 3, 0.52, 2.0))
	var benches := _signed_fbm(lx + scaffold * 0.2, lz - scaffold * 0.2, seed_val + 2400, 5.5, 3, 0.5, 2.0)
	return (aligned * 0.72 + (gullies - 0.45) * 0.32 + benches * 0.24) * amp

func _build_features(seed: int) -> Dictionary:
	var ridges: Array = []
	var channels: Array = []
	for i in range(7):
		var cx := _hash01(i, seed, 11) * 2.2 - 1.1
		var cz := _hash01(i, seed, 23) * 2.2 - 1.1
		var angle := _hash01(i, seed, 37) * TAU
		var length := lerpf(0.65, 1.55, _hash01(i, seed, 41))
		var dx := cos(angle) * length * 0.5
		var dz := sin(angle) * length * 0.5
		ridges.append({
			"ax": cx - dx,
			"az": cz - dz,
			"bx": cx + dx,
			"bz": cz + dz,
			"width": lerpf(0.035, 0.095, _hash01(i, seed, 53)),
			"amp": lerpf(0.18, 0.48, _hash01(i, seed, 67)),
		})
	for i in range(8):
		var start_x := _hash01(i, seed, 71) * 2.2 - 1.1
		var end_x := _hash01(i, seed, 83) * 2.2 - 1.1
		var start_z := -1.16 + _hash01(i, seed, 97) * 0.32
		var end_z := 1.16 - _hash01(i, seed, 109) * 0.32
		var bend := lerpf(-0.42, 0.42, _hash01(i, seed, 113))
		var phase := _hash01(i, seed, 127) * TAU
		var points: Array = []
		for s in range(6):
			var t := float(s) / 5.0
			var curve := sin(t * PI + phase) * bend
			points.append(Vector2(lerpf(start_x, end_x, t) + curve * sin(t * PI), lerpf(start_z, end_z, t)))
		channels.append({
			"points": points,
			"width": lerpf(0.028, 0.075, _hash01(i, seed, 131)),
			"amp": lerpf(0.14, 0.40, _hash01(i, seed, 149)),
			"order": 1 + int(floor(_hash01(i, seed, 151) * 4.0)),
		})
	return {"ridges": ridges, "channels": channels}

func _dist_segment(px: float, pz: float, ax: float, az: float, bx: float, bz: float) -> float:
	var vx := bx - ax
	var vz := bz - az
	var wx := px - ax
	var wz := pz - az
	var denom := maxf(vx * vx + vz * vz, 0.00001)
	var t := _safe01((wx * vx + wz * vz) / denom)
	var qx := ax + vx * t
	var qz := az + vz * t
	return Vector2(px - qx, pz - qz).length()

func _dist_polyline(px: float, pz: float, points: Array) -> float:
	var best := INF
	for i in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		best = minf(best, _dist_segment(px, pz, a.x, a.y, b.x, b.y))
	return best

func _fbm(x: float, z: float, seed: int, base_scale: float, octaves: int, gain: float, lacunarity: float) -> float:
	var total := 0.0
	var amp := 0.5
	var norm := 0.0
	var scale := base_scale
	for i in range(octaves):
		total += _value_noise(x, z, scale, seed + i * 131) * amp
		norm += amp
		amp *= gain
		scale *= lacunarity
	return total / maxf(norm, 0.00001)

func _signed_fbm(x: float, z: float, seed: int, base_scale: float, octaves: int, gain: float, lacunarity: float) -> float:
	return _fbm(x, z, seed, base_scale, octaves, gain, lacunarity) * 2.0 - 1.0

func _value_noise(x: float, z: float, scale: float, seed: int) -> float:
	var sx := x * scale
	var sz := z * scale
	var ix := int(floor(sx))
	var iz := int(floor(sz))
	var fx := sx - float(ix)
	var fz := sz - float(iz)
	var ux := fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0)
	var uz := fz * fz * fz * (fz * (fz * 6.0 - 15.0) + 10.0)
	var a := _hash01(ix, iz, seed)
	var b := _hash01(ix + 1, iz, seed)
	var c := _hash01(ix, iz + 1, seed)
	var d := _hash01(ix + 1, iz + 1, seed)
	return lerpf(lerpf(a, b, ux), lerpf(c, d, ux), uz)

func _hash01(a: int, b: int, c: int) -> float:
	var n := sin(float(a) * 127.1 + float(b) * 311.7 + float(c) * 74.7) * 43758.5453123
	return n - floor(n)

func _smoothstep(a: float, b: float, x: float) -> float:
	var t := _safe01((x - a) / (b - a))
	return t * t * (3.0 - 2.0 * t)

func _safe01(v: float) -> float:
	return clampf(v, 0.0, 1.0)

func _coord01_to_local(v: float) -> float:
	return v * 2.0 - 1.0

func _grid_to_local(i: int, cells: int) -> float:
	return _coord01_to_local(float(i) / float(cells - 1))
