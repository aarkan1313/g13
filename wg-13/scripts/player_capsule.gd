extends CharacterBody3D
# M1.7c — a minimal test character to prove the terrain collision (M1.7a/b).
# This is DEMO content, not engine: the engine provides streamed terrain +
# HeightMapShape3D collision; this capsule is just a probe that stands on it.
# Kept generic (no game logic) and self-contained so it drops out cleanly.
#
# Toggle (so you can reach a fresh page, then drop onto it):
#   F = FLY  — hand control back to the world_view's free-fly camera; capsule
#              sleeps (no gravity), so flying is exactly as before.
#   G = WALK — snap the capsule under wherever the fly-camera is looking, switch
#              to the capsule's own camera, enable gravity + WASD. Drop and walk;
#              confirm you stand on the surface, never fall through, including on
#              a page that just streamed in.
#   CapsLock = TURBO toggle (WALK only) — multiply move speed by turbo_mult
#              (default 60x) for fast on-foot traverse. CapsLock again = off.
#              (Shift still stacks as sprint.) Uses the normal move_and_slide
#              physics path — collision behaves as usual, just faster.
#
# The capsule finds the fly-camera via the viewport's current camera at _ready
# (the view makes it current), so it never reaches into world_view internals.

@export var move_speed: float = 12.0
@export var sprint_mult: float = 3.0       # Shift = sprint
@export var turbo_mult: float = 60.0       # CapsLock = TURBO toggle (cover ground fast on foot)
@export var jump_speed: float = 16.0       # Space = jump (initial upward velocity)
@export var gravity: float = 30.0
# Momentum: accelerate toward target velocity instead of snapping (weighty feel).
# Units ~ 1/sec multiplier on speed; ground is snappy, air is light (air control).
@export var accel_ground: float = 8.0
@export var accel_air: float = 1.5
@export var mouse_sensitivity: float = 0.0025
@export var eye_height: float = 4.0        # camera offset above the capsule centre
@export var capsule_height: float = 6.0    # taller capsule (was 2m) — better vantage walking
@export var capsule_radius: float = 0.6
@export var spawn_clearance: float = 3.0   # metres above terrain to drop in (small = no tunneling speed)

var _view: Node3D                           # the world_view (for terrain-height lookup)
var _fly_cam: Camera3D                      # the world_view's free-fly camera
# Auto-drive hook (used by the auto-tour to walk the capsule without faking OS
# input): a LOCAL-space move dir (x = strafe, z = forward/back, -z = forward).
# Zero -> read the keyboard as normal. Set back to ZERO to return to manual.
var auto_move := Vector3.ZERO
var _walk_cam: Camera3D                     # our own camera, used in WALK mode
var _walking := false
var _turbo := false                         # CapsLock toggle: turbo_mult traverse speed (WALK)
var _yaw := 0.0
var _pitch := 0.0
var _captured := false

func _ready() -> void:
	# Body shape.
	var shape := CapsuleShape3D.new()
	shape.height = capsule_height
	shape.radius = capsule_radius
	var col := CollisionShape3D.new()
	col.shape = shape
	add_child(col)

	# Climb ANY slope (just slower on steep grades, handled in _physics_process):
	# treat almost everything as walkable floor instead of an unclimbable wall.
	# Default floor_max_angle (45 deg) makes steep mountain faces act as walls you
	# slide off; raise it so the capsule ascends them.
	floor_max_angle = deg_to_rad(89.0)
	# M2.7 quick-fix: floor_snap was 6m (= capsule_height) — it YANKED the body back
	# to the surface every frame, so cresting a bump at speed never launched into an
	# arc (the "run fast over a bump and just stay at that height, never fall" bug).
	# A SMALL snap (0.3m) still keeps the capsule glued on gentle contiguous ground
	# (no flat-terrain jitter) but can't grab it back down off a crest -> real
	# ballistic arcs / falling. Full character-feel (jump tuning, slope camera) = M2.7.
	floor_snap_length = 0.3
	floor_stop_on_slope = false      # don't freeze on a slope; let movement drive up it

	# Our walk camera (eye-level), inactive until WALK.
	_walk_cam = Camera3D.new()
	_walk_cam.position = Vector3(0.0, eye_height, 0.0)
	_walk_cam.far = 60000.0                 # see the streamed horizon while walking
	add_child(_walk_cam)

	# Start in FLY: the view's free-fly camera stays current (unchanged behaviour).
	# Defer the lookup one frame so the view's _ready has made its camera current.
	call_deferred("_grab_fly_cam")

