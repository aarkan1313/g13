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

const SHADER := "res://shaders/field_height_dem_grounded.glsl"
const RING := "res://shaders/ring_displace.gdshader"
const FLY := "res://scripts/fly_camera.gd"
const DEM_KERNEL := "res://../archive/from_workflows_worldgen10_wg10/worldgen_terrain/packs/dem_v1/kernels/badlands__cop30_badlands_utah_canyonlands_109_7_38_25.npy"
const DEM_REVIEW_FOOTPRINT_M := 32768.0
const DEM_SOURCE_RELIEF_M := 1600.0
const DEM_REVIEW_AMPLITUDE_M := 520.0
const REVIEW_START := Vector3(30000.0, 1180.0, 18000.0)
const REVIEW_LOOK_AT := Vector3(31800.0, 360.0, 17480.0)
# Half the vertical extent of each page's frustum-cull AABB (world units). Must
# exceed the composed terrain's |height| (M2.3 peaks ~1.9km, valleys ~1km) so a
# vertex-shader-displaced plane is never wrongly culled when the camera tilts.
const AABB_HALF_HEIGHT := 6000.0

@export var page_res: int = 128
@export var spacing: float = 4.0
@export var seed_val: float = 1234.0
@export var octaves: int = 5
@export var base_freq: float = 0.0015
@export var amplitude: float = 240.0
# M1.6: 6 levels @ base span 508m, radius 3 -> coarsest reaches ~49km (30km goal
# with margin). Each coarser level doubles per-page span, so reach is exponential
# for linear page cost. (level span = base_span * 2^level.)
# STREAMING CONFIG = the M2.6 perf-passed production values (world_view.gd).
# RESTORED 2026-06-07 after measuring that this prototype's earlier "push harder"
# config (r5, 7lvl, eager 128) was the "performance is bad": burst median-of-maxes
# 85.7ms, 198/720 frames over budget, 1100 resident pages -- vs production's r3/8lvl/
# eager8 at 13.2ms, 1/720. Reach comes from num_levels (2^L), NOT ring_radius
# (which costs pages QUADRATICALLY for only linear reach), so 8 levels gives MORE
# reach (~195km) than the old 7-level/r5 (~162km) for FAR fewer pages. (A/B measured.)
@export var num_levels: int = 7            # 7 levels @ base span 508m, radius 3 -> reach ~98km (~100km). (Reach is NOT the "view distance" lever -- proven pixel-identical 49 vs 779km; the limit is terrain composition, mostly-flat world. See world_view.gd note.)
@export var ring_radius: int = 3           # pages each side, per level. NOT the reach lever -- raising it scales pages quadratically (r5 = 1100 resident, the lag). Reach = num_levels.
@export var evict_margin: int = 1          # hysteresis: keep_radius = ring_radius + margin
@export var max_new_per_frame: int = 4
# Mid-coarse eager pages produced per frame (coarsest level exempt = never-black
# floor). SPREADS the burst across frames -- the whole point of M2.6. eager 128 let
# a single frame dump up to 128 dispatches (the 83ms spikes). 8 is the production
# value: enough to fill ahead, low enough that no frame hitches.
@export var max_eager_per_frame: int = 8
@export var show_page_tint: bool = false   # debug checkerboard marking page edges (off = clean look)
@export var review_mesh_lod_bias: int = 2   # visual review only: keep coarse DEM pages from faceting at altitude
@export var review_mesh_min_subdiv: int = 96
# M1.7: collision for NEAR fine (level-0) pages only — you stand on the fine
# surface, not the coarse horizon blanket. radius 1 = the 3x3 fine block around
# the camera, so the page you're on plus every neighbor you could step onto is
# collidable before you reach it (no edge fall-through) without building dozens
# of bodies. Built async off the main thread (00 §2.2 collision is a renderer
# concern); kept cheap for the RTX 3070 minimum target.
@export var collision_radius: int = 0       # review-only: visual candidate skips level-0 CPU readback/collision

