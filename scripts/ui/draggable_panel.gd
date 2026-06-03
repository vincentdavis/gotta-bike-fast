class_name DraggablePanel
extends PanelContainer

# Turns a HUD panel into a user-movable + resizable floating widget.
#
#   • Drag anywhere on the panel body to move it.
#   • Drag the bottom-right grip (drawn as three diagonal ticks) to resize.
#   • Double-click the panel to reset to its scene-authored position/size.
#
# The rect is persisted to user://hud_layout.cfg keyed by panel_id, so a
# player's layout survives across rides and relaunches.
#
# Attach as the script on a PanelContainer and set panel_id (+ optionally
# default_size as a fallback for panels that start hidden, whose computed
# rect isn't available at _ready time).

const LAYOUT_FILE := "user://hud_layout.cfg"
const GRIP := 22.0          # bottom-right square that triggers resize
const MIN_SIZE := Vector2(120.0, 80.0)
const EDGE_MARGIN := 40.0   # keep at least this many px on-screen / grabbable

@export var panel_id: String = ""
@export var default_size := Vector2(320.0, 400.0)

var _default_rect: Rect2
var _dragging := false
var _resizing := false
var _grab_offset := Vector2.ZERO
var _resize_start_size := Vector2.ZERO
var _resize_start_mouse := Vector2.ZERO


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_MOVE
	# Wait one frame so the scene-authored anchors/offsets have been
	# resolved into a concrete rect before we capture + free it.
	await get_tree().process_frame
	var rect := get_rect()
	if rect.size.x < 10.0 or rect.size.y < 10.0:
		# Hidden-at-startup panels (e.g. the minimap) have no computed
		# size yet — fall back to the authored default.
		rect = Rect2(position, default_size)
	_default_rect = rect
	# Switch to free top-left anchoring so position is independent of the
	# viewport edges from here on (it's a user-positioned widget now).
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_END
	_make_subtree_ignore_mouse(self)
	apply_rect(_load_saved_rect())


# Recursively let mouse events fall through child Controls to this panel
# so a drag started anywhere on the body moves the whole widget. Called
# again by the host (hud.gd) after it rebuilds dynamic content like the
# leaderboard rows.
func make_content_passthrough() -> void:
	_make_subtree_ignore_mouse(self)


func _make_subtree_ignore_mouse(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_make_subtree_ignore_mouse(child)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			if mb.double_click:
				apply_rect(_default_rect)
				_save_rect()
				accept_event()
				return
			if _in_grip(mb.position):
				_resizing = true
				_resize_start_size = size
				_resize_start_mouse = get_global_mouse_position()
			else:
				_dragging = true
				_grab_offset = get_global_mouse_position() - global_position
			accept_event()
		else:
			if _dragging or _resizing:
				_dragging = false
				_resizing = false
				_save_rect()
				accept_event()
	elif event is InputEventMouseMotion:
		if _dragging:
			position = _clamp_pos(get_global_mouse_position() - _grab_offset)
			accept_event()
		elif _resizing:
			var delta := get_global_mouse_position() - _resize_start_mouse
			var ns := _resize_start_size + delta
			ns.x = maxf(ns.x, MIN_SIZE.x)
			ns.y = maxf(ns.y, MIN_SIZE.y)
			_apply_size(ns)
			accept_event()
		else:
			mouse_default_cursor_shape = (
				Control.CURSOR_FDIAGSIZE
				if _in_grip((event as InputEventMouseMotion).position)
				else Control.CURSOR_MOVE
			)


func _draw() -> void:
	# Three diagonal ticks in the bottom-right corner as a resize affordance.
	var c := Color(1, 1, 1, 0.45)
	for i in range(3):
		var d := 5.0 + float(i) * 5.0
		draw_line(Vector2(size.x - d, size.y - 4.0), Vector2(size.x - 4.0, size.y - d), c, 1.5)


func _in_grip(local_pos: Vector2) -> bool:
	return local_pos.x >= size.x - GRIP and local_pos.y >= size.y - GRIP


func _clamp_pos(p: Vector2) -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(
		clampf(p.x, EDGE_MARGIN - size.x, vp.x - EDGE_MARGIN),
		clampf(p.y, 0.0, vp.y - EDGE_MARGIN),
	)


func apply_rect(r: Rect2) -> void:
	_apply_size(r.size)
	position = _clamp_pos(r.position)


func _apply_size(s: Vector2) -> void:
	# custom_minimum_size is the reliable size lever for a Container;
	# setting size too keeps the offsets in sync for persistence. The
	# panel still can't shrink below its content's combined min size.
	custom_minimum_size = s
	size = s
	queue_redraw()


func _load_saved_rect() -> Rect2:
	if panel_id.is_empty():
		return _default_rect
	var cfg := ConfigFile.new()
	if cfg.load(LAYOUT_FILE) != OK or not cfg.has_section(panel_id):
		return _default_rect
	return Rect2(
		Vector2(
			float(cfg.get_value(panel_id, "x", _default_rect.position.x)),
			float(cfg.get_value(panel_id, "y", _default_rect.position.y)),
		),
		Vector2(
			float(cfg.get_value(panel_id, "w", _default_rect.size.x)),
			float(cfg.get_value(panel_id, "h", _default_rect.size.y)),
		),
	)


func _save_rect() -> void:
	if panel_id.is_empty():
		return
	var cfg := ConfigFile.new()
	cfg.load(LAYOUT_FILE)  # ignore failure — fresh file is fine
	cfg.set_value(panel_id, "x", position.x)
	cfg.set_value(panel_id, "y", position.y)
	cfg.set_value(panel_id, "w", size.x)
	cfg.set_value(panel_id, "h", size.y)
	cfg.save(LAYOUT_FILE)
