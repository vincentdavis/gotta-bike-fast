extends Control

const REFRESH_INTERVAL_S := 3.0

@onready var code_input: LineEdit = $Margin/VBox/CodeRow/CodeInput
@onready var join_code_button: Button = $Margin/VBox/CodeRow/JoinCodeButton
@onready var refresh_button: Button = $Margin/VBox/ListHeader/RefreshButton
@onready var games_list: VBoxContainer = $Margin/VBox/Scroll/GamesList
@onready var status_label: Label = $Margin/VBox/StatusLabel
@onready var back_button: Button = $Margin/VBox/BackButton

var _polling: bool = true


func _ready() -> void:
	join_code_button.pressed.connect(_on_join_code_pressed)
	refresh_button.pressed.connect(_refresh_now)
	back_button.pressed.connect(_on_back_pressed)
	code_input.text_submitted.connect(_on_code_submitted)

	_refresh_now()
	_poll_loop()


func _exit_tree() -> void:
	_polling = false


func _poll_loop() -> void:
	while _polling and is_inside_tree():
		await get_tree().create_timer(REFRESH_INTERVAL_S).timeout
		if _polling and is_inside_tree():
			await _refresh_now()


func _refresh_now() -> void:
	var games: Array = await ApiClient.list_games()
	if not is_inside_tree():
		return
	_render_games(games)


func _render_games(games: Array) -> void:
	for child in games_list.get_children():
		child.queue_free()
	if games.is_empty():
		var none := Label.new()
		none.text = "(no open games right now)"
		none.add_theme_font_size_override("font_size", 18)
		games_list.add_child(none)
		return
	for g in games:
		var row := _build_game_row(g)
		games_list.add_child(row)


func _build_game_row(game: Dictionary) -> PanelContainer:
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

	var line1 := Label.new()
	line1.text = "%s · hosted by %s" % [
		str(game.get("course_name", "?")),
		str(game.get("host_display_name", "?")),
	]
	line1.add_theme_font_size_override("font_size", 20)
	info.add_child(line1)

	var line2 := Label.new()
	var n: int = int(game.get("participant_count", 0))
	line2.text = "%d rider%s · code %s" % [n, "" if n == 1 else "s", str(game.get("code", ""))]
	line2.add_theme_font_size_override("font_size", 16)
	info.add_child(line2)

	var btn := Button.new()
	btn.text = "Join"
	btn.add_theme_font_size_override("font_size", 20)
	var captured_code: String = str(game.get("code", ""))
	btn.pressed.connect(func() -> void: _join_with_code(captured_code))
	hbox.add_child(btn)
	return panel


func _on_join_code_pressed() -> void:
	_join_with_code(code_input.text)


func _on_code_submitted(_text: String) -> void:
	_join_with_code(code_input.text)


func _join_with_code(raw: String) -> void:
	var code := _normalize_code(raw)
	if code.is_empty():
		status_label.text = "Enter a valid code"
		return
	if not GameSession.has_rider():
		status_label.text = "Pick a rider first"
		return
	status_label.text = "Joining %s…" % code

	var game: Dictionary = await ApiClient.join_game(
		code, GameSession.rider_id, GameSession.rider_display_name
	)
	if game.is_empty():
		status_label.text = "Could not join %s" % code
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
	_polling = false
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")


func _normalize_code(raw: String) -> String:
	var s := raw.strip_edges().to_upper()
	# Accept full URL form (gbf://join/CODE) by taking the last path segment.
	if "/" in s:
		s = s.split("/")[-1]
	return s


func _on_back_pressed() -> void:
	_polling = false
	get_tree().change_scene_to_file("res://scenes/main.tscn")
