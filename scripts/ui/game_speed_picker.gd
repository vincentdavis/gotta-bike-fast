class_name GameSpeedPicker
extends CanvasLayer

# Picks the race time-scale for a group ride the host is creating. Returns a
# float multiplier (1.0 = real time). The value rides along on the game and
# every client applies it — but only on keyboard (virtual) riders; anyone on a
# real power meter / trainer races at real time so their effort isn't distorted.
# Mirrors CountdownPicker's modal style.

signal _picked(speed: float)

# [label, multiplier]
const OPTIONS: Array = [
	["1× · real time (default)", 1.0],
	["1.5× · brisk", 1.5],
	["2× · fast", 2.0],
	["3× · very fast", 3.0],
	["4× · time-lapse", 4.0],
]


func pick(default_speed: float = 1.0) -> float:
	_build_ui(default_speed)
	return await _picked


func _build_ui(default_speed: float) -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.65)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Race speed (virtual rides)"
	title.add_theme_font_size_override("font_size", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var sub := Label.new()
	sub.text = "Runs the whole race faster. Riders on a trainer / power meter\nstay at real time. Default suggested from your settings."
	sub.add_theme_font_size_override("font_size", 14)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(0.78, 0.78, 0.78)
	vbox.add_child(sub)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	vbox.add_child(spacer)

	for opt in OPTIONS:
		var btn := Button.new()
		var speed := float(opt[1])
		btn.text = opt[0]
		if is_equal_approx(speed, default_speed):
			btn.text += "   ◀ current"
		btn.add_theme_font_size_override("font_size", 20)
		btn.custom_minimum_size = Vector2(420, 0)
		btn.pressed.connect(func() -> void: _picked.emit(speed))
		vbox.add_child(btn)