func _grab_fly_cam() -> void:
	_fly_cam = get_viewport().get_camera_3d()
	# Find the world_view (a sibling) so we can sample resident terrain height.
	for sib in get_parent().get_children():
		if sib != self and sib.has_method("page_terrain_height"):
			_view = sib
			break
	# Park the capsule out of sight until the user enters WALK mode.
	if _fly_cam != null:
		global_position = _fly_cam.global_position - Vector3(0.0, 1000.0, 0.0)

# Resident terrain height at a world XZ, sampled from the SAME pool heights the
# collision uses (returns NAN if that level-0 page isn't resident yet).
func _terrain_height_at(wx: float, wz: float) -> float:
	if _view == null:
		return NAN
	return _view.page_terrain_height(wx, wz)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G and not _walking:
			_enter_walk()
		elif event.keycode == KEY_F and _walking:
			_enter_fly()
		elif event.keycode == KEY_CAPSLOCK and _walking:
			_turbo = not _turbo            # CapsLock = toggle TURBO walk (cover ground fast)
			print("WALK turbo %s (x%.0f)" % ["ON" if _turbo else "OFF", turbo_mult])
	# Mouse-look only in WALK (FLY mode is the view's fly_camera's job).
	# LEFT-mouse drag = look (matches fly_camera.gd's left-click look).
	if _walking:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_captured = event.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _captured else Input.MOUSE_MODE_VISIBLE
		elif event is InputEventMouseMotion and _captured:
			_yaw -= event.relative.x * mouse_sensitivity
			_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
			rotation.y = _yaw
			_walk_cam.rotation.x = _pitch

func _enter_walk() -> void:
	_walking = true
	# Spawn at the terrain you were looking at (the fly-cam's XZ), just ABOVE the
	# resident surface — NOT from the fly-cam's altitude. A small drop means no
	# tunneling speed, and because the height is resident the collision body for
	# that page is present (or lands within a frame), so you can't fall through a
	# fresh page. If the page isn't resident yet, fall back to the fly-cam height.
	if _fly_cam != null:
		var p: Vector3 = _fly_cam.global_position
		var th: float = _terrain_height_at(p.x, p.z)
		var spawn_y: float = (th + spawn_clearance) if not is_nan(th) else p.y
		global_position = Vector3(p.x, spawn_y, p.z)
		_yaw = _fly_cam.global_rotation.y
		rotation.y = _yaw
		# Stop the fly-camera from also reading WASD/Shift while we walk — otherwise
		# both controllers fight over the keyboard (and Shift boosts the invisible
		# fly-cam), which makes live behaviour confusing. One controller at a time.
		_fly_cam.set_process(false)
		_fly_cam.set_process_input(false)
		_fly_cam.set_process_unhandled_input(false)
	# M2.3-fix: stream + build collision around the CAPSULE now, not the frozen
	# fly camera — otherwise walking away from the drop point leaves the collision
	# zone and you fall through.
	if _view != null and _view.has_method("set_track_target"):
		_view.set_track_target(self)
	velocity = Vector3.ZERO
	_walk_cam.make_current()
	print("M1.7c: WALK — capsule active, gravity on. Drop onto the terrain. (F = back to fly)")

