class_name CoursePicker
extends CanvasLayer

# Modal course picker. Instantiate, add_child to a parent node, call
# pick(courses) and await the returned Dictionary.

signal _picked(course: Dictionary)


func pick(courses: Array) -> Dictionary:
	_build_ui(courses)
	return await _picked


func _build_ui(courses: Array) -> void:
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
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Choose a course"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	for c in courses:
		var btn := Button.new()
		var course_name: String = str(c.get("name", "Unnamed"))
		var length_km: float = float(c.get("length_m", 0.0)) / 1000.0
		btn.text = "%s · %.1f km" % [course_name, length_km]
		btn.add_theme_font_size_override("font_size", 22)
		btn.custom_minimum_size = Vector2(340, 0)
		var captured: Dictionary = c
		btn.pressed.connect(func() -> void: _picked.emit(captured))
		vbox.add_child(btn)
