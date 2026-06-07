extends RefCounted
class_name WorldOrigin
# ENGINE MODULE — camera-relative floating origin (world rebase).
#
# The streaming world is COMPUTED in ABSOLUTE coordinates (a page's terrain is a
# pure function of its integer grid index: page_pool feeds the GPU field
# origin = gx * span). It is DISPLAYED in GODOT coordinates kept near (0,0). One
# offset connects them:
#
#     godot_pos    = absolute_pos - offset
#     absolute_pos = godot_pos + offset
#
# As the camera flies out, its Godot position would grow without bound -> the world
# slides toward the edge of coarse coverage ("never centered / you reach the
# outside edge") and 32-bit float precision degrades at distance (vertex shimmer).
# This module pulls the displayed world back toward origin in WHOLE-CELL steps so
# the camera oscillates near (0,0) forever, while terrain generation is unchanged
# (the grid index for any absolute location is identical after a whole-cell shift
# -> determinism preserved, no field/Rust change).
#
# Single owner of the Godot<->absolute transform: every boundary crossing
# (ring center, page_terrain_height, player spawn) goes THROUGH this, so views /
# player / auto-tour / gates can't silently desync. Used by any view (engine
# capability, not view-specific). See spec:
# docs/superpowers/specs/2026-06-07-floating-origin-world-rebase-design.md

# Accumulated rebase in ABSOLUTE metres. godot = absolute - offset. X/Z only
# (altitude is bounded; rebasing Y would fight gravity/jump and gives no precision
# win). Y stays 0.
var offset := Vector3.ZERO

# Rebase quantum (world units). Set to the level-0 page span by the view in _ready.
# The camera is pulled back whenever it drifts >= this from the Godot origin, in
# whole multiples of it. Smaller = more frequent, smaller shifts (tighter centering);
# larger = looser. One fine cell is "continuous in feel" (fires ~30x/s in turbo,
# each shift visually identical) while keeping the field origin integer-exact.
var cell_span := 508.0

func _init(p_cell_span: float = 508.0) -> void:
	cell_span = max(p_cell_span, 1.0)

# Godot-space -> absolute-space. Feed this the camera (or any Godot) position to
# get the coordinate the GPU field / grid index must use, so terrain is unchanged.
func to_absolute(godot_pos: Vector3) -> Vector3:
	return godot_pos + offset

# Absolute-space -> Godot-space (the inverse). For placing something given its
# absolute world coordinate (rarely needed; provided for symmetry/completeness).
func to_godot(absolute_pos: Vector3) -> Vector3:
	return absolute_pos - offset

# Decide whether to rebase this frame. If the camera's Godot position has drifted
# >= cell_span from origin on X or Z, return the WHOLE-CELL shift to apply to the
# displayed world (move View + Player by -shift) and bank it into offset. Else
# return ZERO (no rebase). The shift is always an integer number of cell_span on
# X/Z, Y = 0, so the field's grid index is unchanged -> terrain bit-identical.
func maybe_rebase(cam_godot: Vector3) -> Vector3:
	if abs(cam_godot.x) < cell_span and abs(cam_godot.z) < cell_span:
		return Vector3.ZERO
	# Snap to the nearest whole number of cells the camera has drifted (X/Z only).
	var shift := Vector3(
		round(cam_godot.x / cell_span) * cell_span,
		0.0,
		round(cam_godot.z / cell_span) * cell_span)
	if shift == Vector3.ZERO:
		return Vector3.ZERO            # within half a cell of origin on both axes after rounding
	offset += shift
	return shift
