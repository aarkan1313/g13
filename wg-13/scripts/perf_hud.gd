extends CanvasLayer
# DEMO dev tool — lightweight perf/diagnostics HUD, top-right. Reads the running
# scene; never writes it. Engine-side (world_view/Rust/GLSL) is untouched.
#
# Cost discipline: the only thing a text HUD can do to hurt perf is format a
# string every frame, so the LABEL is rebuilt at update_hz (~5/s), NOT per frame.
# The per-frame work is one delta sample into a ring buffer (negligible). All
# rows are toggleable; H hides the whole HUD. Frame time uses TRUE per-frame
# delta (the M1.6 lesson: Engine FPS is smoothed and hides spikes).

@export var update_hz: float = 5.0          # label refreshes per second (not per frame)
@export var window_frames: int = 240        # ring-buffer size for p99/max (~4s @ 60fps)
@export var budget_ms: float = 16.6         # 60 FPS budget; frame row goes amber over it

# Per-section toggles (also flippable live with number keys 1-5).
@export var show_frame: bool = true
@export var show_streaming: bool = true
@export var show_position: bool = true
@export var show_memory: bool = true
@export var show_profiler: bool = true      # M1.9 per-system frame breakdown (key 5)

var _label: Label
var _panel: PanelContainer
var _view: Node3D
var _samples := PackedFloat32Array()        # recent frame delta ms (ring)
var _accum := 0.0                           # time since last label refresh

func _ready() -> void:
	layer = 100                             # draw over the 3D scene
	# A small dark translucent panel BEHIND the text so it stays readable over
	# bright/varied terrain (the label alone washed out on light ground). The
	# PanelContainer hugs the label, so the backing is only as big as the text.
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_right = -8.0
	panel.offset_top = 8.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN   # extend left from the right edge
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE       # never eat input
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.0, 0.0, 0.0, 0.45)               # subtle dark wash
	bg.set_content_margin_all(8.0)
	bg.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 4)
	panel.add_child(_label)
	_panel = panel
	_find_view()

func _find_view() -> void:
	# The world_view is a sibling under the scene root; identify it by its API.
	var parent := get_parent()
	if parent == null:
		return
	for sib in parent.get_children():
		if sib != self and sib.has_method("page_span_value"):
			_view = sib
			return

func _process(delta: float) -> void:
	# Per-frame: cheap sample only.
	var ms := delta * 1000.0
	_samples.push_back(ms)
	while _samples.size() > window_frames:
		_samples.remove_at(0)

	_accum += delta
	if _accum < 1.0 / maxf(update_hz, 0.5):
		return                              # throttle the expensive part (string build)
	_accum = 0.0
	if visible:
		_label.text = _build_text(ms)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_H: visible = not visible
			KEY_1: show_frame = not show_frame
			KEY_2: show_streaming = not show_streaming
			KEY_3: show_position = not show_position
			KEY_4: show_memory = not show_memory
			KEY_5: show_profiler = not show_profiler

func _build_text(cur_ms: float) -> String:
	var lines := PackedStringArray()

	if show_frame:
		var p99 := _percentile(98.999)
		var mx := _max_sample()
		var fps: float = (1000.0 / cur_ms) if cur_ms > 0.0 else 0.0
		var warn := "  !!" if mx > budget_ms else ""
		lines.append("%.0f fps  %.2f ms" % [fps, cur_ms])
		lines.append("p99 %.2f  max %.2f%s" % [p99, mx, warn])

	if show_streaming and _view != null and _view._pool != null:
		var pool = _view._pool
		var bodies := 0
		if "_collisions" in _view:
			bodies = _view._collisions.size()
		lines.append("pages %d  bodies %d" % [pool.resident_count(), bodies])
		lines.append("made %d  evict %d" % [pool.total_produced(), pool.evicted_count()])

	if show_profiler and _view != null and _view._pool != null:
		var pool = _view._pool
		# Per-system frame cost (the M1.9 evidence). produce = GPU dispatch +
		# blocking readback in Rust; proc/mesh = this view's GDScript per frame.
		var prod_ms: float = pool.produce_us_this_frame() / 1000.0
		var proc_ms: float = 0.0
		var mesh_ms: float = 0.0
		if "prof_process_us" in _view:
			proc_ms = _view.prof_process_us / 1000.0
		if "prof_mesh_us" in _view:
			mesh_ms = _view.prof_mesh_us / 1000.0
		lines.append("prod %.2f ms (%d fine/%d eager)" % [
			prod_ms, pool.produced_this_frame(), pool.eager_this_frame()])
		lines.append("view %.2f ms  mesh %.2f ms" % [proc_ms, mesh_ms])

	if show_position and _view != null and _view._cam != null:
		var p: Vector3 = _view._cam.global_position
		var span: float = _view.page_span_value()
		var gx := int(floor(p.x / span))
		var gz := int(floor(p.z / span))
		lines.append("xz %.0f, %.0f  alt %.0f" % [p.x, p.z, p.y])
		lines.append("page %d, %d" % [gx, gz])

	if show_memory:
		var stat := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
		var vram := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
		lines.append("mem %.0f MB  vram %.0f MB" % [stat, vram])

	return "\n".join(lines)

# p99-style percentile over the window (defensive: empty -> 0).
func _percentile(pct: float) -> float:
	if _samples.is_empty():
		return 0.0
	var sorted := Array(_samples)
	sorted.sort()
	var idx := int(round((pct / 100.0) * (sorted.size() - 1)))
	return sorted[clampi(idx, 0, sorted.size() - 1)]

func _max_sample() -> float:
	var m := 0.0
	for s in _samples:
		m = maxf(m, s)
	return m
