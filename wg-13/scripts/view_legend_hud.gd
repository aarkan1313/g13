extends CanvasLayer
# DEMO dev tool — view-mode LEGEND HUD, top-LEFT (mirrors perf_hud.gd on the right).
# When V cycles the terrain view (normal / temperature / moisture / biome), this
# shows a guide for reading what's on screen:
#   - biome  : each biome as [color swatch] id name -- % of visible terrain, AND a
#              flat on-GROUND number (Label3D) at the centroid of each large zone.
#   - temp   : a cold->hot color-ramp bar with end labels (continuous, no %).
#   - moisture: a dry->wet color-ramp bar.
#   - normal : a low->high elevation color-ramp bar.
# Reads the running scene; never writes the engine (world_view/Rust/GLSL untouched).
# Cost discipline (the perf_hud lesson): the % tally + zone scan run at update_hz
# (~3/s), NOT per frame. The ground labels reposition on the same throttle.
# Toggle the whole HUD with L; toggle the ground numbers with K.

@export var update_hz: float = 3.0          # legend/% refreshes per second (throttled)
@export var min_zone_cells: int = 40        # a biome needs this many sampled cells to get a ground number on N (filters tiny specks; step-11 sampling -> small raw counts)
@export var max_ground_labels: int = 14     # cap so it never clutters

# Biome id -> color (matches BIOME_COLORS in ring_displace.gdshader) + name.
const BIOME_COLORS := [
	Color(0.95, 0.96, 0.98), Color(0.62, 0.60, 0.52), Color(0.20, 0.42, 0.34),
	Color(0.55, 0.52, 0.50), Color(0.70, 0.72, 0.40), Color(0.30, 0.55, 0.28),
	Color(0.16, 0.45, 0.30), Color(0.85, 0.74, 0.45), Color(0.78, 0.70, 0.32),
	Color(0.18, 0.60, 0.25),
]
const BIOME_NAMES := [
	"snow / ice", "tundra", "taiga", "mountain rock", "grassland",
	"temperate forest", "temp. rainforest", "desert", "savanna", "tropical rainforest",
]

var _panel: PanelContainer
var _rows: VBoxContainer
var _view: Node3D
var _accum := 0.0
var _ground := {}                           # biome id -> Label3D (on-ground number)
var _ground_root: Node3D

func _ready() -> void:
	layer = 100
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 8.0
	panel.offset_top = 8.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.0, 0.0, 0.0, 0.45)
	bg.set_content_margin_all(8.0)
	bg.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 2)
	panel.add_child(_rows)
	_panel = panel
	_find_view()

func _find_view() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for sib in parent.get_children():
		if sib != self and sib.has_method("view_mode"):
			_view = sib
			# a child node to hold the on-ground labels (so we can clear them as a unit)
			_ground_root = Node3D.new()
			_ground_root.name = "BiomeGroundLabels"
			sib.add_child(_ground_root)
			return

func _process(delta: float) -> void:
	_accum += delta
	# Biome view runs the expensive per-page biome scan -> refresh it slower
	# (1.5/s) than the cheap ramp views (update_hz). The % + zone numbers don't
	# need to change faster than that.
	var hz: float = update_hz
	if _view != null and _view.view_mode() == 3:
		hz = 1.5
	if _accum < 1.0 / maxf(hz, 0.5):
		return
	_accum = 0.0
	if visible and _view != null:
		_rebuild()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_L:
				visible = not visible
				if not visible:
					_clear_ground()
			KEY_N:
				# Manual TRIGGER: snapshot the on-ground biome numbers where you are
				# now (only meaningful in biome view). They stay put until you press
				# N again (re-snapshot) or K (clear) — no per-frame flicker/cost.
				if _view != null and _view.view_mode() == 3:
					_scan_biomes()
					_update_ground_numbers()
			KEY_K:
				_clear_ground()

# --- legend build -----------------------------------------------------------

func _rebuild() -> void:
	for c in _rows.get_children():
		c.queue_free()
	var mode: int = _view.view_mode()
	var name: String = _view.view_mode_name()
	_add_title("VIEW: %s  (V to cycle)" % name.to_upper())
	match mode:
		3: _build_biome()
		1: _build_ramp("temperature", [
				[Color(0.10,0.20,0.85), "cold"], [Color(0.45,0.30,0.85), ""],
				[Color(0.75,0.30,0.70), "mild"], [Color(0.92,0.35,0.30), ""],
				[Color(0.85,0.12,0.10), "hot"]])
		2: _build_ramp("moisture", [
				[Color(0.50,0.34,0.16), "dry"], [Color(0.80,0.72,0.42), ""],
				[Color(0.42,0.68,0.30), "mid"], [Color(0.20,0.72,0.72), ""],
				[Color(0.10,0.40,0.80), "wet"]])
		_: _build_ramp("elevation", [
				[Color(0.26,0.40,0.20), "low"], [Color(0.40,0.45,0.30), ""],
				[Color(0.55,0.50,0.40), "high"]])
	# On-ground numbers are MANUAL (press N in biome view) — not auto-placed, so
	# they don't flicker or cost per frame. Just clear them when you leave biome view.
	if mode != 3:
		_clear_ground()

