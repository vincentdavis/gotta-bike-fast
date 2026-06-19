extends CanvasLayer

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


func _process(delta: float) -> void:
	if _camera_toast_t > 0.0:
		_camera_toast_t -= delta
		if _camera_toast_t <= 0.0:
			camera_label.modulate.a = 0.0
		elif _camera_toast_t < CAMERA_TOAST_FADE_S:
			camera_label.modulate.a = _camera_toast_t / CAMERA_TOAST_FADE_S


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
