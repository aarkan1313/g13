extends SceneTree
# M1.6 gate — STEADY-STATE frame time under budget while flying across many page
# loads, MEASURED via true per-frame delta (01_TOOLCHAIN §6). Note: the initial
# multi-level fill is a one-time startup transient (see startup-hitch handling in
# world_view); this gate measures steady-state flight, which is what "60 FPS, no
# stutter on movement" means. vsync off so we see true cost, not the display cap.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_6_frametime_check.gd

const VIEW := preload("res://scripts/world_view.gd")
const WARMUP := 200         # let the 6-level rings fully fill (past the startup transient)
const MEASURE := 240        # frames measured while flying
const FLY_SPEED := 900.0    # fast -> constant new-page streaming during measurement
const BUDGET_MS := 16.6     # 60 FPS

var _root: Node3D
var _f := 0
var _samples := []
var _failed := false

func _init() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_root = Node3D.new()
	_root.set_script(VIEW)
	get_root().add_child(_root)

func _process(dt: float) -> bool:
	_f += 1
	var cam := get_root().get_viewport().get_camera_3d()
	if _f <= WARMUP:
		return false
	if cam:
		cam.global_position += Vector3(FLY_SPEED, 0, -FLY_SPEED).normalized() * FLY_SPEED * dt
	_samples.append(dt * 1000.0)   # true per-frame wall time
	if _samples.size() < MEASURE:
		return false
	_report()
	return true

func _report() -> void:
	_samples.sort()
	var n := _samples.size()
	var maxv: float = _samples[n - 1]
	var p99: float = _samples[mini(int(n * 0.99), n - 1)]
	var p50: float = _samples[n / 2]
	var avg := 0.0
	for s in _samples: avg += s
	avg /= n

	print("M1.6 steady-state frame time, %d frames @ %.0f u/s, %d levels:" % [n, FLY_SPEED, _root.get("num_levels")])
	print("  median %.2f ms (%.0f fps) | avg %.2f | p99 %.2f | max %.2f (budget %.1f)" % [
		p50, 1000.0 / p50, avg, p99, maxv, BUDGET_MS])

	if p99 > BUDGET_MS:
		_failed = true
		print("FAIL: p99 %.2f ms exceeds budget %.1f ms" % [p99, BUDGET_MS])
	else:
		print("PASS: p99 %.2f ms within budget %.1f ms (steady-state holds 60 FPS while streaming)" % [p99, BUDGET_MS])

	print("M1.6 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
