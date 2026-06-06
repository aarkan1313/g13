extends SceneTree
# M1.5c gate — NO-OVERLAP (annulus clipmap). After the rings settle, no two
# levels may display the same world ground: a coarse page must be HIDDEN wherever
# the finer pages covering its footprint are all resident. Overlap => z-fighting,
# which is what this prevents by construction.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m1_5c_overlap_check.gd

const VIEW := preload("res://scripts/world_view.gd")
const SETTLE_FRAMES := 90        # let the bounded fine ring fully fill

var _failed := false
var _root: Node3D
var _frames := 0
func _fail(m): _failed = true; print("FAIL: ", m)

func _init() -> void:
	_root = Node3D.new()
	_root.set_script(VIEW)
	# Generous budget + modest rings so the fine ring fully fills within SETTLE.
	_root.set("max_new_per_frame", 64)
	_root.set("ring_radius", 2)
	_root.set("num_levels", 2)
	get_root().add_child(_root)

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < SETTLE_FRAMES:
		return false
	_check()
	_finish()
	return true

func _check() -> void:
	var inst: Dictionary = _root.get("_instances")
	if inst == null or inst.is_empty():
		_fail("view built no page instances"); return

	# Collect VISIBLE pages per level (a hidden mesh draws nothing, so it can't
	# z-fight — annulus hides coarse where fine covers, it doesn't free it).
	var fine := {}     # "gx:gz" visible at level 0
	var coarse := {}   # "gx:gz" visible at level 1
	for key in inst.keys():
		var mi: MeshInstance3D = inst[key]
		if not mi.visible:
			continue
		var p: PackedStringArray = key.split(":")
		var lvl := int(p[0]); var gx := int(p[1]); var gz := int(p[2])
		if lvl == 0: fine["%d:%d" % [gx, gz]] = true
		elif lvl == 1: coarse["%d:%d" % [gx, gz]] = true

	if fine.is_empty():
		_fail("no fine pages displayed after settle (budget too tight?)"); return

	# Invariant: any coarse page whose 2x2 fine footprint is FULLY displayed must
	# NOT itself be displayed (else it overlaps fine -> z-fight). Coarse page
	# (cgx,cgz) covers fine (2cgx..2cgx+1, 2cgz..2cgz+1).
	var overlaps := 0
	for ckey in coarse.keys():
		var cp: PackedStringArray = ckey.split(":")
		var cgx := int(cp[0]); var cgz := int(cp[1])
		var all_fine := true
		for dz in range(2):
			for dx in range(2):
				if not fine.has("%d:%d" % [2 * cgx + dx, 2 * cgz + dz]):
					all_fine = false
		if all_fine:
			overlaps += 1   # coarse displayed where fine fully covers -> overlap

	if overlaps > 0:
		_fail("%d coarse pages overlap fully-covered fine area (would z-fight)" % overlaps)
	else:
		print("PASS: no-overlap — every coarse page with a full fine footprint is hidden (annulus holds)")

	print("INFO: fine=%d coarse=%d displayed" % [fine.size(), coarse.size()])

func _finish() -> void:
	print("M1.5c-overlap RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
