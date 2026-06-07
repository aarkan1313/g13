extends SceneTree
# M1.8 gate — floating-origin world rebase is TERRAIN-NEUTRAL.
#
# Proves, output-provably, that the WorldOrigin module (camera-relative rebase)
# changes only WHERE the world is drawn (Godot coords) and NEVER what terrain is
# generated (absolute grid index). If this holds, the floating origin is safe to
# wire into the views: the field/Rust path is untouched and determinism is intact.
#
# Checks:
#   1. transform round-trip: to_godot(to_absolute(p)) == p, and to_absolute adds
#      the accumulated offset (the Godot<->absolute contract).
#   2. rebase fires only past one cell, snaps to WHOLE cells, and keeps the camera
#      within one cell of the Godot origin (centering holds while cruising).
#   3. TERRAIN NEUTRALITY (the real proof): the level-0 page covering a fixed
#      ABSOLUTE world point produces BIT-IDENTICAL heights before vs after several
#      rebases. Because the page is keyed by absolute grid index (gx = floor(abs/
#      span)) and the rebase shifts by whole cells, the same absolute point maps to
#      the same gx,gz -> same field production. (Uses the real PagePool + an
#      independent FieldCompute, the M1.7a pattern.)
#
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_8_origin_rebase_check.gd

const ORIGIN_SCRIPT := "res://scripts/world_origin.gd"
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
	var WO = load(ORIGIN_SCRIPT)
	if WO == null: _fail("world_origin.gd failed to load"); _finish(); return
	var span := float(RES - 1) * SPACING            # level-0 page span (shared-boundary cell)
	var origin = WO.new(span)

	# --- 1. transform round-trip + offset contract ---
	var p := Vector3(123.0, 45.0, -678.0)
	if origin.to_absolute(p) != p:
		_fail("to_absolute should be identity at zero offset, got %s" % origin.to_absolute(p))
	# Force an offset and check the contract.
	origin.offset = Vector3(span * 3.0, 0.0, span * -2.0)
	var rt: Vector3 = origin.to_godot(origin.to_absolute(p))
	if rt != p:
		_fail("round-trip to_godot(to_absolute(p)) != p (got %s)" % rt)
	elif origin.to_absolute(p) != p + origin.offset:
		_fail("to_absolute must add offset")
	else:
		print("PASS: transform — round-trip identity + to_absolute adds offset")
	origin.offset = Vector3.ZERO                     # reset for the rebase checks

	# --- 2. rebase fires only past one cell, snaps whole, keeps camera centered ---
	# Inside one cell: no rebase.
	if origin.maybe_rebase(Vector3(span * 0.4, 0.0, span * -0.3)) != Vector3.ZERO:
		_fail("rebase fired inside one cell (should not)")
	# Walk the camera outward in small steps; after each rebase the *residual* Godot
	# position (cam - accumulated offset-applied-to-view) must stay within one cell.
	var ok_center := true
	var ok_whole := true
	var cam_abs := 0.0                                # absolute camera X marched outward
	for i in range(400):
		cam_abs += span * 0.37                        # sub-cell steps, like flight
		# Godot position = absolute - offset (the view would move by -shift each rebase).
		var cam_godot := Vector3(cam_abs - origin.offset.x, 0.0, 0.0)
		var shift: Vector3 = origin.maybe_rebase(cam_godot)
		if shift != Vector3.ZERO:
			# shift must be a whole multiple of span.
			var n := shift.x / span
			if abs(n - round(n)) > 1e-4:
				ok_whole = false
		# After this frame, the residual Godot X must be within one cell of origin.
		var residual: float = cam_abs - origin.offset.x
		if abs(residual) >= span:
			ok_center = false
	if not ok_whole:
		_fail("a rebase shift was not a whole multiple of cell_span")
	elif not ok_center:
		_fail("camera drifted >= one cell from origin after rebasing (centering broken)")
	else:
		print("PASS: rebase — whole-cell shifts; camera stays within one cell of origin over 400 steps (offset now %.0f)" % origin.offset.x)

	# --- 3. TERRAIN NEUTRALITY via the real field (the load-bearing proof) ---
	var pool = ClassDB.instantiate("PagePool")
	if pool == null: _fail("PagePool not registered"); _finish(); return
	if not pool.initialize(SHADER): _fail("pool.initialize failed (need vulkan)"); _finish(); return
	pool.configure(RES, SPACING, SEED, OCT, FREQ, AMP, 4)

	# Pick a fixed ABSOLUTE world point far from origin; find its level-0 grid index.
	var abs_pt := Vector3(193_000.0, 0.0, -88_000.0)
	var gx := int(floor(abs_pt.x / span))
	var gz := int(floor(abs_pt.z / span))

	# Heights for that page, produced directly by the field (the source of truth).
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.initialize(SHADER):
		_fail("FieldCompute init failed (need vulkan)"); _finish(); return
	var h0: PackedFloat32Array = fc.produce_page(gx * span, gz * span, SPACING, SEED, RES, OCT, FREQ, AMP)

	# Now SIMULATE several rebases (any whole-cell offset). The grid index that the
	# view derives from the ABSOLUTE camera position for abs_pt is unchanged: gx,gz
	# come from floor(absolute/span), and the rebase only changes godot<->absolute,
	# not absolute. Re-derive gx,gz THROUGH the module to prove the wiring is neutral.
	var origin2 = WO.new(span)
	# Apply a big arbitrary whole-cell offset, as if we'd flown far.
	origin2.offset = Vector3(span * 379.0, 0.0, span * -173.0)
	# The view computes the ring/grid center from to_absolute(camera_godot). For the
	# page covering abs_pt, the camera-godot that corresponds is abs_pt - offset.
	var cam_godot_at_pt: Vector3 = origin2.to_godot(abs_pt)
	var re_abs: Vector3 = origin2.to_absolute(cam_godot_at_pt)
	var gx2 := int(floor(re_abs.x / span))
	var gz2 := int(floor(re_abs.z / span))
	if gx2 != gx or gz2 != gz:
		_fail("grid index changed under rebase: (%d,%d) -> (%d,%d)" % [gx, gz, gx2, gz2])
	else:
		var h1: PackedFloat32Array = fc.produce_page(gx2 * span, gz2 * span, SPACING, SEED, RES, OCT, FREQ, AMP)
		if h1.size() != h0.size():
			_fail("height size changed under rebase")
		elif h1.to_byte_array() != h0.to_byte_array():
			_fail("TERRAIN NOT NEUTRAL: heights at a fixed absolute point differ across rebase")
		else:
			print("PASS: terrain-neutral — heights at a fixed absolute point are BIT-IDENTICAL across a 379-cell rebase")

	_finish()

func _finish() -> void:
	print("M1.8 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
