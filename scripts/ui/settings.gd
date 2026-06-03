extends Control

# Game-side preferences only. Rider profiles (display name, weight, height,
# FTP, aero) and the garage are managed on the web — the in-game UI is
# read-only for those, with a button that links out.

@onready var email_label: Label = $Margin/Scroll/VBox/EmailLabel
@onready var rider_summary: Label = $Margin/Scroll/VBox/RiderSummary
@onready var manage_riders_button: Button = $Margin/Scroll/VBox/ManageRidersButton
@onready var units_option: OptionButton = $Margin/Scroll/VBox/UnitsOption
@onready var music_input: HSlider = $Margin/Scroll/VBox/MusicInput
@onready var sfx_input: HSlider = $Margin/Scroll/VBox/SFXInput
@onready var status_label: Label = $Margin/Scroll/VBox/StatusLabel
@onready var save_button: Button = $Margin/Scroll/VBox/ButtonRow/SaveButton
@onready var back_button: Button = $Margin/Scroll/VBox/ButtonRow/BackButton

var _user: Dictionary = {}


func _ready() -> void:
	units_option.add_item("Metric", 0)
	units_option.add_item("Imperial", 1)

	manage_riders_button.pressed.connect(_on_manage_riders)
	save_button.pressed.connect(_on_save)
	back_button.pressed.connect(_on_back)

	_render_rider_summary()
	_load_user()


func _render_rider_summary() -> void:
	if not GameSession.has_rider():
		rider_summary.text = "(no rider selected)"
		return
	rider_summary.text = "%s · %.1f kg · %.2f m · FTP %d W\n%s" % [
		GameSession.rider_display_name,
		GameSession.rider_weight_kg,
		GameSession.rider_height_m,
		GameSession.rider_ftp_w,
		GameSession.loadout_summary(),
	]


func _load_user() -> void:
	status_label.text = "Loading…"
	_user = await ApiClient.get_me()
	if _user.is_empty():
		status_label.text = "Could not load user"
		return
	email_label.text = (
		"Account: %s · tier %s"
		% [str(_user.get("email", "?")), str(_user.get("tier", "free"))]
	)
	var prefs: Dictionary = _user.get("preferences", {})
	units_option.select(1 if str(prefs.get("units", "metric")) == "imperial" else 0)
	music_input.value = float(prefs.get("music_volume", 0.7))
	sfx_input.value = float(prefs.get("sfx_volume", 0.8))
	status_label.text = ""


func _on_save() -> void:
	save_button.disabled = true
	status_label.text = "Saving…"
	# Only game-side preferences travel through here. Rider profile fields
	# live on Rider records (managed via the web app).
	var prefs: Dictionary = {
		"units": "imperial" if units_option.selected == 1 else "metric",
		"music_volume": float(music_input.value),
		"sfx_volume": float(sfx_input.value),
	}
	var updated: Dictionary = await ApiClient.update_me({"preferences": prefs})
	save_button.disabled = false
	if updated.is_empty():
		status_label.text = "Save failed"
		return
	_user = updated
	status_label.text = "Saved"


func _on_manage_riders() -> void:
	# SSO-bridged so the browser opens as the same user the game is.
	await ApiClient.open_web_link("/riders/")


func _on_back() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
