extends CanvasLayer

@onready var power_label: Label = $VBox/PowerLabel
@onready var speed_label: Label = $VBox/SpeedLabel
@onready var distance_label: Label = $VBox/DistanceLabel
@onready var lap_label: Label = $VBox/LapLabel
@onready var grade_label: Label = $VBox/GradeLabel
@onready var time_label: Label = $VBox/TimeLabel
@onready var draft_label: Label = $VBox/DraftLabel
@onready var course_label: Label = $VBox/CourseLabel
@onready var status_label: Label = $VBox/StatusLabel
@onready var countdown_label: Label = $CountdownLabel
@onready var leaderboard_panel: PanelContainer = $LeaderboardPanel
@onready var leaderboard_list: VBoxContainer = $LeaderboardPanel/Margin/VBox/Scroll/List
@onready var minimap_panel: PanelContainer = $MinimapPanel
@onready var minimap_box: Control = $MinimapPanel/Margin/VBox/MapBox
@onready var minimap_rect: TextureRect = $MinimapPanel/Margin/VBox/MapBox/MinimapRect
@onready var minimap_marker: ColorRect = $MinimapPanel/Margin/VBox/MapBox/RiderMarker


func set_power(w: float) -> void:
	power_label.text = "Power: %d W" % int(round(w))


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
		draft_label.remove_theme_color_override("font_color")


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
		if is_me:
			row.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
		leaderboard_list.add_child(row)
	# Newly-created rows default to capturing the mouse, which would
	# block a drag started over them — let them pass through so the
	# whole panel stays grabbable.
	if leaderboard_panel.has_method("make_content_passthrough"):
		leaderboard_panel.make_content_passthrough()
