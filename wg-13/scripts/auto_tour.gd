extends Node
# DEMO dev tool — data-driven auto-tour that flies/walks the scene hands-free so
# you can watch for visual issues. MODULAR by design: the tour is a list of step
# dicts (data, not code); to change what it does, edit the rows. Each "action"
# is a small reusable function below; add a move = add a function + a row.
#
# It DRIVES THE EXISTING RIGS — it moves world_view's fly-camera and triggers the
# player's walk mode (via auto_move), so there's no parallel mover to maintain.
#
# Control: T toggles the tour. Toggling off (or any WASD/mouse input) PAUSES and
# hands you the normal fly/walk controls from the current spot; T again RESUMES
# from the same step. Starts OFF (press T to begin) so a normal launch is clean.

@export var enabled := false                 # start state; T flips it
@export var loop := true                     # restart the step list at the end
@export var idle_resume := false             # (off) auto-resume after manual idle — pause-only by default

# The tour. Each step: {action, ...params, secs}. Edit/reorder these rows to
# change the tour. Speeds are world units/sec; secs is the step duration.
@export var tour: Array = [
	{"action": "fly_forward", "speed": 600.0,  "secs": 8.0},   # cruise
	{"action": "boost",       "speed": 2400.0, "secs": 6.0},   # outrun streamer -> show never-black
	{"action": "slow_pan",    "speed": 120.0,  "secs": 6.0},   # slow -> show detail / any seams
	{"action": "ascend",      "speed": 500.0,  "secs": 4.0},   # rise -> show horizon / far LOD
	{"action": "descend",     "speed": 500.0,  "secs": 4.0},   # drop toward the surface
	{"action": "orbit",       "speed": 0.6,    "radius": 500.0, "secs": 12.0},  # circle a spot, all angles
	{"action": "reverse",     "speed": 600.0,  "secs": 6.0},   # back up
	{"action": "walk_drop",   "speed": 1.0,    "secs": 10.0},  # G-drop + auto-walk -> show collision
]

var _view: Node3D
var _player: CharacterBody3D
var _fly: Camera3D
var _idx := 0
var _t := 0.0                                # time spent in current step
var _orbit_centre := Vector3.ZERO
var _orbit_angle := 0.0
var _active := false                         # currently driving (enabled AND not manually paused)

func _ready() -> void:
	call_deferred("_link")

func _link() -> void:
	var parent := get_parent()
	for sib in parent.get_children():
		if sib.has_method("page_span_value"):
			_view = sib
		elif sib is CharacterBody3D and "auto_move" in sib:
			_player = sib
	if _view != null:
		_fly = _view._cam
	if enabled:
		_start()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		if _active: _stop("toggle")
		else: _start()
		return
	# Any movement input pauses the tour and hands over control.
	if _active and _is_manual_input(event):
		_stop("manual input")

func _is_manual_input(event: InputEvent) -> bool:
	# Only deliberate MOVEMENT counts as "take control". Looking around does NOT:
	# passive mouse motion AND left-click-drag (the look/aim control) are allowed
	# while the tour drives, so you can inspect the view hands-free without pausing.
	# Mouse wheel (speed adjust) is also allowed. Taking over = a movement key.
	if event is InputEventKey and event.pressed and not event.echo:
		return event.keycode in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_SPACE, KEY_C,
			KEY_E, KEY_Q, KEY_SHIFT, KEY_F, KEY_G]
	return false

func _start() -> void:
	if _fly == null:
		return
	_active = true
	enabled = true
	# The tour owns POSITION (disable the fly-cam's _process movement), but LOOK
	# stays live (keep _unhandled_input) so you can left-drag to aim the camera
	# and inspect the view while the tour flies. On orbit steps the tour sets the
	# rotation itself (look-at the centre); on straight steps your look coexists
	# with the tour's translation.
	_fly.set_process(false)
	_fly.make_current()
	print("AUTO-TOUR: ON (step %d/%d). T or any movement key = pause + take control." % [
		_idx + 1, tour.size()])

func _stop(reason: String) -> void:
	_active = false
	# Stop any auto-walk and hand control back.
	if _player != null:
		_player.auto_move = Vector3.ZERO
		if _player._walking:
			_player._enter_fly()
	if _fly != null:
		_fly.set_process(true)
		_fly.set_process_input(true)
		_fly.set_process_unhandled_input(true)
		_fly.make_current()
	print("AUTO-TOUR: PAUSED (%s) at step %d. T to resume." % [reason, _idx + 1])

func _process(delta: float) -> void:
	if not _active or _fly == null or tour.is_empty():
		return
	var step: Dictionary = tour[_idx]
	var secs: float = step.get("secs", 5.0)
	# Run the current action for this frame.
	_run_action(step, delta)
	_t += delta
	if _t >= secs:
		_advance()

func _advance() -> void:
	# Clean up walk steps before leaving them.
	if _player != null and _player._walking and tour[_idx].get("action") != "walk_drop":
		pass
	_t = 0.0
	_idx += 1
	if _idx >= tour.size():
		if loop:
			_idx = 0
		else:
			_stop("tour complete")
			return
	# Entering a non-walk step from a walk step: return to flying.
	if _player != null and _player._walking and tour[_idx].get("action") != "walk_drop":
		_player.auto_move = Vector3.ZERO
		_player._enter_fly()
		_fly.set_process(false); _fly.set_process_input(false); _fly.set_process_unhandled_input(false)
	print("AUTO-TOUR: step %d/%d -> %s" % [_idx + 1, tour.size(), tour[_idx].get("action", "?")])

# --- actions (one small function each; add a move = add one here + a row) -----

func _run_action(step: Dictionary, delta: float) -> void:
	match step.get("action", ""):
		"fly_forward", "boost", "slow_pan":
			_fly_dir(-_fly.global_transform.basis.z, step.get("speed", 600.0), delta)
		"reverse":
			_fly_dir(_fly.global_transform.basis.z, step.get("speed", 600.0), delta)
		"ascend":
			_fly_dir(Vector3.UP, step.get("speed", 500.0), delta)
		"descend":
			_fly_dir(Vector3.DOWN, step.get("speed", 500.0), delta)
		"orbit":
			_orbit(step, delta)
		"walk_drop":
			_walk(step, delta)
		_:
			pass   # unknown action -> hold position (safe)

func _fly_dir(dir: Vector3, speed: float, delta: float) -> void:
	_fly.global_position += dir.normalized() * speed * delta

func _orbit(step: Dictionary, delta: float) -> void:
	var radius: float = step.get("radius", 500.0)
	var ang_speed: float = step.get("speed", 0.6)   # rad/sec
	if _t <= delta:                                  # first frame: pick a centre ahead
		_orbit_centre = _fly.global_position - _fly.global_transform.basis.z.normalized() * radius
		_orbit_angle = 0.0
	_orbit_angle += ang_speed * delta
	var off := Vector3(cos(_orbit_angle), 0.0, sin(_orbit_angle)) * radius
	_fly.global_position = _orbit_centre + Vector3(off.x, _fly.global_position.y - _orbit_centre.y, off.z)
	_fly.look_at(_orbit_centre, Vector3.UP)

func _walk(step: Dictionary, delta: float) -> void:
	if _player == null:
		return
	if not _player._walking:
		_player._enter_walk()                        # drop onto the terrain here
	# Auto-walk forward (local -z) so you see the capsule traverse + hold collision.
	_player.auto_move = Vector3(0.0, 0.0, -1.0)
