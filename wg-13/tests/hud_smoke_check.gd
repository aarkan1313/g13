extends SceneTree
# Smoke check (not a milestone gate) — the perf HUD loads in demo.tscn, finds the
# view, and produces sane diagnostic text without touching the engine side.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/hud_smoke_check.gd

const DEMO := "res://scenes/demo.tscn"
var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	var rootn: Node = load(DEMO).instantiate()
	root.add_child(rootn)
	for _i in range(30): await process_frame

	var hud: CanvasLayer = rootn.get_node("PerfHUD")
	if hud == null: _fail("PerfHUD node missing from demo.tscn"); _finish(rootn); return

	# 1. HUD found the view.
	if hud._view == null:
		_fail("HUD did not find the world_view sibling")
	else:
		print("PASS: HUD found the view")

	# 2. text builds and contains all enabled sections with sane numbers.
	var txt: String = hud._build_text(8.0)   # 8ms -> 125fps sample
	print("HUD TEXT:\n", txt)
	if not ("fps" in txt and "ms" in txt):
		_fail("frame row missing")
	elif not ("pages" in txt):
		_fail("streaming row missing (view/pool not read)")
	elif not ("xz" in txt and "page" in txt):
		_fail("position row missing")
	elif not ("mem" in txt and "vram" in txt):
		_fail("memory row missing")
	elif not ("prod" in txt and "view" in txt and "mesh" in txt):
		_fail("profiler row missing (per-system frame breakdown)")
	else:
		print("PASS: all HUD sections present (frame/streaming/profiler/position/memory)")

	# profiler getters are wired (pool produce_us + view prof_*).
	if not hud._view._pool.has_method("produce_us_this_frame"):
		_fail("pool missing produce_us_this_frame() getter")
	elif not ("prof_process_us" in hud._view):
		_fail("view missing prof_process_us")
	else:
		print("PASS: profiler instrumentation wired (pool produce_us + view prof_*)")

	# 3. page count in the text matches the pool (not a fabricated number).
	var pool = hud._view._pool
	if not ("pages %d" % pool.resident_count()) in txt:
		_fail("HUD page count does not match pool.resident_count()=%d" % pool.resident_count())
	else:
		print("PASS: HUD streaming count matches the pool (%d pages)" % pool.resident_count())

	# 4. toggling a section removes it from the text.
	hud.show_streaming = false
	var txt2: String = hud._build_text(8.0)
	if "pages" in txt2:
		_fail("toggling show_streaming off did not remove the streaming row")
	else:
		print("PASS: section toggle works (streaming row removed when off)")

	_finish(rootn)

func _finish(rootn) -> void:
	if rootn != null: rootn.queue_free()
	print("HUD SMOKE RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
