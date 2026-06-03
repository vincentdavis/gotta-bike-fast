extends Control

# Dev / staging URL overrides. Edits flow through the DevSettings autoload,
# which also pushes new values into ApiClient and WorldClient so subsequent
# requests use the new origin immediately (no restart needed).

@onready var backend_input: LineEdit = $Margin/VBox/BackendInput
@onready var web_input: LineEdit = $Margin/VBox/WebInput
@onready var ws_input: LineEdit = $Margin/VBox/WSInput
@onready var status_label: Label = $Margin/VBox/StatusLabel
@onready var save_button: Button = $Margin/VBox/ButtonRow/SaveButton
@onready var test_button: Button = $Margin/VBox/ButtonRow/TestButton
@onready var reset_button: Button = $Margin/VBox/ButtonRow/ResetButton
@onready var back_button: Button = $Margin/VBox/ButtonRow/BackButton


func _ready() -> void:
	_populate_from_settings()
	save_button.pressed.connect(_on_save)
	test_button.pressed.connect(_on_test)
	reset_button.pressed.connect(_on_reset)
	back_button.pressed.connect(_on_back)


func _populate_from_settings() -> void:
	backend_input.text = DevSettings.base_url
	web_input.text = DevSettings.web_url
	ws_input.text = DevSettings.ws_url


func _on_save() -> void:
	DevSettings.base_url = backend_input.text.strip_edges()
	DevSettings.web_url = web_input.text.strip_edges()
	DevSettings.ws_url = ws_input.text.strip_edges()
	DevSettings.save()
	status_label.text = "Saved."


func _on_reset() -> void:
	DevSettings.reset_to_defaults()
	DevSettings.save()
	_populate_from_settings()
	status_label.text = "Reset to defaults and saved."


func _on_test() -> void:
	test_button.disabled = true
	status_label.text = "Testing…"
	var backend := backend_input.text.strip_edges()
	var web := web_input.text.strip_edges()

	var backend_ok: bool = await _probe(backend + "/healthz")
	var web_ok: bool = await _probe(web + "/api/docs")

	test_button.disabled = false
	status_label.text = "FastAPI: %s · Django: %s" % [
		"OK" if backend_ok else "FAIL",
		"OK" if web_ok else "FAIL",
	]


func _probe(url: String) -> bool:
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		return false
	var result: Array = await http.request_completed
	http.queue_free()
	var transport: int = result[0]
	var code: int = result[1]
	return transport == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 400


func _on_back() -> void:
	# Return to whoever opened the menu (the System tab sets this before
	# navigating in). Falls back to the unified home page so older entry
	# points don't end up at a blank scene if they forgot to set it.
	var ret := GameSession.dev_menu_return_scene
	if ret.is_empty():
		ret = "res://scenes/main.tscn"
	# Clear the hint so it doesn't bleed into a later, unrelated navigation.
	GameSession.dev_menu_return_scene = ""
	get_tree().change_scene_to_file(ret)
