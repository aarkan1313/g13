extends SceneTree
# M2.6 Stage 3 gate — render textures are GPU-resident RD textures (Texture2DRD),
# which are NOT ref-counted: the pool MUST free their RIDs on evict or VRAM leaks
# unbounded as you fly. This streams a large area (many produce+evict cycles) and
# asserts the resident page count returns to a bounded steady state (eviction is
# actually reclaiming pages, not accumulating). Pairs with the engine's own
# "RIDs leaked" report at exit (should be ~0 render textures with free-on-evict).
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_6_vram_check.gd

const VIEW := preload("res://scripts/world_view.gd")
const WARMUP := 60
const STEP := 600.0       # move far each frame -> constant new pages + evictions
const FRAMES := 400

var _root: Node3D
var _f := 0
var _peak_resident := 0

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
		cam.global_position += Vector3(STEP, 0.0, STEP)
	var resident: int = _root._pool.resident_count()
	_peak_resident = maxi(_peak_resident, resident)
	if _f - WARMUP >= FRAMES:
		_report()
		return true
	return false

func _report() -> void:
	var resident: int = _root._pool.resident_count()
	var produced: int = _root._pool.total_produced()
	var evicted: int = _root._pool.evicted_count()
	print("M2.6 VRAM/eviction, %d frames flying:" % FRAMES)
	print("  produced=%d  evicted=%d  resident now=%d  peak resident=%d" % [
		produced, evicted, resident, _peak_resident])
	# With free-on-evict working: we produced FAR more pages than are resident (lots
	# of eviction happened), and resident stays bounded near the ring footprint (it
	# does NOT grow ~= produced). A leak would show resident climbing with produced.
	var bounded_ok := resident < produced / 2 and evicted > produced / 4
	if not bounded_ok:
		print("FAIL: eviction not reclaiming — resident %d vs produced %d, evicted %d (leak suspected)" % [
			resident, produced, evicted])
		quit(1)
	else:
		print("PASS: eviction reclaims pages — resident %d bounded << produced %d (evicted %d)" % [
			resident, produced, evicted])
		print("  (Check the engine's 'RIDs of type Texture leaked' line at exit: render")
		print("   textures should NOT accumulate ~= produced with free-on-evict.)")
		quit(0)