var _pool: RefCounted
var _ring_shader: Resource
# Floating origin (engine module). Keeps the camera near the Godot origin by
# rebasing the displayed world in whole fine-cells, so the world stays CENTERED on
# you (no "reach the outside edge") and float precision holds at distance. Terrain
# is computed in ABSOLUTE coords via _origin.to_absolute(); the rebase is whole-cell
# so generation is unchanged (proven by m1_8_origin_rebase_check). See world_origin.gd.
var _origin: RefCounted
# View mode: 0 = normal height shading, 1 = temperature, 2 = moisture (M2.1),
# 3 = biome (M2.2). Cycled by V; pushed to every page material so the field's
# climate/biome outputs are visible ON the terrain you're flying (the same render
# path real biome textures will use in M3).
var _view_mode := 0
const VIEW_MODE_NAMES := ["normal", "temperature", "moisture", "biome"]
var _instances := {}                       # "L:gx:gz" -> MeshInstance3D
var _inst_meta := {}                        # "L:gx:gz" -> Vector3i(level,gx,gz) — parsed once, so
											# the per-frame loops never re-split the string key (M1.9.3c)
# (The GDScript per-level scan-skip state was removed when the streaming policy
# moved to Rust update_streaming, 00 §4 — Rust owns the scan now.)
var _cam: Camera3D
# Smoothed travel direction (world XZ), used to bias page production toward where
# you're flying so the leading edge loads before you reach it (anti-pop-in).
var _prev_track_x: float = INF
var _prev_track_z: float = INF
var _travel_dir := Vector2.ZERO              # smoothed unit-ish vector in (x,z)
# M2.3-fix — the node whose world position drives STREAMING + COLLISION. Defaults
# to the fly camera; in WALK mode the player sets it to the CAPSULE so the world
# follows where you actually ARE (not the frozen fly-cam at the drop-in spot).
# Without this, walking away from the drop point left the collision zone -> the
# capsule fell through rendered-but-not-collidable terrain. Set via set_track_target().
var _track: Node3D
# M1.9.3a — kill the per-page alloc spike (measured: mesh+material `new` on the
# eager burst was the dominant cost). (1) One SHARED PlaneMesh per level: every
# page at a level has identical geometry, so build it once and reference it.
# (2) A FREE-LIST of MeshInstance3D (with their material): evicted instances are
# recycled (texture re-pointed, repositioned) instead of freed + re-newed. Steady
# state and bursts now allocate nothing.
var _level_mesh := {}                       # level -> shared PlaneMesh
var _free_instances: Array = []             # recycled MeshInstance3D pool
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
	if _pool.has_method("load_dem_kernel_npy"):
		if not _pool.load_dem_kernel_npy(DEM_KERNEL, DEM_REVIEW_FOOTPRINT_M, DEM_SOURCE_RELIEF_M, DEM_REVIEW_AMPLITUDE_M):
			push_warning("DEM review: compact DEM kernel failed to load; running scaffold-only.")
	_pool.configure(page_res, spacing, seed_val, octaves, base_freq, amplitude, max_new_per_frame)
	if _pool.has_method("set_cpu_readback_enabled"):
		_pool.set_cpu_readback_enabled(false)
	_pool.set_max_eager_per_frame(max_eager_per_frame)
	_ring_shader = load(RING)
	# Floating origin: rebase quantum = the level-0 page span (one fine cell).
	_origin = load("res://scripts/world_origin.gd").new(_pool.page_span())
	_spawn_camera()
	_track = _cam            # default: stream/collide around the fly camera (WALK overrides)
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
	# Stream + collide around the ACTIVE controller (the capsule in WALK mode, else
	# the fly camera). Reading the frozen fly-cam here is what let a walking player
	# leave the collision zone and fall through (M2.3-fix). Guard against a freed
	# target by falling back to the camera.
	var tracker: Node3D = _track if (_track != null and is_instance_valid(_track)) else _cam

	# FLOATING ORIGIN: before streaming, pull the displayed world back toward the
	# Godot origin if the camera has drifted >= one fine cell. Moving THIS node
	# (View) shifts every page instance, collision body, and the fly camera in one
	# op (they're all children); the Player (sibling) is shifted separately. The
	# rebase is whole-cell so the absolute grid index is unchanged -> terrain
	# bit-identical (m1_8). This is what keeps the world centered on you and the far
	# edge far, and holds float precision at distance.
	var shift: Vector3 = _origin.maybe_rebase(tracker.global_position)
	if shift != Vector3.ZERO:
		position -= shift                                   # View + all children (pages, collision, fly cam)
		if _track != null and _track != _cam and is_instance_valid(_track):
			_track.global_position -= shift                # the Player capsule (a sibling, not under View)

	# Stream/collide around the ABSOLUTE camera position so the field's grid index
	# (floor(abs/span)) is unchanged by the rebase. tracker.global_position is in the
	# now-shifted Godot space; to_absolute() adds the accumulated offset back.
	var abs_track: Vector3 = _origin.to_absolute(tracker.global_position)
	var cam_x: float = abs_track.x
	var cam_z: float = abs_track.z

	# TEMP DEBUG: is the streaming center actually following the camera? Prints ~1/s.
	# Smoothed travel direction (XZ) for direction-biased production. When moving,
	# this points where you're flying; when ~stationary it decays toward zero (then
	# pure nearest-first takes over). EMA so a single jittery frame doesn't swing it.
	if _prev_track_x != INF:
		var mv := Vector2(cam_x - _prev_track_x, cam_z - _prev_track_z)
		if mv.length() > 0.01:
			_travel_dir = (_travel_dir * 0.8 + mv.normalized() * 0.2)
		else:
			_travel_dir *= 0.8
	_prev_track_x = cam_x
	_prev_track_z = cam_z
	var dir_len: float = _travel_dir.length()
	var travel_n := (_travel_dir / dir_len) if dir_len > 0.001 else Vector2.ZERO

	# STREAMING POLICY IS NOW IN RUST (00 §4). One call does the whole per-frame ring
	# scan + nearest-first/dir-bias ordering + 3-mode bounded production + pin + evict
	# + annulus visibility, on the absolute grid, and returns a DIFF. The view only
	# does node work for the changes (create/recycle/show/hide) — no per-frame scan,
	# no per-page pin FFI. (Migrated from the old GDScript loop; gate m1_5d.)
	var diff: Dictionary = _pool.update_streaming(
		cam_x, cam_z, ring_radius, evict_margin, num_levels, travel_n.x, travel_n.y)
	_apply_stream_diff(diff)

	_update_collision(cam_x, cam_z, base_span)

	# M1.9 profiling: record this frame's view-side cost for the HUD.
	prof_mesh_us = _mesh_us_accum
	prof_process_us = Time.get_ticks_usec() - _t_start

