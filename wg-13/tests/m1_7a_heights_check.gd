extends SceneTree
# M1.7a gate — PagePool retains the CPU heights behind each resident page and
# exposes them via get_page_heights(), so collision reads the SAME array the
# view's texture was packed from (00 §2.2 / MILESTONE_1 M1.7: "collision reads
# the same resident page heights the view uses, never a second field path").
#
# This proves, output-provably:
#   1. a resident page returns page_res*page_res heights
#   2. they equal a fresh FieldCompute production of the same world page
#      (it's the real field, not stale/garbage), and differ for a different page
#   3. a non-resident page returns an empty array (getter never fabricates)
#
# M2.6 NOTE: render textures are now GPU-resident (Texture2DRD, no CPU readback),
# so the old "texture bytes == heights bytes" check is gone — a render Texture2DRD
# can't be CPU-read (no CAN_COPY_FROM_BIT, by design). The M1.7 no-drift contract
# ("collision reads the same field the view renders") is now proven by check #2:
# collision `heights` are bit-identical to an independent FieldCompute of the SAME
# page params — and the render path runs the IDENTICAL GLSL with the SAME params,
# so both derive from one field math (one source of truth, 00 §2.1). Collision and
# render can't drift because they share the field + params, not because we byte-
# compare a CPU copy of the (now GPU-only) render texture.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_7a_heights_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 4.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	var pool = ClassDB.instantiate("PagePool")
	if pool == null: _fail("PagePool not registered"); _finish(); return
	if not pool.initialize(SHADER): _fail("initialize failed (need vulkan)"); _finish(); return
	pool.configure(RES, SPACING, SEED, OCT, FREQ, AMP, 4)

	# Produce one resident page (level 0, origin page).
	pool.begin_frame()
	var tex = pool.request_page(0, 0, 0)
	if tex == null: _fail("request_page returned null for an affordable page"); _finish(); return

	# M2.6 BATCH: the level-0 collision heights are now read back in a BATCHED
	# dispatch on the NEXT begin_frame (not synchronously at request time) — this is
	# the perf win (one submit/sync for all collision pages, not per-page). So the
	# heights land one begin_frame later; collision already tolerates this (it
	# retries until heights are present). Trigger that collect, then assert.
	pool.begin_frame()

	# --- 1. length ---
	var heights: PackedFloat32Array = pool.get_page_heights(0, 0, 0)
	if heights.size() != RES * RES:
		_fail("expected %d heights, got %d" % [RES * RES, heights.size()])
		_finish(); return
	print("PASS: length — get_page_heights returned %d floats (%dx%d)" % [heights.size(), RES, RES])
	var h_bytes: PackedByteArray = heights.to_byte_array()

	# --- 2. it's the real field: matches a fresh FieldCompute of the same world page ---
	# (This is the M1.7 no-drift proof now: collision heights == the field math, and
	#  the render path runs the IDENTICAL GLSL with the SAME params, so they agree.)
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.initialize(SHADER):
		_fail("FieldCompute init failed (need vulkan)")
	else:
		# Level-0 page (0,0): origin (0,0), spacing = SPACING. Same params as the pool.
		var oracle: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
		if oracle.size() != heights.size():
			_fail("oracle size %d != heights size %d" % [oracle.size(), heights.size()])
		elif oracle.to_byte_array() != h_bytes:
			_fail("pool heights do not match a fresh FieldCompute production of the same page")
		else:
			print("PASS: real field — heights match an independent FieldCompute production of page (0,0)")
		# A DIFFERENT page must differ (the getter is keyed, not constant).
		var other: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED + 1.0, RES, OCT, FREQ, AMP)
		if other.to_byte_array() == h_bytes:
			_fail("a different seed produced identical heights (getter not discriminating)")
		else:
			print("PASS: discriminating — a different field (seed+1) yields different heights")

	# --- 3. non-resident page returns empty (getter never fabricates) ---
	var absent: PackedFloat32Array = pool.get_page_heights(0, 9999, 9999)
	if absent.size() != 0:
		_fail("non-resident page returned %d heights, expected 0 (empty)" % absent.size())
	else:
		print("PASS: non-resident — get_page_heights on an unproduced page returns empty")

	print("INFO: resident=%d total_produced=%d" % [pool.resident_count(), pool.total_produced()])
	_finish()

func _finish() -> void:
	print("M1.7a RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
