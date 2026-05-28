extends Control

const DEFAULT_RIDER_NAME := "Anonymous"
const DEFAULT_RIDER_WEIGHT_KG := 75.0
const DEFAULT_RIDER_HEIGHT_M := 1.75
const DEFAULT_RIDER_FTP_W := 200

@onready var solo_button: Button = $Center/VBox/SoloButton
@onready var create_button: Button = $Center/VBox/CreateButton
@onready var join_button: Button = $Center/VBox/JoinButton
@onready var my_games_button: Button = $Center/VBox/MyGamesButton
@onready var status_label: Label = $Center/VBox/StatusLabel

var _busy: bool = false


func _ready() -> void:
	solo_button.pressed.connect(_on_solo_pressed)
	create_button.pressed.connect(_on_create_pressed)
	join_button.pressed.connect(_on_join_pressed)
	my_games_button.pressed.connect(_on_my_games_pressed)
	# Preserve rider_id across menu visits so "My Games" can find them.
	var saved_rider_id := GameSession.rider_id
	GameSession.reset()
	GameSession.rider_id = saved_rider_id


func _set_busy(busy: bool, message: String = "") -> void:
	_busy = busy
	solo_button.disabled = busy
	create_button.disabled = busy
	join_button.disabled = busy
	my_games_button.disabled = busy
	status_label.text = message


func _ensure_rider() -> String:
	if not GameSession.rider_id.is_empty():
		return GameSession.rider_id
	var rider: Dictionary = await ApiClient.create_rider(
		DEFAULT_RIDER_NAME,
		DEFAULT_RIDER_WEIGHT_KG,
		DEFAULT_RIDER_HEIGHT_M,
		DEFAULT_RIDER_FTP_W,
	)
	if rider.is_empty():
		return ""
	GameSession.rider_id = str(rider["id"])
	return GameSession.rider_id


func _on_solo_pressed() -> void:
	if _busy:
		return
	GameSession.is_solo = true
	get_tree().change_scene_to_file("res://scenes/ride.tscn")


func _on_create_pressed() -> void:
	if _busy:
		return
	_set_busy(true, "Loading courses…")

	var rider_id := await _ensure_rider()
	if rider_id.is_empty():
		_set_busy(false, "Failed to create rider")
		return

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
		rider_id,
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
	_set_busy(true, "Checking rider…")
	var rider_id := await _ensure_rider()
	_set_busy(false, "")
	if rider_id.is_empty():
		status_label.text = "Could not create rider"
		return
	get_tree().change_scene_to_file("res://scenes/my_games.tscn")