# Apply the Rust streaming DIFF: create instances for ADDED pages (binding their
# resident textures via the pool getters — cache hits), recycle REMOVED ones, and
# set visibility for SHOW/HIDE. Flat PackedInt32Array [level,gx,gz, ...] strided by
# 3. A newly-added page appears in ADDED (create) and in SHOW/HIDE (its visibility),
# so create first, then the show/hide loops set the flag. This replaces the old
# per-frame GDScript ring scan / pin / evict / annulus passes (now Rust, 00 §4).
func _apply_stream_diff(diff: Dictionary) -> void:
	var base_span: float = _pool.page_span()
	var added: PackedInt32Array = diff["added"]
	for i in range(0, added.size(), 3):
		var level: int = added[i]
		var gx: int = added[i + 1]
		var gz: int = added[i + 2]
		var key := "%d:%d:%d" % [level, gx, gz]
		if _instances.has(key):
			continue                          # already have a node (guard)
		var span: float = base_span * pow(2.0, level)
		var tex = _pool.get_page_height_tex(level, gx, gz)
		if tex == null:
			continue                          # produced-but-not-fetchable (shouldn't happen)
		_instances[key] = _make_page_instance(tex, level, gx, gz, span)
		_inst_meta[key] = Vector3i(level, gx, gz)
	var removed: PackedInt32Array = diff["removed"]
	for i in range(0, removed.size(), 3):
		var rkey := "%d:%d:%d" % [removed[i], removed[i + 1], removed[i + 2]]
		if _instances.has(rkey):
			_recycle_instance(_instances[rkey])
			_instances.erase(rkey)
			_inst_meta.erase(rkey)
	var show: PackedInt32Array = diff["show"]
	for i in range(0, show.size(), 3):
		var skey := "%d:%d:%d" % [show[i], show[i + 1], show[i + 2]]
		if _instances.has(skey):
			_instances[skey].visible = true
	var hide: PackedInt32Array = diff["hide"]
	for i in range(0, hide.size(), 3):
		var hkey := "%d:%d:%d" % [hide[i], hide[i + 1], hide[i + 2]]
		if _instances.has(hkey):
			_instances[hkey].visible = false