func _add_title(s: String) -> void:
	var l := Label.new()
	l.text = s
	l.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 4)
	_rows.add_child(l)

# one legend row: [swatch] text
func _add_swatch_row(col: Color, text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var sw := ColorRect.new()
	sw.color = col
	sw.custom_minimum_size = Vector2(16, 16)
	row.add_child(sw)
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 4)
	row.add_child(l)
	_rows.add_child(row)

func _build_ramp(label: String, stops: Array) -> void:
	# A horizontal gradient bar with the stop labels under it.
	var grad := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for i in range(stops.size()):
		offs.append(float(i) / float(stops.size() - 1))
		cols.append(stops[i][0])
	grad.offsets = offs
	grad.colors = cols
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 180
	tex.height = 14
	var tr := TextureRect.new()
	tr.texture = tex
	tr.custom_minimum_size = Vector2(180, 14)
	_rows.add_child(tr)
	# end labels (left = first non-empty, right = last non-empty)
	var lo := ""
	var hi := ""
	for s in stops:
		if s[1] != "":
			if lo == "": lo = s[1]
			hi = s[1]
	_add_swatch_row(Color(0,0,0,0), "%s  <- %s ... %s ->" % [label, lo, hi])

# Combined biome scan: ONE pass over the visible level-0 pages (each page's biome
# array fetched ONCE — get_page_biome clones a 128^2 array across FFI, so calling
# it twice/page was the biome-view lag). Fills fixed-size arrays (no Dictionary in
# the hot loop): per-biome cell count + world-space centroid sums. Cached so the
# legend + ground numbers share one scan. nb = BIOME_COLORS.size() (10).
var _bcount := PackedInt32Array()           # cells per biome id (sampled)
var _bsumx := PackedFloat64Array()          # world-X sum per biome
var _bsumz := PackedFloat64Array()          # world-Z sum per biome
var _btotal := 0

func _scan_biomes() -> void:
	var nb := BIOME_COLORS.size()
	if _bcount.size() != nb:
		_bcount.resize(nb); _bsumx.resize(nb); _bsumz.resize(nb)
	for k in range(nb):
		_bcount[k] = 0; _bsumx[k] = 0.0; _bsumz[k] = 0.0
	_btotal = 0
	if _view._pool == null:
		return
	var page_res: int = _view.page_res
	var span: float = _view.page_span_value()
	var spacing: float = span / float(page_res - 1)
	var step := 11   # coarse sample — this is a %, not an exact count
	for key in _view._instances.keys():
		var m: Vector3i = _view._inst_meta[key]
		if m.x != 0:            # level-0 (fine) pages only — the ground you see/walk
			continue
		var biome: PackedFloat32Array = _view._pool.get_page_biome(m.x, m.y, m.z)
		if biome.is_empty():
			continue
		var ox: float = m.y * span
		var oz: float = m.z * span
		var n := biome.size()
		var i := 0
		while i < n:
			var id := int(biome[i] + 0.5)
			if id >= 0 and id < nb:
				_bcount[id] += 1
				_btotal += 1
				_bsumx[id] += ox + float(i % page_res) * spacing
				_bsumz[id] += oz + float(i / page_res) * spacing
			i += step

func _build_biome() -> void:
	_scan_biomes()
	_add_title("  (N = drop numbers on ground)")
	for id in range(BIOME_COLORS.size()):
		var col: Color = BIOME_COLORS[id]
		var txt: String
		if _bcount[id] == 0:
			col = col.darkened(0.55)   # dim absent biomes
			txt = "%d  %s  --" % [id, BIOME_NAMES[id]]
		else:
			var pct := 100.0 * float(_bcount[id]) / float(max(_btotal, 1))
			txt = "%d  %s  %.0f%%" % [id, BIOME_NAMES[id], pct]
		_add_swatch_row(col, txt)

# --- on-ground biome-id numbers (flat Label3D at large-zone centroids) ------
# GRID approach: drop a biome-id number on the ground at every world-grid point
# (grid_step_m apart) around the player, each showing whichever biome is at that
# spot. So numbers spread across each zone at regular intervals — you always have
# one nearby, and split zones each get their own (vs the old centroid that landed
# between patches). Sampled where terrain is resident; off-page points are skipped.
# SCALE: the visible world reaches ~49 km (the LOD horizon), so the grid covers
# ~that radius — at 9 km it was a tiny patch against a ~100 km-wide view. extent
# ~45 km, ~17 per side -> ~2.6 km spacing, numbers across the whole visible terrain.
@export var grid_extent_m: float = 45000.0  # half-width of the grid around the player (~LOD reach)
@export var grid_side: int = 17             # numbers per side -> grid_side^2 total (17^2=289)

