extends CanvasLayer

# Tap events from the on-screen touch controls (phones/tablets). The hold
# buttons are read by ride_controller each tick via touch_power_dir /
# touch_steer_dir instead — held state, not events, mirroring the keyboard.
signal touch_turn
signal touch_camera
signal touch_finish

@onready var stats_panel: PanelContainer = $StatsPanel
@onready var power_label: Label = $StatsPanel/Margin/VBox/PowerLabel
@onready var cadence_label: Label = $StatsPanel/Margin/VBox/CadenceLabel
@onready var speed_label: Label = $StatsPanel/Margin/VBox/SpeedLabel
@onready var heart_rate_label: Label = $StatsPanel/Margin/VBox/HeartRateLabel
@onready var trainer_label: Label = $StatsPanel/Margin/VBox/TrainerLabel
@onready var distance_label: Label = $StatsPanel/Margin/VBox/DistanceLabel
@onready var lap_label: Label = $StatsPanel/Margin/VBox/LapLabel
@onready var grade_label: Label = $StatsPanel/Margin/VBox/GradeLabel
@onready var time_label: Label = $StatsPanel/Margin/VBox/TimeLabel
@onready var draft_label: Label = $StatsPanel/Margin/VBox/DraftLabel
@onready var course_label: Label = $StatsPanel/Margin/VBox/CourseLabel
@onready var hint_label: Label = $StatsPanel/Margin/VBox/HintLabel
@onready var status_label: Label = $StatsPanel/Margin/VBox/StatusLabel
@onready var countdown_label: Label = $CountdownLabel
@onready var leaderboard_panel: PanelContainer = $LeaderboardPanel
@onready var leaderboard_list: VBoxContainer = $LeaderboardPanel/Margin/VBox/Scroll/List
@onready var cp_panel: PanelContainer = $CPPanel
@onready var cp_curve_box: CPCurveBox = $CPPanel/Margin/VBox/CurveBox
@onready var minimap_panel: PanelContainer = $MinimapPanel
@onready var minimap_box: Control = $MinimapPanel/Margin/VBox/MapBox
@onready var minimap_rect: TextureRect = $MinimapPanel/Margin/VBox/MapBox/MinimapRect
@onready var minimap_marker: ColorRect = $MinimapPanel/Margin/VBox/MapBox/RiderMarker
@onready var camera_label: Label = $CameraToast

# Camera-view toast: shows the active view name for a moment after a switch,
# then fades out. _camera_toast_t counts down; the last CAMERA_TOAST_FADE_S
# seconds fade the alpha to zero.
const CAMERA_TOAST_S := 1.6
const CAMERA_TOAST_FADE_S := 0.5
var _camera_toast_t := 0.0
# HUD text colour (from GraphicsSettings, applied in apply_appearance). Used
# by set_draft() to restore the draft row's colour after drafting and by
# set_leaderboard() to colour dynamically-created rows.
var _stat_base_color := Color(1, 1, 1)
var _hud_text_color := Color(1, 1, 1)
var _hud_outline_color := Color(0, 0, 0, 0.7)  # reused for dynamic leaderboard rows

# --- Touch controls (built in code; VISIBILITY_TOUCHSCREEN_ONLY hides them
# on desktop). ◀▶ steer bottom-left, ▲▼ power bottom-right, small taps
# (camera / turn / finish) along the top. Finish needs a confirming second
# tap so a stray thumb can't end a race.
const TOUCH_BTN := 96.0
const TOUCH_SMALL := 56.0
const TOUCH_MARGIN := 18.0
const TOUCH_GAP := 12.0
const FINISH_CONFIRM_MS := 2500

var _touch_up: TouchScreenButton = null
var _touch_down: TouchScreenButton = null
var _touch_left: TouchScreenButton = null
var _touch_right: TouchScreenButton = null
var _touch_cam: TouchScreenButton = null
var _touch_turn: TouchScreenButton = null
var _touch_fin: TouchScreenButton = null
var _touch_fin_glyph: Label = null
var _finish_armed_until_ms: int = 0


func _ready() -> void:
	_build_touch_controls()
	get_viewport().size_changed.connect(_layout_touch_controls)


func _process(delta: float) -> void:
	if _camera_toast_t > 0.0:
		_camera_toast_t -= delta
		if _camera_toast_t <= 0.0:
			camera_label.modulate.a = 0.0
		elif _camera_toast_t < CAMERA_TOAST_FADE_S:
			camera_label.modulate.a = _camera_toast_t / CAMERA_TOAST_FADE_S
	# Disarm the finish confirm once its window lapses untapped.
	if _finish_armed_until_ms > 0 and Time.get_ticks_msec() > _finish_armed_until_ms:
		_finish_armed_until_ms = 0
		if _touch_fin_glyph != null:
			_touch_fin_glyph.text = "🏁"


