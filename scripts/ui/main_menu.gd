extends Control

@onready var solo_button: Button = $Center/VBox/SoloButton
@onready var create_button: Button = $Center/VBox/CreateButton
@onready var join_button: Button = $Center/VBox/JoinButton
@onready var my_games_button: Button = $Center/VBox/MyGamesButton
@onready var switch_rider_button: Button = $Center/VBox/SwitchRiderButton
@onready var settings_button: Button = $Center/VBox/SettingsButton
@onready var dev_button: Button = $Center/VBox/DevButton
@onready var logout_button: Button = $Center/VBox/LogoutButton
@onready var status_label: Label = $Center/VBox/StatusLabel
@onready var rider_label: Label = $Center/VBox/RiderLabel

var _busy: bool = false


func _ready() -> void:
	if not ApiClient.is_authenticated():
		get_tree().change_scene_to_file("res://scenes/login.tscn")
		return
	if not GameSession.has_rider():
		get_tree().change_scene_to_file("res://scenes/riders.tscn")
		return

	solo_button.pressed.connect(_on_solo_pressed)
	create_button.pressed.connect(_on_create_pressed)
	join_button.pressed.connect(_on_join_pressed)
	my_games_button.pressed.connect(_on_my_games_pressed)
	switch_rider_button.pressed.connect(_on_switch_rider_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	dev_button.pressed.connect(_on_dev_pressed)
	logout_button.pressed.connect(_on_logout_pressed)

	rider_label.text = "Riding as %s" % GameSession.rider_display_name
	# Wipe any leftover game state from a previous session, but keep the
	# picked rider so the menu reflects it.
	GameSession.reset()


func _set_busy(busy: bool, message: String = "") -> void:
	_busy = busy
	solo_button.disabled = busy
	create_button.disabled = busy
	join_button.disabled = busy
	my_games_button.disabled = busy
	switch_rider_button.disabled = busy
	settings_button.disabled = busy
	dev_button.disabled = busy
	logout_button.disabled = busy
	status_label.text = message


func _on_solo_pressed() -> void:
	if _busy:
		return
	GameSession.is_solo = true
	get_tree().change_scene_to_file("res://scenes/ride.tscn")


func _on_create_pressed() -> void:
	if _busy:
		return
	_set_busy(true, "Loading courses…")

	var courses: Array = await ApiClient.list_courses()
	if courses.is_empty():
		_set_busy(false, "No courses available")
		return

	var picker := CoursePicker.new()
	add_child(picker)
	var chosen: Dictionary = await picker.pick(courses)
	picker.queue_free()

	var cd_picker := CountdownPicker.new()
	add_child(cd_picker)
	var start_opt: Dictionary = await cd_picker.pick()
	cd_picker.queue_free()

	_set_busy(true, "Creating game…")
	var game: Dictionary = await ApiClient.create_game(
		GameSession.rider_id,
		GameSession.rider_display_name,
		str(chosen["id"]),
		int(start_opt.get("countdown_duration_s", 30)),
		int(start_opt.get("scheduled_start_in_s", -1)),
	)
	if game.is_empty():
		_set_busy(false, "Failed to create game")
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


func _on_join_pressed() -> void:
	if _busy:
		return
	get_tree().change_scene_to_file("res://scenes/join.tscn")


func _on_my_games_pressed() -> void:
	if _busy:
		return
	get_tree().change_scene_to_file("res://scenes/my_games.tscn")


func _on_switch_rider_pressed() -> void:
	if _busy:
		return
	get_tree().change_scene_to_file("res://scenes/riders.tscn")


func _on_settings_pressed() -> void:
	if _busy:
		return
	get_tree().change_scene_to_file("res://scenes/settings.tscn")


func _on_dev_pressed() -> void:
	if _busy:
		return
	get_tree().change_scene_to_file("res://scenes/dev_menu.tscn")


func _on_logout_pressed() -> void:
	if _busy:
		return
	ApiClient.logout()
	GameSession.clear_rider()
	GameSession.reset()
	get_tree().change_scene_to_file("res://scenes/login.tscn")
