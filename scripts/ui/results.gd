extends Control

const REFRESH_INTERVAL_S := 3.0

@onready var course_label: Label = $Margin/VBox/CourseLabel
@onready var status_label: Label = $Margin/VBox/StatusLabel
@onready var rows: VBoxContainer = $Margin/VBox/Scroll/Rows
@onready var refresh_button: Button = $Margin/VBox/ButtonRow/RefreshButton
@onready var back_button: Button = $Margin/VBox/ButtonRow/BackButton

var _polling: bool = true


func _ready() -> void:
	course_label.text = "Course: %s · %.1f km" % [
		GameSession.course.get("name", "?"),
		float(GameSession.course.get("length_m", 0.0)) / 1000.0,
	]
	refresh_button.pressed.connect(_refresh)
	back_button.pressed.connect(_on_back)
	WorldClient.disconnect_now()  # we no longer need the game socket
	_refresh()
	_poll_loop()


func _exit_tree() -> void:
	_polling = false


func _poll_loop() -> void:
	while _polling and is_inside_tree():
		await get_tree().create_timer(REFRESH_INTERVAL_S).timeout
		if _polling and is_inside_tree():
			await _refresh()


func _refresh() -> void:
	status_label.text = "Updating…"
	var results: Array = await ApiClient.list_game_results(GameSession.code)
	if not is_inside_tree():
		return
	_render(results)
	status_label.text = ""


func _render(results: Array) -> void:
	for child in rows.get_children():
		child.queue_free()
	if results.is_empty():
		var none := Label.new()
		none.text = "(no results yet)"
		none.add_theme_font_size_override("font_size", 18)
		rows.add_child(none)
		return
	for i in results.size():
		var r: Dictionary = results[i]
		rows.add_child(_build_row(i + 1, r))


func _build_row(rank: int, r: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var is_me: bool = str(r.get("rider_id", "")) == GameSession.rider_id
	var color := Color(1.0, 0.85, 0.35) if is_me else Color(1.0, 1.0, 1.0)

	row.add_child(_label("%d" % rank, 48, color))
	row.add_child(_label("#%d" % int(r.get("bib_number", 0)), 80, color))

	var name_lbl := _label(str(r.get("display_name", "?")), 0, color)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)

	row.add_child(
		_label(
			"%.2f km" % (float(r.get("distance_m", 0.0)) / 1000.0), 120, color
		)
	)

	var dur: int = int(float(r.get("duration_s", 0.0)))
	row.add_child(
		_label("%d:%02d" % [dur / 60, dur % 60], 100, color)
	)

	var avg_w: int = int(round(float(r.get("avg_power_w", 0.0))))
	var max_w: int = int(round(float(r.get("max_power_w", 0.0))))
	row.add_child(_label("%d / %d" % [avg_w, max_w], 120, color))

	var status_str: String = "DONE" if bool(r.get("finished", false)) else "racing…"
	var status_color := (
		Color(0.5, 1.0, 0.5)
		if bool(r.get("finished", false))
		else Color(0.7, 0.7, 0.7)
	)
	row.add_child(_label(status_str, 90, status_color))

	return row


func _label(text: String, min_width: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", color)
	if min_width > 0:
		l.custom_minimum_size = Vector2(min_width, 0)
	return l


func _on_back() -> void:
	_polling = false
	GameSession.reset()
	get_tree().change_scene_to_file("res://scenes/main.tscn")