func touch_power_dir() -> float:
	# −1‥+1 held-ramp direction from the on-screen ▲/▼ buttons.
	var dir := 0.0
	if _touch_up != null and _touch_up.is_pressed():
		dir += 1.0
	if _touch_down != null and _touch_down.is_pressed():
		dir -= 1.0
	return dir


func touch_steer_dir() -> float:
	var dir := 0.0
	if _touch_left != null and _touch_left.is_pressed():
		dir -= 1.0
	if _touch_right != null and _touch_right.is_pressed():
		dir += 1.0
	return dir


func _build_touch_controls() -> void:
	_touch_left = _touch_button("◀", TOUCH_BTN)
	_touch_right = _touch_button("▶", TOUCH_BTN)
	_touch_up = _touch_button("▲", TOUCH_BTN)
	_touch_down = _touch_button("▼", TOUCH_BTN)
	_touch_cam = _touch_button("📷", TOUCH_SMALL)
	_touch_cam.released.connect(func() -> void: touch_camera.emit())
	_touch_turn = _touch_button("🔄", TOUCH_SMALL)
	_touch_turn.released.connect(func() -> void: touch_turn.emit())
	_touch_fin = _touch_button("🏁", TOUCH_SMALL)
	_touch_fin_glyph = _touch_fin.get_node("Glyph")
	_touch_fin.released.connect(_on_touch_finish)
	_layout_touch_controls()


func _on_touch_finish() -> void:
	var now := Time.get_ticks_msec()
	if now <= _finish_armed_until_ms:
		_finish_armed_until_ms = 0
		_touch_fin_glyph.text = "🏁"
		touch_finish.emit()
		return
	_finish_armed_until_ms = now + FINISH_CONFIRM_MS
	_touch_fin_glyph.text = "✓?"


func _touch_button(glyph: String, size_px: float) -> TouchScreenButton:
	var btn := TouchScreenButton.new()
	btn.visibility_mode = TouchScreenButton.VISIBILITY_TOUCHSCREEN_ONLY
	# TOUCHSCREEN_ONLY only suppresses the button's own texture — its Glyph
	# child would still draw on desktops — so hide the whole node there.
	btn.visible = DisplayServer.is_touchscreen_available()
	btn.texture_normal = _touch_texture(size_px, 0.30)
	btn.texture_pressed = _touch_texture(size_px, 0.55)
	var shape := RectangleShape2D.new()
	shape.size = Vector2(size_px, size_px)
	btn.shape = shape
	btn.shape_centered = false
	var lbl := Label.new()
	lbl.name = "Glyph"
	lbl.text = glyph
	lbl.size = Vector2(size_px, size_px)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", int(size_px * 0.42))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(lbl)
	add_child(btn)
	return btn


func _touch_texture(size_px: float, alpha: float) -> GradientTexture2D:
	# A flat translucent square — TouchScreenButton needs a texture to have a
	# visible footprint, and a solid gradient is the cheapest way to one.
	var tex := GradientTexture2D.new()
	tex.width = int(size_px)
	tex.height = int(size_px)
	var g := Gradient.new()
	var ink := Color(0.18, 0.16, 0.14, alpha)
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([ink, ink])
	tex.gradient = g
	return tex


func _layout_touch_controls() -> void:
	if _touch_up == null:
		return
	var vs := get_viewport().get_visible_rect().size
	var m := TOUCH_MARGIN
	# Steering pair, bottom-left.
	_touch_left.position = Vector2(m, vs.y - m - TOUCH_BTN)
	_touch_right.position = Vector2(m + TOUCH_BTN + TOUCH_GAP, vs.y - m - TOUCH_BTN)
	# Power stack, bottom-right.
	_touch_up.position = Vector2(
		vs.x - m - TOUCH_BTN, vs.y - m - TOUCH_BTN * 2.0 - TOUCH_GAP
	)
	_touch_down.position = Vector2(vs.x - m - TOUCH_BTN, vs.y - m - TOUCH_BTN)
	# Small taps, top row just right of center — clear of the stats panel on
	# the left and the leaderboard on the right at default layouts.
	var row_w := TOUCH_SMALL * 3.0 + TOUCH_GAP * 2.0
	var x0 := vs.x * 0.60 - row_w / 2.0
	_touch_cam.position = Vector2(x0, m)
	_touch_turn.position = Vector2(x0 + TOUCH_SMALL + TOUCH_GAP, m)
	_touch_fin.position = Vector2(x0 + (TOUCH_SMALL + TOUCH_GAP) * 2.0, m)


