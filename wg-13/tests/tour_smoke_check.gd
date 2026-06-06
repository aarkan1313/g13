extends SceneTree
# Smoke check (not a milestone gate) — the auto-tour drives the camera per its
# step data and pauses/resumes correctly, driving the existing fly-cam (not a
# parallel mover). Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/tour_smoke_check.gd

const DEMO := "res://scenes/demo.tscn"
var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	var rootn: Node = load(DEMO).instantiate()
	root.add_child(rootn)
	for _i in range(20): await process_frame

	var tour: Node = rootn.get_node("AutoTour")
	var view: Node3D = rootn.get_node("View")
	if tour == null or view == null: _fail("AutoTour or View missing"); _finish(rootn); return
	if tour._fly == null: _fail("tour did not link the fly camera"); _finish(rootn); return

	# 1. starts OFF (clean launch).
	if tour._active:
		_fail("tour is active on launch (should start OFF until T)")
	else:
		print("PASS: tour starts OFF")

	# 2. starting it MOVES the camera (forward step) — drives the real fly-cam.
	var p0: Vector3 = tour._fly.global_position
	tour._start()
	for _i in range(30): await process_frame   # ~0.5s of step 1 (fly_forward 600)
	var p1: Vector3 = tour._fly.global_position
	var moved: float = p0.distance_to(p1)
	if moved < 50.0:
		_fail("camera barely moved during fly_forward (%.1f m in ~0.5s @ 600/s)" % moved)
	else:
		print("PASS: tour drives the fly-camera (moved %.0f m in ~0.5s)" % moved)

	# 3. it advances through steps over time.
	var start_idx: int = tour._idx
	# fast-forward by faking time: run enough frames to pass step 1's secs (8s).
	# Cheaper: directly drive _process with big deltas would skip physics; instead
	# just assert the step pointer mechanism by forcing _t past the duration.
	tour._t = tour.tour[tour._idx].get("secs", 5.0) + 1.0
	await process_frame
	if tour._idx == start_idx and tour.tour.size() > 1:
		_fail("tour did not advance to the next step after the duration elapsed")
	else:
		print("PASS: tour advances steps (step %d -> %d)" % [start_idx + 1, tour._idx + 1])

	# 4. pausing hands control back: fly-cam process re-enabled, tour inactive.
	tour._stop("test")
	if tour._active:
		_fail("tour still active after stop")
	elif not tour._fly.is_processing():
		_fail("fly-camera input not restored after pause (you couldn't fly)")
	else:
		print("PASS: pause restores manual fly control")

	# 5. resume works.
	tour._start()
	if not tour._active:
		_fail("tour did not resume on second start")
	else:
		print("PASS: resume re-activates the tour")

	_finish(rootn)

func _finish(rootn) -> void:
	if rootn != null: rootn.queue_free()
	print("TOUR SMOKE RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