# M2.1 — V cycles the view mode (normal -> temperature -> moisture -> normal) and
# pushes it to every live page material so the climate fields show on the terrain.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_V:
		_view_mode = (_view_mode + 1) % VIEW_MODE_NAMES.size()
		_apply_view_mode()
		print("view mode: %s" % VIEW_MODE_NAMES[_view_mode])

# Push the current view mode to all displayed page materials AND the recycled
# free-list (so a recycled instance starts in the right mode before its per-page
# bind also sets it). New pages pick it up in _make_page_instance.
func _apply_view_mode() -> void:
	for key in _instances.keys():
		var mat: ShaderMaterial = _instances[key].material_override
		if mat != null:
			mat.set_shader_parameter("view_mode", _view_mode)
	for mi in _free_instances:
		var mat: ShaderMaterial = mi.material_override
		if mat != null:
			mat.set_shader_parameter("view_mode", _view_mode)

# M2.1 introspection (for the climate gate / HUD): current view mode + its name.
func view_mode() -> int:
	return _view_mode

func view_mode_name() -> String:
	return VIEW_MODE_NAMES[_view_mode]

# M2.3-fix — set the node whose position drives streaming + collision. The player
# calls this with itself on WALK (so the world follows the capsule) and with the
# fly camera on FLY. Pass null to restore the default (fly camera).
func set_track_target(target: Node3D) -> void:
	_track = target if target != null else _cam

# Resident terrain height (world Y) at a world XZ, read from the SAME level-0
# pool heights the collision uses (00 §2.2 one source). Returns NAN if that page
# isn't resident. For demo/character spawn use (sample the floor without a
# physics query); the render/collision paths don't depend on this.
func page_terrain_height(wx: float, wz: float) -> float:
	var span: float = page_span_value()
	# The caller passes GODOT-space XZ (e.g. the fly cam / player position). Pages are
	# keyed by ABSOLUTE grid index, so convert through the floating origin first —
	# otherwise after a rebase we'd look up the wrong page and the player would spawn
	# on the wrong column of terrain.
	if _origin != null:
		var a: Vector3 = _origin.to_absolute(Vector3(wx, 0.0, wz))
		wx = a.x
		wz = a.z
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
	if collision_radius <= 0:
		for key in _collisions.keys():
			_collisions[key].queue_free()
		_collisions.clear()
		_collision_building.clear()
		return
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

# (Annulus visibility + the per-frame ring scan / pin / evict are now owned by Rust
# PagePool.update_streaming (00 §4); the view applies its diff in _apply_stream_diff.
# The old GDScript _update_annulus_visibility / _pack_key were removed in that migration.)

