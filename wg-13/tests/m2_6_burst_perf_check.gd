extends SceneTree
# M2.6 gate — BURST streaming frame time (what the steady-state m1_6 gate misses).
# Drives DETERMINISTIC turbo motion + periodic big jumps to fresh regions so many
# pages are produced in single frames (the felt hitch). Repeats the burst REPEATS
# times and reports the aggregate worst sustained frame, so it's stable enough to
# A/B a perf change (single runs were too noisy). Uses a FIXED per-frame step (not
# dt) so timing variance doesn't move WHERE we sample.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_6_burst_perf_check.gd

const VIEW := preload("res://scripts/world_view.gd")
const WARMUP := 120
const MEASURE := 240
const REPEATS := 3
const TURBO_STEP := 250.0     # world units/frame (~15000 u/s @ 60) -> heavy bursts
const JUMP_EVERY := 40
const JUMP_DIST := 8000.0
const BUDGET_MS := 16.6

var _root: Node3D
var _f := 0
var _rep := 0
var _jumps := 0
var _all_samples := []        # frame times across ALL repeats
var _rep_maxes := []          # worst frame per repeat
var _cur := []

func _init() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_root = Node3D.new()
	_root.set_script(VIEW)
	get_root().add_child(_root)

func _process(_dt: float) -> bool:
	_f += 1
	var cam := get_root().get_viewport().get_camera_3d()
	if _f <= WARMUP:
		return false
	if cam:
		cam.global_position += Vector3(TURBO_STEP, 0.0, -TURBO_STEP)
		if _f % JUMP_EVERY == 0:
			_jumps += 1
			cam.global_position += Vector3(JUMP_DIST * float(_jumps), 0.0, JUMP_DIST * 0.5 * float(_jumps))
	var ms := _dt * 1000.0
	_cur.append(ms)
	_all_samples.append(ms)
	if _cur.size() >= MEASURE:
		_cur.sort()
		_rep_maxes.append(_cur[_cur.size() - 1])
		_cur = []
		_rep += 1
		_f = WARMUP        # re-warm between repeats (keep streaming, reset counter window)
		if _rep >= REPEATS:
			_report()
			return true
	return false

func _report() -> void:
	_all_samples.sort()
	var n := _all_samples.size()
	var p999: float = _all_samples[mini(int(n * 0.999), n - 1)]
	var p99: float = _all_samples[mini(int(n * 0.99), n - 1)]
	var p50: float = _all_samples[n / 2]
	# Stable worst metric: MEDIAN of the per-repeat maxes (robust to one unlucky run).
	_rep_maxes.sort()
	var med_max: float = _rep_maxes[_rep_maxes.size() / 2]
	var over := 0
	for s in _all_samples:
		if s > BUDGET_MS: over += 1
	print("M2.6 BURST perf, %d repeats x %d frames:" % [REPEATS, MEASURE])
	print("  median %.2f | p99 %.2f | p99.9 %.2f ms | median-of-maxes %.2f ms | frames>16.6: %d/%d" % [
		p50, p99, p999, med_max, over, n])
	# This gate is a MEASURING STICK + regression guard, not a hard pass/fail on an
	# absolute number yet (the M2.6 stages drive med_max down). Fail only on a gross
	# regression so it can run in the suite without false alarms; the real bar is the
	# stage-over-stage improvement recorded in the plan + the human feel-check.
	var GROSS := 60.0
	if med_max > GROSS:
		print("FAIL: median-of-maxes %.2f ms exceeds gross-regression guard %.1f ms" % [med_max, GROSS])
		quit(1)
	else:
		print("PASS: burst measured (median-of-maxes %.2f ms); compare across M2.6 stages" % med_max)
		quit(0)
