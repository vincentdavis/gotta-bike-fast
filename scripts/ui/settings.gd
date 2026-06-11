extends Control

# Game-side preferences only. Rider profiles (display name, weight, height,
# FTP, aero) and the garage are managed on the web — the in-game UI is
# read-only for those, with a button that links out.

@onready var email_label: Label = $Margin/Scroll/VBox/EmailLabel
@onready var rider_summary: Label = $Margin/Scroll/VBox/RiderSummary
@onready var manage_riders_button: Button = $Margin/Scroll/VBox/ManageRidersButton
@onready var units_option: OptionButton = $Margin/Scroll/VBox/UnitsOption
@onready var quality_option: OptionButton = $Margin/Scroll/VBox/QualityOption
@onready var scale_label: Label = $Margin/Scroll/VBox/ScaleLabel
@onready var scale_slider: HSlider = $Margin/Scroll/VBox/ScaleSlider
@onready var frame_option: OptionButton = $Margin/Scroll/VBox/FrameOption
@onready var fullscreen_check: CheckBox = $Margin/Scroll/VBox/FullscreenCheck
@onready var show_fps_check: CheckBox = $Margin/Scroll/VBox/ShowFPSCheck
@onready var hud_bg_picker: ColorPickerButton = $Margin/Scroll/VBox/HudBgColorPicker
@onready var hud_opacity_label: Label = $Margin/Scroll/VBox/HudOpacityLabel
@onready var hud_opacity_slider: HSlider = $Margin/Scroll/VBox/HudOpacitySlider
@onready var hud_text_picker: ColorPickerButton = $Margin/Scroll/VBox/HudTextColorPicker
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

	_setup_graphics_controls()
	_render_rider_summary()
	_load_user()


# --- Graphics (device-local; applied + saved immediately, no Save needed) ---

func _setup_graphics_controls() -> void:
	# Item index == enum value for the option buttons.
	quality_option.add_item("Low", GraphicsSettings.Quality.LOW)
	quality_option.add_item("Medium", GraphicsSettings.Quality.MEDIUM)
	quality_option.add_item("High", GraphicsSettings.Quality.HIGH)
	quality_option.select(GraphicsSettings.quality)
	quality_option.item_selected.connect(
		func(idx: int) -> void: GraphicsSettings.set_quality(idx)
	)

	scale_slider.value = GraphicsSettings.render_scale
	_update_scale_label(GraphicsSettings.render_scale)
	scale_slider.value_changed.connect(_on_scale_changed)

	frame_option.add_item("VSync (match display)", GraphicsSettings.FrameLimit.VSYNC)
	frame_option.add_item("60 fps", GraphicsSettings.FrameLimit.FPS_60)
	frame_option.add_item("30 fps (quiet)", GraphicsSettings.FrameLimit.FPS_30)
	frame_option.add_item("Uncapped", GraphicsSettings.FrameLimit.UNCAPPED)
	frame_option.select(GraphicsSettings.frame_limit)
	frame_option.item_selected.connect(
		func(idx: int) -> void: GraphicsSettings.set_frame_limit(idx)
	)

	fullscreen_check.button_pressed = GraphicsSettings.fullscreen
	fullscreen_check.toggled.connect(
		func(on: bool) -> void: GraphicsSettings.set_fullscreen(on)
	)

	show_fps_check.button_pressed = GraphicsSettings.show_fps
	show_fps_check.toggled.connect(
		func(on: bool) -> void: GraphicsSettings.set_show_fps(on)
	)

	# HUD appearance — background colour + opacity + text colour, shared by the
	# stats panel, leaderboard, and minimap. Applies on the next ride.
	hud_bg_picker.color = GraphicsSettings.hud_bg_color
	hud_bg_picker.color_changed.connect(
		func(c: Color) -> void: GraphicsSettings.set_hud_bg_color(c)
	)

	hud_opacity_slider.value = GraphicsSettings.hud_bg_opacity
	_update_hud_opacity_label(GraphicsSettings.hud_bg_opacity)
	hud_opacity_slider.value_changed.connect(_on_hud_opacity_changed)

	hud_text_picker.color = GraphicsSettings.hud_text_color
	hud_text_picker.color_changed.connect(
		func(c: Color) -> void: GraphicsSettings.set_hud_text_color(c)
	)


func _on_hud_opacity_changed(value: float) -> void:
	GraphicsSettings.set_hud_bg_opacity(value)
	_update_hud_opacity_label(value)


func _update_hud_opacity_label(value: float) -> void:
	hud_opacity_label.text = "Panel opacity: %d%%" % int(round(value * 100.0))


func _on_scale_changed(value: float) -> void:
	GraphicsSettings.set_render_scale(value)
	_update_scale_label(value)


func _update_scale_label(value: float) -> void:
	scale_label.text = "Render scale: %d%%" % int(round(value * 100.0))


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
	get_tree().change_scene_to_file("res://scenes/main.tscn")
