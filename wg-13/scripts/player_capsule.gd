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
#
# The capsule finds the fly-camera via the viewport's current camera at _ready
# (the view makes it current), so it never reaches into world_view internals.

@export var move_speed: float = 12.0
@export var sprint_mult: float = 3.0       # Shift = sprint
@export var jump_speed: float = 12.0       # Space = jump (initial upward velocity)
@export var gravity: float = 30.0
@export var mouse_sensitivity: float = 0.0025
@export var eye_height: float = 1.6        # camera offset above the capsule centre
@export var capsule_height: float = 2.0
@export var capsule_radius: float = 0.4
@export var spawn_clearance: float = 3.0   # metres above terrain to drop in (small = no tunneling speed)

var _view: Node3D                           # the world_view (for terrain-height lookup)
var _fly_cam: Camera3D                      # the world_view's free-fly camera
var _walk_cam: Camera3D                     # our own camera, used in WALK mode
var _walking := false
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
	# Mouse-look only in WALK (FLY mode is the view's fly_camera's job).
	if _walking:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
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
	velocity = Vector3.ZERO
	_walk_cam.make_current()
	print("M1.7c: WALK — capsule active, gravity on. Drop onto the terrain. (F = back to fly)")

func _enter_fly() -> void:
	_walking = false
	_captured = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _fly_cam != null:
		_fly_cam.set_process(true)                 # hand input back to the fly-camera
		_fly_cam.set_process_input(true)
		_fly_cam.set_process_unhandled_input(true)
		_fly_cam.make_current()
	print("M1.7c: FLY — free-fly camera. (G = drop the capsule and walk)")

func _physics_process(delta: float) -> void:
	if not _walking:
		return
	# Gravity + ground + jump.
	if is_on_floor():
		velocity.y = 0.0
		if Input.is_key_pressed(KEY_SPACE):       # Space = jump (only from the ground)
			velocity.y = jump_speed
	else:
		velocity.y -= gravity * delta
	# WASD relative to facing (yaw only); Shift = sprint.
	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): input.z -= 1.0
	if Input.is_key_pressed(KEY_S): input.z += 1.0
	if Input.is_key_pressed(KEY_A): input.x -= 1.0
	if Input.is_key_pressed(KEY_D): input.x += 1.0
	var dir := (transform.basis * Vector3(input.x, 0.0, input.z))
	dir.y = 0.0
	if dir.length() > 0.0:
		dir = dir.normalized()
	var spd: float = move_speed * (sprint_mult if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	velocity.x = dir.x * spd
	velocity.z = dir.z * spd
	move_and_slide()
