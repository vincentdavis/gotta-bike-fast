class_name CountdownPicker
extends CanvasLayer

# Picks both the countdown duration and an optional scheduled start.
# Returns a Dictionary:
#   { "countdown_duration_s": int, "scheduled_start_in_s": int }
# where scheduled_start_in_s == -1 means "host starts manually".

signal _picked(result: Dictionary)

# [label, countdown_s, scheduled_in_s]   scheduled = -1 → manual
const OPTIONS: Array = [
	["Start manually · 10 s countdown", 10, -1],
	["Start manually · 30 s countdown (default)", 30, -1],
	["Start manually · 1 min countdown", 60, -1],
	["Scheduled · in 5 min · 30 s countdown", 30, 300],
	["Scheduled · in 15 min · 30 s countdown", 30, 900],
	["Scheduled · in 30 min · 30 s countdown", 30, 1800],
	["Scheduled · in 1 hour · 30 s countdown", 30, 3600],
]


func pick() -> Dictionary:
	_build_ui()
	return await _picked


func _build_ui() -> void:
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
	title.text = "When does the race start?"
	title.add_theme_font_size_override("font_size", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	vbox.add_child(spacer)

	for opt in OPTIONS:
		var btn := Button.new()
		btn.text = opt[0]
		btn.add_theme_font_size_override("font_size", 20)
		btn.custom_minimum_size = Vector2(420, 0)
		var captured: Dictionary = {
			"countdown_duration_s": int(opt[1]),
			"scheduled_start_in_s": int(opt[2]),
		}
		btn.pressed.connect(func() -> void: _picked.emit(captured))
		vbox.add_child(btn)
