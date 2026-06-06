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
# M1.6: 6 levels @ base span 508m, radius 3 -> coarsest reaches ~49km (30km goal
# with margin). Each coarser level doubles per-page span, so reach is exponential
# for linear page cost. (level span = base_span * 2^level.)
@export var num_levels: int = 6            # fine (0) + coarse blankets, out to the horizon
@export var ring_radius: int = 3           # pages each side, per level, around camera
@export var evict_margin: int = 1          # hysteresis: keep_radius = ring_radius + margin
@export var max_new_per_frame: int = 4
@export var show_page_tint: bool = false   # debug checkerboard marking page edges (off = clean look)
# M1.7: collision for NEAR fine (level-0) pages only — you stand on the fine
# surface, not the coarse horizon blanket. radius 1 = the 3x3 fine block around
# the camera, so the page you're on plus every neighbor you could step onto is
# collidable before you reach it (no edge fall-through) without building dozens
# of bodies. Built async off the main thread (00 §2.2 collision is a renderer
# concern); kept cheap for the RTX 3070 minimum target.
@export var collision_radius: int = 1       # level-0 pages each side around camera with collision

var _pool: RefCounted
var _ring_shader: Resource
var _instances := {}                       # "L:gx:gz" -> MeshInstance3D
var _cam: Camera3D
# M1.7 collision state (level-0 pages only). "gx:gz" keys.
var _collisions := {}                       # "gx:gz" -> StaticBody3D (resident collision body)
var _collision_building := {}               # "gx:gz" -> true while a WorkerThreadPool task is in flight
# M1.9 profiling (read by the perf HUD). Microseconds spent in this view's
# per-frame work, split so we can attribute the fast-motion spike: total
# _process, and just the mesh/material instance creation. The pool exposes its
# own produce_us separately. Cheap: two Time.get_ticks_usec() reads.
var prof_process_us := 0
var prof_mesh_us := 0
var _mesh_us_accum := 0                      # accumulates across _make_page_instance calls this frame

func _ready() -> void:
	_pool = ClassDB.instantiate("PagePool")
	if _pool == null:
		push_error("M1.5: PagePool not registered."); return
	if not _pool.initialize(SHADER):
		push_error("M1.5: PagePool.initialize failed (need --rendering-driver vulkan)."); return
	_pool.configure(page_res, spacing, seed_val, octaves, base_freq, amplitude, max_new_per_frame)
	_ring_shader = load(RING)
	_spawn_camera()
	var span: float = _pool.page_span()
	var reach: float = ring_radius * span * pow(2.0, num_levels - 1)
	print("M1.6: %d-level clipmap, ring_radius %d, base span %.0fm -> reach ~%.1f km" % [
		num_levels, ring_radius, span, reach / 1000.0])

func _process(_dt: float) -> void:
	if _cam == null:
		return
	var _t_start := Time.get_ticks_usec()
	_mesh_us_accum = 0
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
	_update_collision(cam_x, cam_z, base_span)

	# M1.9 profiling: record this frame's view-side cost for the HUD.
	prof_mesh_us = _mesh_us_accum
	prof_process_us = Time.get_ticks_usec() - _t_start

# Resident terrain height (world Y) at a world XZ, read from the SAME level-0
# pool heights the collision uses (00 §2.2 one source). Returns NAN if that page
# isn't resident. For demo/character spawn use (sample the floor without a
# physics query); the render/collision paths don't depend on this.
func page_terrain_height(wx: float, wz: float) -> float:
	var span: float = page_span_value()
	var gx: int = int(floor(wx / span))
	var gz: int = int(floor(wz / span))
	var heights: PackedFloat32Array = _pool.get_page_heights(0, gx, gz)
	if heights.size() != page_res * page_res:
		return NAN
	# Nearest cell within the page (page-local world -> cell).
	var cx: int = clampi(int(round((wx - gx * span) / spacing)), 0, page_res - 1)
	var cz: int = clampi(int(round((wz - gz * span) / spacing)), 0, page_res - 1)
	return heights[cz * page_res + cx]

func page_span_value() -> float:
	return (page_res - 1) * spacing

