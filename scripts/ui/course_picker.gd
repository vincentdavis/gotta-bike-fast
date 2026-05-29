class_name CoursePicker
extends CanvasLayer

# Modal course picker with topo-map preview. Instantiate, add_child to a
# parent node, call pick(courses) and await the returned Dictionary.
#
# Two-pane layout: list of courses on the left, hillshaded topo preview
# on the right. Clicking a course selects + previews it; "Start Ride"
# confirms. ESC / "Cancel" returns an empty Dictionary.

signal _picked(course: Dictionary)

var _courses: Array = []
var _selected: Dictionary = {}

var _name_label: Label
var _stats_label: Label
var _topo_rect: TextureRect
var _topo_status: Label
var _start_button: Button
var _topo_request_token: int = 0


func pick(courses: Array) -> Dictionary:
	_courses = courses
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
	vbox.add_theme_constant_override("separation", 14)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Choose a course"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	vbox.add_child(hbox)

	# --- Left: course list ---
	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size = Vector2(280, 380)
	hbox.add_child(list_scroll)

	var list_vbox := VBoxContainer.new()
	list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_vbox.add_theme_constant_override("separation", 6)
	list_scroll.add_child(list_vbox)

	for c in _courses:
		var btn := Button.new()
		var course_name: String = str(c.get("name", "Unnamed"))
		var length_km: float = float(c.get("length_m", 0.0)) / 1000.0
		btn.text = "%s\n%.1f km" % [course_name, length_km]
		btn.add_theme_font_size_override("font_size", 16)
		btn.custom_minimum_size = Vector2(260, 50)
		btn.toggle_mode = true
		var captured: Dictionary = c
		btn.pressed.connect(func() -> void: _select(captured))
		list_vbox.add_child(btn)

	# --- Right: preview pane ---
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	right.custom_minimum_size = Vector2(460, 380)
	hbox.add_child(right)

	_name_label = Label.new()
	_name_label.text = "Select a course to preview"
	_name_label.add_theme_font_size_override("font_size", 22)
	right.add_child(_name_label)

	_stats_label = Label.new()
	_stats_label.text = ""
	_stats_label.add_theme_font_size_override("font_size", 14)
	_stats_label.modulate = Color(0.75, 0.78, 0.85)
	right.add_child(_stats_label)

	var topo_frame := PanelContainer.new()
	topo_frame.custom_minimum_size = Vector2(440, 280)
	# Give the frame a solid dark background so the 3D scene behind the
	# modal doesn't leak through when no topo texture is loaded.
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color(0.08, 0.09, 0.11, 1.0)
	frame_style.border_color = Color(0.20, 0.22, 0.26, 1.0)
	frame_style.border_width_left = 1
	frame_style.border_width_right = 1
	frame_style.border_width_top = 1
	frame_style.border_width_bottom = 1
	topo_frame.add_theme_stylebox_override("panel", frame_style)
	right.add_child(topo_frame)

	_topo_rect = TextureRect.new()
	_topo_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_topo_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_topo_rect.custom_minimum_size = Vector2(440, 280)
	topo_frame.add_child(_topo_rect)

	_topo_status = Label.new()
	_topo_status.text = ""
	_topo_status.add_theme_font_size_override("font_size", 13)
	_topo_status.modulate = Color(0.7, 0.7, 0.75)
	right.add_child(_topo_status)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 12)
	right.add_child(button_row)

	_start_button = Button.new()
	_start_button.text = "Start Ride"
	_start_button.add_theme_font_size_override("font_size", 18)
	_start_button.custom_minimum_size = Vector2(160, 0)
	_start_button.disabled = true
	_start_button.pressed.connect(_on_start)
	button_row.add_child(_start_button)

	var cancel_button := Button.new()
	cancel_button.text = "Cancel"
	cancel_button.add_theme_font_size_override("font_size", 16)
	cancel_button.flat = true
	cancel_button.pressed.connect(func() -> void: _picked.emit({}))
	button_row.add_child(cancel_button)


func _select(course: Dictionary) -> void:
	_selected = course
	var nm: String = str(course.get("name", "?"))
	var length_km: float = float(course.get("length_m", 0.0)) / 1000.0
	_name_label.text = nm
	_stats_label.text = "%.1f km" % length_km
	_start_button.disabled = false
	_topo_rect.texture = null
	_topo_status.text = ""
	var url: String = str(course.get("topo_map_url", ""))
	if url.is_empty():
		_topo_status.text = "(no topo preview available for this course)"
		return
	# Generation-tag the request so a fast-clicker doesn't end up with the
	# wrong preview if responses arrive out of order.
	_topo_request_token += 1
	var my_token := _topo_request_token
	_topo_status.text = "Loading preview…"
	_fetch_topo(url, my_token)


func _fetch_topo(url: String, token: int) -> void:
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		if token == _topo_request_token:
			_topo_status.text = "Preview fetch failed"
		return
	var result: Array = await http.request_completed
	http.queue_free()
	if token != _topo_request_token:
		return  # superseded by a later selection
	var transport: int = result[0]
	var code: int = result[1]
	if transport != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		_topo_status.text = "Preview fetch failed (code %d)" % code
		return
	var img := Image.new()
	var perr := img.load_png_from_buffer(result[3])
	if perr != OK:
		_topo_status.text = "Preview decode failed"
		return
	_topo_rect.texture = ImageTexture.create_from_image(img)
	_topo_status.text = ""


func _on_start() -> void:
	if not _selected.is_empty():
		_picked.emit(_selected)