func _enter_fly() -> void:
	_walking = false
	_turbo = false                                 # leave WALK turbo off when handing back to fly
	_captured = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# M2.3-fix: stream + collide around the fly camera again.
	if _view != null and _view.has_method("set_track_target"):
		_view.set_track_target(_fly_cam)
	if _fly_cam != null:
		_fly_cam.set_process(true)                 # hand input back to the fly-camera
		_fly_cam.set_process_input(true)
		_fly_cam.set_process_unhandled_input(true)
		_fly_cam.make_current()
	print("M1.7c: FLY — free-fly camera. (G = drop the capsule and walk)")

func _physics_process(delta: float) -> void:
	if not _walking:
		return
	var grounded := is_on_floor()

	# --- VERTICAL: gravity + jump (momentum-preserving) ---
	if grounded:
		if velocity.y < 0.0:
			velocity.y = 0.0                       # just landed: stop downward, keep horizontal momentum
		if Input.is_key_pressed(KEY_SPACE):
			velocity.y = jump_speed                # jump; horizontal velocity carries over (real arc)
	else:
		velocity.y -= gravity * delta             # fall with accelerating velocity

	# --- HORIZONTAL: accelerate toward a target velocity (MOMENTUM, not snap) ---
	# Move dir: the auto-tour's auto_move if set, else WASD (relative to facing).
	var input := auto_move
	if input == Vector3.ZERO:
		if Input.is_key_pressed(KEY_W): input.z -= 1.0
		if Input.is_key_pressed(KEY_S): input.z += 1.0
		if Input.is_key_pressed(KEY_A): input.x -= 1.0
		if Input.is_key_pressed(KEY_D): input.x += 1.0
	var dir := (transform.basis * Vector3(input.x, 0.0, input.z))
	dir.y = 0.0
	if dir.length() > 0.0:
		dir = dir.normalized()

	var spd: float = move_speed * (sprint_mult if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	if _turbo: spd *= turbo_mult
	# GRADE-BASED SPEED: all slopes climbable, just slower the steeper (never zero,
	# never a wall). Gentle: only bites on genuinely steep ground, floor of 0.45.
	if grounded:
		spd *= clampf(get_floor_normal().y, 0.45, 1.0)

	var target := Vector3(dir.x * spd, 0.0, dir.z * spd)
	var cur_h := Vector3(velocity.x, 0.0, velocity.z)
	# Accelerate/decelerate toward target. Snappy on the ground, lighter in the air
	# (air control) so jumps/falls keep momentum and feel weighty. Rates scale with
	# speed so turbo still reaches top speed quickly.
	var accel: float = (accel_ground if grounded else accel_air) * maxf(spd, move_speed)
	cur_h = cur_h.move_toward(target, accel * delta)
	velocity.x = cur_h.x
	velocity.z = cur_h.z

	# SUBSTEPPED MOVE (anti-tunneling). One move_and_slide advances velocity*delta in
	# a SINGLE swept test; at turbo (~36 m/frame) that skips over terrain and tunnels
	# (proven: every CLIP was turbo, hspeed=2160; normal/sprint never clipped). Split
	# the frame's motion into N substeps each <= half the capsule radius, so the swept
	# body always overlaps terrain between substeps. Keeps the proven move_and_slide
	# path (floor snap, is_on_floor(), m1_7c gate); calls it N times at 1/N velocity
	# so total distance is unchanged. N=1 at normal speed (no cost). One body -> cheap.
	var frame_dist: float = velocity.length() * delta
	var max_step: float = max(capsule_radius * 0.5, 0.05)
	var substeps: int = clampi(int(ceil(frame_dist / max_step)), 1, 64)
	if substeps <= 1:
		move_and_slide()
	else:
		var keep_v := velocity
		velocity = velocity / float(substeps)
		for _s in range(substeps):
			move_and_slide()
		# Keep move_and_slide's resolved vertical (landing/slope), restore horizontal.
		velocity.x = keep_v.x
		velocity.z = keep_v.z