func _update_ground_numbers() -> void:
	if _ground_root == null or _view._cam == null:
		return
	var cam: Vector3 = _view._cam.global_position
	# Spacing auto-fits the extent across grid_side points, so the numbers ALWAYS
	# cover the full grid_extent_m around you evenly (was: fixed 700m step + a 200
	# cap that filled only a corner of the area before running out).
	var grid_step_m: float = (2.0 * grid_extent_m) / float(max(grid_side - 1, 1))
	var max_ground_total: int = grid_side * grid_side
	# Snap the grid to world coords (so numbers don't jitter as you move).
	var x0: float = floor((cam.x - grid_extent_m) / grid_step_m) * grid_step_m
	var z0: float = floor((cam.z - grid_extent_m) / grid_step_m) * grid_step_m
	var n := 0
	var wz := z0
	while wz <= cam.z + grid_extent_m and n < max_ground_total:
		var wx := x0
		while wx <= cam.x + grid_extent_m and n < max_ground_total:
			var id := _biome_at(wx, wz)
			if id >= 0:
				var wy: float = _height_at(wx, wz)
				if is_finite(wy):
					_place_ground(n, id, Vector3(wx, wy + 120.0, wz))
					n += 1
			wx += grid_step_m
		wz += grid_step_m
	# hide any leftover labels from a denser previous snapshot
	for i in range(n, _ground.size()):
		if _ground.has(i):
			_ground[i].visible = false

# Biome id at a world point. Tries the FINEST resident page first, falling back to
# coarser levels — the distant terrain you see is COARSE pages (levels 1..N), and
# only a few FINE (level 0) pages are resident near the player, so level-0-only
# made numbers appear only right around you. Returns -1 if no page covers it.
func _biome_at(wx: float, wz: float) -> int:
	var base_span: float = _view.page_span_value()
	var page_res: int = _view.page_res
	var coarsest: int = _view.num_levels - 1
	for level in range(0, coarsest + 1):
		var span: float = base_span * pow(2.0, level)
		var gx: int = int(floor(wx / span))
		var gz: int = int(floor(wz / span))
		var biome: PackedFloat32Array = _view._pool.get_page_biome(level, gx, gz)
		if biome.size() != page_res * page_res:
			continue
		var spacing: float = span / float(page_res - 1)
		var cx: int = clampi(int(round((wx - gx * span) / spacing)), 0, page_res - 1)
		var cz: int = clampi(int(round((wz - gz * span) / spacing)), 0, page_res - 1)
		return int(biome[cz * page_res + cx] + 0.5)
	return -1

# Terrain height at a world point, finest resident page first (coarse fallback) —
# so a number placed out in coarse-page distance still sits ON the ground, not at
# a fixed altitude. NAN if no page covers it.
func _height_at(wx: float, wz: float) -> float:
	var base_span: float = _view.page_span_value()
	var page_res: int = _view.page_res
	var coarsest: int = _view.num_levels - 1
	for level in range(0, coarsest + 1):
		var span: float = base_span * pow(2.0, level)
		var gx: int = int(floor(wx / span))
		var gz: int = int(floor(wz / span))
		var heights: PackedFloat32Array = _view._pool.get_page_heights(level, gx, gz)
		if heights.size() != page_res * page_res:
			continue
		var spacing: float = span / float(page_res - 1)
		var cx: int = clampi(int(round((wx - gx * span) / spacing)), 0, page_res - 1)
		var cz: int = clampi(int(round((wz - gz * span) / spacing)), 0, page_res - 1)
		return heights[cz * page_res + cx]
	return NAN

# Place a number at grid-slot `slot` (labels are pooled + reused across snapshots),
# showing biome `id` (its color), lying FLAT on the ground at `pos`.
func _place_ground(slot: int, id: int, pos: Vector3) -> void:
	var lbl: Label3D
	if _ground.has(slot):
		lbl = _ground[slot]
	else:
		lbl = Label3D.new()
		lbl.font_size = 256
		lbl.outline_size = 40
		lbl.outline_modulate = Color(0, 0, 0, 0.9)
		# BILLBOARD (always faces the camera) so the numbers are readable from the
		# air at any angle/distance — flat-on-ground numbers go edge-on + vanish when
		# you look across the terrain. Big pixel_size: at ~km viewing distance they
		# must be large to read. no_depth_test so they show over terrain (not buried).
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.fixed_size = false
		lbl.pixel_size = 8.0      # large — these sit km away across the visible world
		lbl.no_depth_test = true
		_ground_root.add_child(lbl)
		_ground[slot] = lbl
	lbl.text = str(id)
	lbl.modulate = BIOME_COLORS[id].lightened(0.25)
	lbl.visible = true
	lbl.global_position = pos

func _clear_ground() -> void:
	for slot in _ground.keys():
		_ground[slot].visible = false
