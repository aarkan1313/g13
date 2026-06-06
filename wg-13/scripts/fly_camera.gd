extends Camera3D
# Reusable free-fly inspection camera for WG13 review scenes.
# WASD = move, Q/E = down/up, right-mouse drag (or just move mouse) = look,
# Shift = boost, mouse wheel = adjust speed. This is the standard rig so every
# visual gate is "launch the project and fly" — no scene wiring needed.

@export var speed: float = 600.0          # world units/sec (terrain is ~km-scale)
@export var boost_mult: float = 4.0
@export var look_sensitivity: float = 0.0025

var _yaw := 0.0
var _pitch := 0.0
var _captured := false

func _ready() -> void:
	# Seed yaw/pitch from the starting orientation so look doesn't snap.
	var e := global_transform.basis.get_euler()
	_pitch = e.x
	_yaw = e.y

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_captured = event.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _captured else Input.MOUSE_MODE_VISIBLE
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed *= 1.15
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed /= 1.15
	elif event is InputEventMouseMotion and _captured:
		_yaw -= event.relative.x * look_sensitivity
		_pitch = clamp(_pitch - event.relative.y * look_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)

func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir -= transform.basis.z
	if Input.is_key_pressed(KEY_S): dir += transform.basis.z
	if Input.is_key_pressed(KEY_A): dir -= transform.basis.x
	if Input.is_key_pressed(KEY_D): dir += transform.basis.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir -= Vector3.UP
	var s := speed * (boost_mult if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	if dir != Vector3.ZERO:
		global_position += dir.normalized() * s * delta