# M1.7 — collision for NEAR fine (level-0) pages. Each frame: build bodies for
# in-radius level-0 pages whose heights are resident (async, off the main thread
# via WorkerThreadPool), and free bodies for pages that left the radius. The
# heights are read on the MAIN thread (a cheap CoW handle from the pool) and
# passed INTO the worker, so the worker touches only a plain array + local node
# construction (never the pool or the active tree) — then call_deferred adds the
# finished StaticBody3D on the main thread (the documented Godot pattern).
# collision_radius (1) <= keep (ring_radius+evict_margin), so every collision
# page is already pinned by the mesh pass -> its heights can't be evicted from
# under a live body.
func _update_collision(cam_x: float, cam_z: float, base_span: float) -> void:
	var ccx: int = int(floor(cam_x / base_span))
	var ccz: int = int(floor(cam_z / base_span))

	# 1. free bodies that left the radius (small margin = mesh-like hysteresis).
	var drop_radius: int = collision_radius + evict_margin
	for key in _collisions.keys():
		var p: PackedStringArray = key.split(":")
		var cheb: int = maxi(absi(int(p[0]) - ccx), absi(int(p[1]) - ccz))
		if cheb > drop_radius:
			_collisions[key].queue_free()
			_collisions.erase(key)

	# 2. build bodies for in-radius level-0 pages that have none yet.
	for gz in range(ccz - collision_radius, ccz + collision_radius + 1):
		for gx in range(ccx - collision_radius, ccx + collision_radius + 1):
			var key := "%d:%d" % [gx, gz]
			if _collisions.has(key) or _collision_building.has(key):
				continue
			# Heights must be resident (the fine page must be produced first).
			var heights: PackedFloat32Array = _pool.get_page_heights(0, gx, gz)
			if heights.size() != page_res * page_res:
				continue                       # not produced yet; try again next frame
			_collision_building[key] = true
			# Off-thread: pack the HeightMapShape3D + body from the plain array.
			WorkerThreadPool.add_task(_build_collision_body.bind(key, gx, gz, heights))

# Worker-thread task: build the shape + body from a plain height array (no pool,
# no tree access). HeightMapShape3D vertices are spaced 1 unit on X/Z and the
# grid is centered on the body origin (verified), so we scale by cell_spacing
# and position the body at the page CENTRE (same formula the mesh uses). map_data
# is row-major width*depth with X=width,Z=depth, matching the field's z*res+x.
func _build_collision_body(key: String, gx: int, gz: int, heights: PackedFloat32Array) -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = page_res
	shape.map_depth = page_res
	shape.map_data = heights

	var col := CollisionShape3D.new()
	col.shape = shape

	var body := StaticBody3D.new()
	body.add_child(col)                        # building off-tree is fine; only add_child INTO the active tree must defer
	var span: float = (page_res - 1) * spacing # level-0 world span (cell_spacing = spacing)
	body.position = Vector3(gx * span + span * 0.5, 0.0, gz * span + span * 0.5)
	# 1-unit grid -> scale X/Z to cell_spacing; Y stays 1 (heights are world units).
	body.scale = Vector3(spacing, 1.0, spacing)

	call_deferred("_attach_collision_body", key, body)

# Main-thread: attach the finished body. If the camera moved out of range during
# the build, the body is still attached here and the NEXT frame's eviction pass
# (step 1) frees it once it's tracked and outside drop_radius — self-heals in one
# frame, no leak. The has()-check just guards against a double-add.
func _attach_collision_body(key: String, body: StaticBody3D) -> void:
	_collision_building.erase(key)
	if not _collisions.has(key):
		add_child(body)
		_collisions[key] = body
	else:
		body.queue_free()                      # already built (shouldn't happen, but no double-add)

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
	var _t := Time.get_ticks_usec()
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
	_mesh_us_accum += Time.get_ticks_usec() - _t   # M1.9 profiling: per-frame mesh-build cost
	return mi

func _spawn_camera() -> void:
	var span: float = _pool.page_span()
	# Outer reach of the coarsest level (where the loaded world ends).
	var reach: float = ring_radius * span * pow(2.0, num_levels - 1)
	var terrain_y := amplitude * 1.2
	var cam := Camera3D.new()
	cam.far = reach * 1.3                       # see the whole loaded extent + margin
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
	e.background_color = Color(0.62, 0.70, 0.80)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.55, 0.6)
	e.ambient_light_energy = 0.6
	# Distance fog matched to the loaded extent: the coarsest edge fades into the
	# sky so the boundary of the loaded world is never a visible hard line
	# (WG10 lesson: match fog/far to loaded extent). Fog starts well out so near
	# terrain stays crisp; ends near the reach so the far edge dissolves.
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_DEPTH
	e.fog_light_color = Color(0.62, 0.70, 0.80)  # match sky so it reads as haze->horizon
	e.fog_depth_begin = reach * 0.45
	e.fog_depth_end = reach * 0.98
	e.fog_density = 0.0                          # depth fog drives it, not exponential
	env.environment = e
	add_child(env)
