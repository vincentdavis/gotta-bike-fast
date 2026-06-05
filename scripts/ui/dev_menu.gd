extends Control

# Dev / staging URL overrides. Edits flow through the DevSettings autoload,
# which also pushes new values into ApiClient and WorldClient so subsequent
# requests use the new origin immediately (no restart needed).

@onready var env_option: OptionButton = $Margin/VBox/EnvRow/EnvOption
@onready var backend_input: LineEdit = $Margin/VBox/BackendInput
@onready var web_input: LineEdit = $Margin/VBox/WebInput
@onready var ws_input: LineEdit = $Margin/VBox/WSInput
@onready var status_label: Label = $Margin/VBox/StatusLabel
@onready var save_button: Button = $Margin/VBox/ButtonRow/SaveButton
@onready var test_button: Button = $Margin/VBox/ButtonRow/TestButton
@onready var reset_button: Button = $Margin/VBox/ButtonRow/ResetButton
@onready var back_button: Button = $Margin/VBox/ButtonRow/BackButton

# Index in the OptionButton == index in this list (built in _ready).
var _env_names: Array = []


func _ready() -> void:
	_build_env_options()
	_populate_from_settings()
	env_option.item_selected.connect(_on_env_selected)
	# Hand-editing a URL means we've diverged from a preset → show CUSTOM.
	backend_input.text_changed.connect(_on_url_edited)
	web_input.text_changed.connect(_on_url_edited)
	ws_input.text_changed.connect(_on_url_edited)
	save_button.pressed.connect(_on_save)
	test_button.pressed.connect(_on_test)
	reset_button.pressed.connect(_on_reset)
	back_button.pressed.connect(_on_back)


func _build_env_options() -> void:
	env_option.clear()
	_env_names = DevSettings.environment_names()
	for name in _env_names:
		env_option.add_item(str(name))


func _populate_from_settings() -> void:
	backend_input.text = DevSettings.base_url
	web_input.text = DevSettings.web_url
	ws_input.text = DevSettings.ws_url
	_select_env_in_dropdown(DevSettings.environment)


func _select_env_in_dropdown(name: String) -> void:
	var idx := _env_names.find(name)
	if idx >= 0:
		env_option.select(idx)


func _on_env_selected(idx: int) -> void:
	var name := str(_env_names[idx])
	if name == DevSettings.CUSTOM:
		status_label.text = "Custom — edit the URLs below and Save."
		return
	# Apply the preset immediately so it's live without a separate Save.
	DevSettings.apply_environment(name)
	backend_input.text = DevSettings.base_url
	web_input.text = DevSettings.web_url
	ws_input.text = DevSettings.ws_url
	status_label.text = "Now using %s." % name


func _on_url_edited(_new_text: String) -> void:
	# Reflect that the current fields may no longer match the selected
	# preset. Doesn't persist until Save.
	_select_env_in_dropdown(DevSettings.CUSTOM)


func _on_save() -> void:
	# set_custom_urls re-detects whether the typed URLs match a known
	# preset and records that env name instead of CUSTOM if so.
	DevSettings.set_custom_urls(
		backend_input.text.strip_edges(),
		web_input.text.strip_edges(),
		ws_input.text.strip_edges(),
	)
	_select_env_in_dropdown(DevSettings.environment)
	status_label.text = "Saved (%s)." % DevSettings.environment


func _on_reset() -> void:
	DevSettings.reset_to_defaults()
	_populate_from_settings()
	status_label.text = "Reset to %s and saved." % DevSettings.DEFAULT_ENV


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