func show_camera(view_name: String) -> void:
	if view_name.is_empty():
		return
	show_toast("📷  %s" % view_name)


func show_toast(text: String) -> void:
	# Transient corner toast (reuses the camera-toast label + fade timer) for
	# brief notices like camera changes and game-speed nudges.
	if text.is_empty():
		return
	camera_label.text = text
	camera_label.modulate.a = 1.0
	_camera_toast_t = CAMERA_TOAST_S


func apply_appearance() -> void:
	# Shared HUD look from GraphicsSettings: a translucent background panel +
	# text colour applied to all three readouts — the stats column, the
	# leaderboard, and the minimap — so they're legible over bright scenery and
	# the player can recolour them to taste.
	var text: Color = GraphicsSettings.hud_text_color
	_hud_text_color = text
	_stat_base_color = text  # so set_draft restores the themed colour
	# A thin outline in the opposite luminance keeps text crisp on any panel.
	var outline := Color(0, 0, 0, 0.7) if text.get_luminance() > 0.4 else Color(1, 1, 1, 0.5)
	_hud_outline_color = outline

	for p in [stats_panel, leaderboard_panel, minimap_panel]:
		if p != null:
			p.add_theme_stylebox_override("panel", _panel_style(GraphicsSettings.hud_bg_style()))

	var text_nodes: Array = [
		power_label, cadence_label, speed_label, heart_rate_label, trainer_label,
		distance_label, lap_label, grade_label, time_label, draft_label,
		course_label, hint_label, status_label, camera_label,
		get_node_or_null("LeaderboardPanel/Margin/VBox/Title"),
		get_node_or_null("MinimapPanel/Margin/VBox/Title"),
	]
	for n in text_nodes:
		if n != null:
			n.add_theme_color_override("font_color", text)
			n.add_theme_color_override("font_outline_color", outline)
			n.add_theme_constant_override("outline_size", 3)

	# Clear TrainerLabel's scene-authored blue tint so it follows the configured
	# text colour like every other stat row.
	trainer_label.modulate = Color.WHITE

	# The countdown keeps its terracotta accent — it's a transient call-out, not
	# a configurable readout.
	countdown_label.add_theme_color_override("font_color", Color("a85a3c"))
	countdown_label.add_theme_color_override("font_outline_color", Color("2e2a24"))
	countdown_label.add_theme_constant_override("outline_size", 6)
	_refit()


func _panel_style(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(6)
	sb.set_border_width_all(1)
	sb.border_color = Color(0, 0, 0, 0.28)  # faint ink edge
	return sb


func _refit() -> void:
	# The stats panel hugs its currently-visible rows (optional ones collapse),
	# anchored at its top-left position. The always-present hint row fixes the
	# width, so there's no horizontal jitter as numbers change.
	if stats_panel != null:
		stats_panel.reset_size()


func set_power(w: float, from_sensor: bool = false) -> void:
	# A small "(sensor)" tag flags when the watts are coming off a paired
	# power meter rather than the keyboard ramp.
	var tag := "  (sensor)" if from_sensor else ""
	power_label.text = "Power: %d W%s" % [int(round(w)), tag]


func set_cadence(rpm: float) -> void:
	# Negative rpm means "no fresh cadence source" — collapse the row so it
	# doesn't leave a blank gap in the stat list.
	var was := cadence_label.visible
	if rpm < 0.0:
		cadence_label.visible = false
	else:
		cadence_label.visible = true
		cadence_label.text = "Cadence: %d rpm" % int(round(rpm))
	if cadence_label.visible != was:
		_refit()


func set_heart_rate(bpm: int) -> void:
	# 0 (or less) means "no fresh heart-rate source" — collapse the row.
	var was := heart_rate_label.visible
	if bpm <= 0:
		heart_rate_label.visible = false
	else:
		heart_rate_label.visible = true
		heart_rate_label.text = "HR: %d bpm" % bpm
	if heart_rate_label.visible != was:
		_refit()


func set_trainer(text: String) -> void:
	# Empty text means no controllable trainer — collapse the row.
	var was := trainer_label.visible
	if text.is_empty():
		trainer_label.visible = false
	else:
		trainer_label.visible = true
		trainer_label.text = "Trainer: %s" % text
	if trainer_label.visible != was:
		_refit()


func set_speed(mps: float) -> void:
	speed_label.text = "Speed: %.1f km/h" % (mps * 3.6)


func set_distance(m: float) -> void:
	if m >= 1000.0:
		distance_label.text = "Distance: %.2f km" % (m / 1000.0)
	else:
		distance_label.text = "Distance: %d m" % int(m)


func set_grade(percent: float) -> void:
	grade_label.text = "Grade: %+.1f%%" % percent


func set_lap(lap: int) -> void:
	lap_label.text = "Lap: %d" % lap


func set_elapsed(s: float) -> void:
	var total: int = int(s)
	var minutes: int = total / 60
	var seconds: int = total % 60
	time_label.text = "Time: %d:%02d" % [minutes, seconds]


func set_draft(savings_pct: int) -> void:
	draft_label.text = "Draft: %d%%" % savings_pct
	# Tint cyan when actively drafting, white otherwise.
	if savings_pct > 0:
		draft_label.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))
	else:
		# Restore the themed base (cream under Belleville, white otherwise) —
		# not remove_theme_color_override, which would drop to engine-white and
		# desync this row from the other cream stats.
		draft_label.add_theme_color_override("font_color", _stat_base_color)


