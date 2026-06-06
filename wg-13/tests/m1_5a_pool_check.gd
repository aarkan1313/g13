extends SceneTree
# M1.5a gate — PagePool caches and bounds production.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_5a_pool_check.gd

const SHADER := "res://shaders/field_height.glsl"
var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	var pool = ClassDB.instantiate("PagePool")
	if pool == null: _fail("PagePool not registered"); _finish(); return
	if not pool.initialize(SHADER): _fail("initialize failed (need vulkan)"); _finish(); return
	# page_res, spacing, seed, octaves, base_freq, amplitude, max_new_per_frame
	pool.configure(128, 4.0, 1234.0, 5, 0.0015, 240.0, 4)

	# --- 1. caching: requesting the same page twice produces once ---
	pool.begin_frame()
	var a = pool.request_page(0, 0, 0)
	pool.begin_frame()                       # new frame so budget isn't the limiter
	var b = pool.request_page(0, 0, 0)       # same key -> must be a cache hit
	if a == null or b == null:
		_fail("request_page returned null for an affordable page")
	elif pool.total_produced() != 1:
		_fail("caching: expected 1 production for repeated key, got %d" % pool.total_produced())
	elif pool.cache_hits() < 1:
		_fail("caching: expected >=1 cache hit, got %d" % pool.cache_hits())
	else:
		print("PASS: caching — repeated key produced once, served from cache (%d hits)" % pool.cache_hits())

	# --- 2. bounded production: at most max_new_per_frame new pages per frame ---
	pool.begin_frame()
	var made := 0
	for i in range(10):                      # ask for 10 distinct NEW pages in one frame
		var t = pool.request_page(0, 100 + i, 0)   # high coords -> not yet cached
		if t != null: made += 1
	if pool.produced_this_frame() > 4:
		_fail("bound: produced %d this frame, exceeds max 4" % pool.produced_this_frame())
	elif made > 4:
		_fail("bound: served %d new pages this frame, exceeds max 4" % made)
	else:
		print("PASS: bounded — requested 10 new pages, produced only %d this frame (cap 4)" % pool.produced_this_frame())

	# --- 3. budget resets next frame ---
	pool.begin_frame()
	var t2 = pool.request_page(0, 200, 0)
	if t2 == null:
		_fail("budget did not reset next frame")
	else:
		print("PASS: budget resets — new frame can produce again")

	# --- 4. residency reflects what was produced ---
	print("INFO: resident=%d total_produced=%d hits=%d" % [
		pool.resident_count(), pool.total_produced(), pool.cache_hits()])

	_finish()

func _finish() -> void:
	print("M1.5a RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
