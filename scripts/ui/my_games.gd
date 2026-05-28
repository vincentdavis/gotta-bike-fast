extends Control

@onready var refresh_button: Button = $Margin/VBox/Header/RefreshButton
@onready var games_list: VBoxContainer = $Margin/VBox/Scroll/GamesList
@onready var status_label: Label = $Margin/VBox/StatusLabel
@onready var back_button: Button = $Margin/VBox/BackButton


func _ready() -> void:
	refresh_button.pressed.connect(_refresh)
	back_button.pressed.connect(_on_back)
	if GameSession.rider_id.is_empty():
		status_label.text = "No rider yet — create or join a game first."
		return
	_refresh()


func _refresh() -> void:
	status_label.text = "Loading…"
	var games: Array = await ApiClient.list_my_games(GameSession.rider_id)
	if not is_inside_tree():
		return
	status_label.text = ""
	_render(games)


func _render(games: Array) -> void:
	for child in games_list.get_children():
		child.queue_free()
	if games.is_empty():
		var empty := Label.new()
		empty.text = "(no games yet — host or join one to see it here)"
		empty.add_theme_font_size_override("font_size", 18)
		games_list.add_child(empty)
		return
	for g in games:
		games_list.add_child(_build_row(g))


func _build_row(game: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	margin.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info)

	var state_str: String = str(game.get("state", ""))
	var role: String = "host" if bool(game.get("is_host", false)) else "joined"

	var line1 := Label.new()
	line1.text = "%s · %s · %s" % [
		str(game.get("course_name", "?")),
		state_str,
		role,
	]
	line1.add_theme_font_size_override("font_size", 20)
	info.add_child(line1)

	var line2 := Label.new()
	var n: int = int(game.get("participant_count", 0))
	var scheduled_iso: String = str(game.get("scheduled_start_at", ""))
	var sched_part := ""
	if not scheduled_iso.is_empty() and scheduled_iso != "<null>":
		sched_part = " · scheduled %s" % _short_time(scheduled_iso)
	line2.text = "code %s · %d rider%s%s" % [
		str(game.get("code", "")),
		n,
		"" if n == 1 else "s",
		sched_part,
	]
	line2.add_theme_font_size_override("font_size", 16)
	info.add_child(line2)

	var btn := Button.new()
	if state_str == "LOBBY":
		btn.text = "Enter"
	else:
		btn.text = state_str
		btn.disabled = true
	btn.add_theme_font_size_override("font_size", 18)
	var captured_code: String = str(game.get("code", ""))
	btn.pressed.connect(func() -> void: _enter(captured_code))
	hbox.add_child(btn)
	return panel


func _short_time(iso: String) -> String:
	var clean := iso.split(".")[0]
	var dict := Time.get_datetime_dict_from_datetime_string(clean, true)
	if dict.is_empty():
		return iso
	return "%02d:%02d" % [int(dict.get("hour", 0)), int(dict.get("minute", 0))]


func _enter(code: String) -> void:
	status_label.text = "Re-joining %s…" % code
	var game: Dictionary = await ApiClient.join_game(code, GameSession.rider_id)
	if game.is_empty():
		status_label.text = "Could not enter %s" % code
		return

	GameSession.code = str(game["code"])
	GameSession.host_rider_id = str(game["host_rider_id"])
	GameSession.course = {
		"id": str(game["course_id"]),
		"name": game.get("course_name", ""),
		"length_m": float(game.get("course_length_m", 0.0)),
	}
	GameSession.participants = game.get("participants", [])
	GameSession.state = str(game.get("state", "LOBBY"))
	GameSession.scheduled_start_at_unix_s = GameSession.parse_iso_to_unix(
		str(game.get("scheduled_start_at", ""))
	)
	GameSession.is_solo = false
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")


func _on_back() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