func set_course(name: String, length_m: float) -> void:
	course_label.text = "%s · %.1f km" % [name, length_m / 1000.0]


func set_status(text: String) -> void:
	status_label.text = text


func show_countdown(seconds_remaining: float) -> void:
	if seconds_remaining <= 0.0:
		countdown_label.text = "GO!"
	elif seconds_remaining < 1.0:
		countdown_label.text = "GO!"
	else:
		countdown_label.text = "%d" % int(ceil(seconds_remaining))


func hide_countdown() -> void:
	countdown_label.text = ""


func set_cp_curve(limiter: CPLimiter) -> void:
	# Show the rider's Critical Power panel for this ride. The box redraws
	# itself from the limiter (curve + live rolling averages + headroom).
	cp_curve_box.set_limiter(limiter)
	cp_panel.visible = limiter != null and limiter.is_active()


func set_minimap_texture(tex: Texture2D) -> void:
	if tex == null:
		minimap_panel.visible = false
		minimap_rect.texture = null
		return
	minimap_rect.texture = tex
	minimap_panel.visible = true
	minimap_marker.visible = false


func set_minimap_uv(u: float, v: float) -> void:
	# Position the rider marker over the displayed image. With
	# STRETCH_KEEP_ASPECT_CENTERED the image is letterboxed inside the
	# TextureRect — compute that sub-rect so the marker lands on the
	# actual map, not the empty letterbox.
	if minimap_rect.texture == null:
		return
	var tex_size: Vector2 = minimap_rect.texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var rect_size: Vector2 = minimap_rect.size
	if rect_size.x <= 0.0 or rect_size.y <= 0.0:
		return
	var scale: float = min(rect_size.x / tex_size.x, rect_size.y / tex_size.y)
	var img_w: float = tex_size.x * scale
	var img_h: float = tex_size.y * scale
	var img_x: float = (rect_size.x - img_w) * 0.5
	var img_y: float = (rect_size.y - img_h) * 0.5
	var px: float = img_x + clamp(u, 0.0, 1.0) * img_w
	var py: float = img_y + clamp(v, 0.0, 1.0) * img_h
	var half := minimap_marker.size * 0.5
	minimap_marker.position = Vector2(px - half.x, py - half.y)
	minimap_marker.visible = true


func hide_minimap() -> void:
	minimap_panel.visible = false
	minimap_rect.texture = null
	minimap_marker.visible = false


func set_leaderboard(entries: Array) -> void:
	# entries: Array of {name, bib, distance_m, is_me}, sorted leader-first.
	for child in leaderboard_list.get_children():
		child.queue_free()
	for i in entries.size():
		var e: Dictionary = entries[i]
		var dist_km: float = float(e.get("distance_m", 0.0)) / 1000.0
		var name_str: String = str(e.get("name", "Rider"))
		var bib: int = int(e.get("bib", 0))
		var is_me: bool = bool(e.get("is_me", false))
		var prefix: String = "#%d " % bib if bib > 0 else ""
		var row := Label.new()
		row.text = "%d. %s%s · %.2f km" % [i + 1, prefix, name_str, dist_km]
		row.add_theme_font_size_override("font_size", 18)
		# Highlight "me" in gold; everyone else uses the configured HUD text
		# colour so the leaderboard matches the rest of the readouts. Same
		# outline as the static labels so rows stay legible at any opacity.
		row.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35) if is_me else _hud_text_color)
		row.add_theme_color_override("font_outline_color", _hud_outline_color)
		row.add_theme_constant_override("outline_size", 3)
		leaderboard_list.add_child(row)
	# Newly-created rows default to capturing the mouse, which would
	# block a drag started over them — let them pass through so the
	# whole panel stays grabbable.
	if leaderboard_panel.has_method("make_content_passthrough"):
		leaderboard_panel.make_content_passthrough()
