extends Control

@onready var course_label: Label = $Margin/VBox/CourseLabel
@onready var schedule_label: Label = $Margin/VBox/ScheduleLabel
@onready var share_url: Label = $Margin/VBox/ShareRow/ShareUrl
@onready var copy_button: Button = $Margin/VBox/ShareRow/CopyButton
@onready var riders_list: VBoxContainer = $Margin/VBox/Scroll/RidersList
@onready var status_label: Label = $Margin/VBox/StatusLabel
@onready var start_button: Button = $Margin/VBox/ButtonRow/StartButton
@onready var leave_button: Button = $Margin/VBox/ButtonRow/LeaveButton


func _ready() -> void:
	course_label.text = "Course: %s · %.1f km" % [
		GameSession.course.get("name", "?"),
		float(GameSession.course.get("length_m", 0.0)) / 1000.0,
	]
	if GameSession.game_speed > 1.0:
		# Flag a virtual fast race so riders know before the gun (and trainer
		# riders know they'll be at real time).
		course_label.text += "  ·  ⏩ %s virtual" % (
			("%.1f×" % GameSession.game_speed).replace(".0×", "×")
		)
	share_url.text = "gbf://join/%s" % GameSession.code
	_render_participants(GameSession.participants)

	# Copy-link affordance: an icon button (this font has no emoji, so use an
	# imported SVG glyph) sitting right beside the link.
	copy_button.icon = load("res://branding/copy_icon.svg")
	copy_button.text = ""
	copy_button.tooltip_text = "Copy invite link"
	copy_button.pressed.connect(_on_copy_pressed)
	start_button.pressed.connect(_on_start_pressed)
	leave_button.pressed.connect(_on_leave_pressed)

	if GameSession.is_host():
		if GameSession.scheduled_start_at_unix_s > 0.0:
			start_button.text = "Start Now (skip schedule)"
		else:
			start_button.text = "Start Race"
		start_button.disabled = false
		status_label.text = ""
	else:
		start_button.text = "Waiting for host…"
		start_button.disabled = true
		status_label.text = ""

	_update_schedule_label()

	WorldClient.lobby_update.connect(_on_lobby_update)
	WorldClient.countdown_started.connect(_on_countdown_started)
	WorldClient.race_ended.connect(_on_race_ended)
	WorldClient.connect_to_game(GameSession.code, GameSession.rider_id)


func _process(_delta: float) -> void:
	if GameSession.scheduled_start_at_unix_s > 0.0:
		_update_schedule_label()


func _update_schedule_label() -> void:
	if GameSession.scheduled_start_at_unix_s <= 0.0:
		schedule_label.text = ""
		return
	var remaining: float = (
		GameSession.scheduled_start_at_unix_s - Time.get_unix_time_from_system()
	)
	if remaining <= 0.0:
		schedule_label.text = "Race starting…"
		return
	var hh: int = int(remaining) / 3600
	var mm: int = (int(remaining) % 3600) / 60
	var ss: int = int(remaining) % 60
	if hh > 0:
		schedule_label.text = "Race starts in %d:%02d:%02d" % [hh, mm, ss]
	else:
		schedule_label.text = "Race starts in %d:%02d" % [mm, ss]


func _exit_tree() -> void:
	# Auto-disconnect happens, but be explicit so re-entering doesn't double-bind.
	if WorldClient.lobby_update.is_connected(_on_lobby_update):
		WorldClient.lobby_update.disconnect(_on_lobby_update)
	if WorldClient.countdown_started.is_connected(_on_countdown_started):
		WorldClient.countdown_started.disconnect(_on_countdown_started)
	if WorldClient.race_ended.is_connected(_on_race_ended):
		WorldClient.race_ended.disconnect(_on_race_ended)


func _render_participants(participants: Array) -> void:
	for child in riders_list.get_children():
		child.queue_free()
	for p in participants:
		var row := Label.new()
		var name: String = str(p.get("display_name", "?"))
		var is_host: bool = str(p.get("rider_id", "")) == GameSession.host_rider_id
		row.text = "• %s%s" % [name, "  (host)" if is_host else ""]
		row.add_theme_font_size_override("font_size", 20)
		riders_list.add_child(row)


func _on_lobby_update(participants: Array) -> void:
	GameSession.participants = participants
	_render_participants(participants)


func _on_countdown_started(_countdown_starts_at: String, race_starts_at: String) -> void:
	GameSession.state = "COUNTDOWN"
	GameSession.race_starts_at_unix_s = _parse_iso_to_unix(race_starts_at)
	get_tree().change_scene_to_file("res://scenes/ride.tscn")


func _on_race_ended(reason: String) -> void:
	status_label.text = "Game ended: %s" % reason
	# Bounce back to menu after a moment.
	await get_tree().create_timer(1.5).timeout
	if is_inside_tree():
		WorldClient.disconnect_now()
		GameSession.reset()
		get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_copy_pressed() -> void:
	var link := share_url.text
	DisplayServer.clipboard_set(link)
	if OS.has_feature("web"):
		# Godot's clipboard_set is unreliable in the browser, so also write via
		# the JS Clipboard API. A button press is a valid user gesture and the
		# hosted page is HTTPS (a secure context), so this is allowed.
		JavaScriptBridge.eval(
			"navigator.clipboard && navigator.clipboard.writeText(%s)" % JSON.stringify(link),
			true,
		)
	status_label.text = "Link copied"
	copy_button.modulate = Color(0.55, 1.0, 0.65)  # brief green flash for feedback
	await get_tree().create_timer(1.0).timeout
	if is_instance_valid(copy_button):
		copy_button.modulate = Color.WHITE


func _on_start_pressed() -> void:
	if not GameSession.is_host():
		return
	start_button.disabled = true
	status_label.text = "Starting…"
	var result: Dictionary = await ApiClient.start_game(GameSession.code, GameSession.rider_id)
	if result.is_empty():
		start_button.disabled = false
		status_label.text = "Failed to start"


func _on_leave_pressed() -> void:
	leave_button.disabled = true
	start_button.disabled = true
	status_label.text = "Leaving…"
	await ApiClient.leave_game(GameSession.code, GameSession.rider_id)
	WorldClient.disconnect_now()
	GameSession.reset()
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _parse_iso_to_unix(iso_str: String) -> float:
	# Backend ISO is YYYY-MM-DDTHH:MM:SS.microseconds (no Z; SQLite drops tz).
	# Strip fractional seconds and treat as UTC.
	var clean := iso_str.split(".")[0]
	var dict := Time.get_datetime_dict_from_datetime_string(clean, true)
	if dict.is_empty():
		return Time.get_unix_time_from_system()
	return float(Time.get_unix_time_from_datetime_dict(dict))