# Shared PlaneMesh for a level — identical geometry for every page at that level,
# so it's built once and referenced by all (no per-page mesh alloc). Cached.
# M2.6 perf: subdivision DECREASES with level. A coarse (distant) page covers huge
# ground; at the altitude/range it's seen, its vertices are near/sub-pixel, so the
# fine 127x127 grid is wasted triangles (the profiled cost: ~6.5M tris/frame, most
# on coarse pages). Level 0 keeps full detail (you stand on it); each coarser level
# halves the subdivision, floored so the surface still reads smooth at its range.
# This is the standard clipmap density taper — big triangle cut, no visible change.
func _level_plane_mesh(level: int, span: float) -> PlaneMesh:
	if _level_mesh.has(level):
		return _level_mesh[level]
	var plane := PlaneMesh.new()
	plane.size = Vector2(span, span)
	var full: int = mini(page_res - 1, 160)
	# DEM review needs more geometry in coarse rings; otherwise the compact field
	# can be correct but still read as blocky terrain from altitude.
	var lod_level: int = maxi(level - review_mesh_lod_bias, 0)
	var subdiv: int = maxi(full >> lod_level, review_mesh_min_subdiv)
	plane.subdivide_width = subdiv
	plane.subdivide_depth = subdiv
	_level_mesh[level] = plane
	return plane

# Build OR RECYCLE a page instance. Recycling (popping a hidden instance off the
# free-list and re-pointing its texture/transform) is what removes the eager-burst
# alloc spike measured in M1.9.2 — steady state and bursts allocate nothing.
func _make_page_instance(tex, level: int, gx: int, gz: int, span: float) -> MeshInstance3D:
	var _t := Time.get_ticks_usec()
	var mi: MeshInstance3D
	var mat: ShaderMaterial
	if _free_instances.is_empty():
		mi = MeshInstance3D.new()
		mat = ShaderMaterial.new()
		mat.shader = _ring_shader
		mat.set_shader_parameter("page_world_size", span)   # set once per material
		mat.set_shader_parameter("height_scale", 1.0)
		mat.set_shader_parameter("height_lo", -650.0)
		mat.set_shader_parameter("height_hi", 1150.0)
		mat.set_shader_parameter("terrain_palette", 1)
		mi.material_override = mat
		add_child(mi)
	else:
		mi = _free_instances.pop_back()
		mat = mi.material_override
		mi.visible = true

	mi.mesh = _level_plane_mesh(level, span)                # shared per-level geometry
	mat.set_shader_parameter("height_tex", tex)
	# M2.1: bind this page's climate texture (RG32F, same production as height_tex)
	# so the climate view modes can tint by it. Resident here (we just produced or
	# cache-hit the page), so the getter returns the matching texture.
	mat.set_shader_parameter("climate_tex", _pool.get_page_climate_tex(level, gx, gz))
	# M2.2: bind this page's biome-id texture (R32F) for the biome view mode.
	mat.set_shader_parameter("biome_tex", _pool.get_page_biome_tex(level, gx, gz))
	# M2.4: bind this page's analytic normal texture (RG32F: R=normal_x, G=normal_z),
	# same production as height. The display shader reads it for a seam-free normal
	# instead of finite-differencing the height texture (which clamped at page edges
	# and created the per-chunk shading seam).
	mat.set_shader_parameter("normal_tex", _pool.get_page_normal_tex(level, gx, gz))
	mat.set_shader_parameter("view_mode", _view_mode)       # current mode (recycled mats too)
	mat.set_shader_parameter("page_world_size", span)       # span differs by level on reuse
	mat.set_shader_parameter("cell_spacing", spacing * pow(2.0, level))
	mat.set_shader_parameter("page_tint",
		(1.0 if (gx + gz) % 2 == 0 else 0.82) if show_page_tint else 1.0)
	mi.position = Vector3(gx * span + span * 0.5, 0.0, gz * span + span * 0.5)
	# Custom AABB: the mesh is a FLAT plane displaced in the VERTEX SHADER, so Godot
	# can't auto-compute the displaced bounds — we must declare them or frustum
	# culling uses the flat (y~0) box and CULLS the page when you look up/tilt,
	# making terrain vanish at certain angles. The vertical extent MUST cover the
	# real composed height range (M2.3 reaches ~+1.9km peaks / ~-1km valleys, far
	# beyond the old +/-amplitude=240). Use a generous fixed band; an oversized AABB
	# only costs a touch of over-draw, never a wrong cull. (Was: -amplitude..3*amplitude.)
	mi.custom_aabb = AABB(Vector3(-span, -AABB_HALF_HEIGHT, -span),
		Vector3(2.0 * span, 2.0 * AABB_HALF_HEIGHT, 2.0 * span))
	_mesh_us_accum += Time.get_ticks_usec() - _t            # M1.9 profiling: per-frame mesh-build cost
	return mi

# Return an evicted instance to the free-list instead of freeing it (no churn):
# hide it and keep it parented for reuse next time a page spawns.
# M2.6: the render textures are GPU-resident Texture2DRDs the pool FREES when the
# page evicts (right after this, same frame). So we MUST drop this material's
# references to them now — otherwise the hidden material still points at a freed
# RD texture and the renderer logs "invalid texture" every frame. Null the texture
# params (the material is re-pointed to fresh textures on reuse in _make_page_instance).
func _recycle_instance(mi: MeshInstance3D) -> void:
	mi.visible = false
	var mat: ShaderMaterial = mi.material_override
	if mat != null:
		mat.set_shader_parameter("height_tex", null)
		mat.set_shader_parameter("climate_tex", null)
		mat.set_shader_parameter("biome_tex", null)
		mat.set_shader_parameter("normal_tex", null)
	_free_instances.push_back(mi)

func _spawn_camera() -> void:
	var span: float = _pool.page_span()
	# Outer reach of the coarsest level (where the loaded world ends).
	var reach: float = ring_radius * span * pow(2.0, num_levels - 1)
	var terrain_y := amplitude * 1.2
	var cam := Camera3D.new()
	cam.far = reach * 0.95                      # just past fog_depth_end (0.92): nothing renders in clear air beyond the haze wall, so the streaming frontier is never visible (was 1.3 -> a ~48km clear band past the fog re-exposed the frontier as pop-in)
	cam.set_script(load(FLY))
	add_child(cam)
	cam.global_position = REVIEW_START
	cam.look_at(REVIEW_LOOK_AT, Vector3.UP)
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
	# Distance fog matched to the loaded extent: the coarsest streaming FRONTIER is
	# buried in solid haze so new pages resolve UNSEEN (no pop-in), and the loaded
	# boundary is never a visible hard line (WG10 lesson: match fog/far to extent).
	#
	# ROOT CAUSE FIX (2026-06-07): depth fog amount in Godot 4.3+ is
	#   fog_amount = pow(smoothstep(begin,end,dist), curve) * fog_density
	# (engine shader: drivers/.../scene.glsl). The old `fog_density = 0.0` meant
	# fog_amount == 0 ALWAYS -> there was NO fog and ALL the begin/end tuning this
	# prototype tried (0.85->1.0 etc.) was inert; the frontier appeared in clear air
	# ("even if I go slow there's pop-in"). fog_density is the ON switch. Coupled:
	#  - fog_depth_begin 0.55*reach: near/mid terrain stays crisp (far clear view).
	#  - fog_depth_end 0.92*reach: fully opaque BEFORE the coarsest frontier at reach,
	#    so the frontier (and its ~1-coarse-cell jitter) sits inside the haze wall.
	#  - cam.far 0.95*reach (set above): no geometry renders past the wall.
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_DEPTH
	e.fog_light_color = Color(0.62, 0.70, 0.80)  # match sky so it reads as haze->horizon
	e.fog_depth_begin = reach * 0.55
	e.fog_depth_end = reach * 0.92
	e.fog_density = 1.0                          # ON switch: max obscuration at fog_depth_end
	env.environment = e
	add_child(env)
