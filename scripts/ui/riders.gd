extends Control

# Read-only rider picker. Editing happens in the web app (Django) — this
# screen lists what's there, lets the user pick one, and opens the browser
# for creating or editing.

@onready var riders_list: VBoxContainer = $Margin/VBox/Scroll/RidersList
@onready var status_label: Label = $Margin/VBox/StatusLabel
@onready var manage_button: Button = $Margin/VBox/ButtonRow/ManageButton
@onready var refresh_button: Button = $Margin/VBox/ButtonRow/RefreshButton
@onready var logout_button: Button = $Margin/VBox/ButtonRow/LogoutButton

var _busy: bool = false


func _ready() -> void:
	if not ApiClient.is_authenticated():
		get_tree().change_scene_to_file("res://scenes/login.tscn")
		return

	manage_button.pressed.connect(_on_manage_pressed)
	refresh_button.pressed.connect(_refresh)
	logout_button.pressed.connect(_on_logout_pressed)

	# Refresh automatically when this window regains focus (likely after
	# the user returns from creating a rider in the browser).
	get_tree().root.focus_entered.connect(_on_window_focus)

	_refresh()


func _exit_tree() -> void:
	if get_tree() != null and get_tree().root.focus_entered.is_connected(_on_window_focus):
		get_tree().root.focus_entered.disconnect(_on_window_focus)


func _on_window_focus() -> void:
	if not _busy and is_inside_tree():
		_refresh()


func _refresh() -> void:
	_set_busy(true, "Loading…")
	var riders: Array = await ApiClient.list_riders()
	_set_busy(false, "")
	if not is_inside_tree():
		return
	_render(riders)


func _set_busy(busy: bool, message: String) -> void:
	_busy = busy
	manage_button.disabled = busy
	refresh_button.disabled = busy
	logout_button.disabled = busy
	status_label.text = message


func _render(riders: Array) -> void:
	for child in riders_list.get_children():
		child.queue_free()
	if riders.is_empty():
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 8)

		var empty := Label.new()
		empty.text = "No riders yet."
		empty.add_theme_font_size_override("font_size", 18)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(empty)

		var hint := Label.new()
		hint.text = (
			"Click 'Manage Riders & Garage (web)' below to create one in the browser."
		)
		hint.add_theme_font_size_override("font_size", 14)
		hint.modulate = Color(0.8, 0.8, 0.8)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(hint)

		riders_list.add_child(box)
		return
	for r in riders:
		riders_list.add_child(_build_row(r))


func _build_row(rider: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	margin.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = "%s · %s" % [
		str(rider.get("display_name", "?")),
		str(rider.get("rider_type", "virtual")).capitalize(),
	]
	name_lbl.add_theme_font_size_override("font_size", 22)
	info.add_child(name_lbl)

	var stats := Label.new()
	stats.text = "%.1f kg · %.2f m · FTP %d W" % [
		float(rider.get("weight_kg", 0.0)),
		float(rider.get("height_m", 0.0)),
		int(rider.get("ftp_w", 0)),
	]
	stats.add_theme_font_size_override("font_size", 16)
	info.add_child(stats)

	var loadout := Label.new()
	loadout.text = _loadout_line(rider)
	loadout.add_theme_font_size_override("font_size", 14)
	loadout.modulate = Color(0.75, 0.78, 0.85)
	info.add_child(loadout)

	var select_btn := Button.new()
	select_btn.text = "Select"
	select_btn.add_theme_font_size_override("font_size", 18)
	select_btn.custom_minimum_size = Vector2(130, 0)
	var captured := rider.duplicate()
	select_btn.pressed.connect(func() -> void: _select(captured))
	hbox.add_child(select_btn)

	return panel


func _loadout_line(rider: Dictionary) -> String:
	# "Bike: <name> · Wheels: <name> · Tires: <name>" with "stock" for any
	# slot the rider hasn't equipped yet. Dictionary.get returns Variant,
	# so type each slot explicitly to satisfy the GDScript inference
	# warning being treated as an error.
	var bike: Variant = rider.get("bike")
	var wheels: Variant = rider.get("wheels")
	var tires: Variant = rider.get("tires")
	var b: String = "stock"
	var w: String = "stock"
	var t: String = "stock"
	if bike is Dictionary:
		b = str((bike as Dictionary).get("name", "stock"))
	if wheels is Dictionary:
		w = str((wheels as Dictionary).get("name", "stock"))
	if tires is Dictionary:
		t = str((tires as Dictionary).get("name", "stock"))
	return "Bike: %s · Wheels: %s · Tires: %s" % [b, w, t]


func _select(rider: Dictionary) -> void:
	if _busy:
		return
	GameSession.set_rider(rider)
	# Finalize any rides left active by a prior crash / force-quit / network
	# drop for this rider. Server sweeps within minutes anyway; this just
	# closes the loop instantly so "My Rides" reflects truth.
	_set_busy(true, "Cleaning up prior rides…")
	await _auto_finalize_active(rider.get("id", ""))
	_set_busy(false, "")
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _auto_finalize_active(rider_id: String) -> void:
	if rider_id.is_empty():
		return
	var active: Array = await ApiClient.list_active_rides(rider_id)
	for r in active:
		var rid := str(r.get("id", ""))
		if rid.is_empty():
			continue
		await ApiClient.finish_ride(rid, {}, "app_relaunch")


func _on_manage_pressed() -> void:
	# SSO-bridged so the browser opens as the same user the game is.
	await ApiClient.open_web_link("/riders/")


func _on_logout_pressed() -> void:
	if _busy:
		return
	ApiClient.logout()
	GameSession.clear_rider()
	GameSession.reset()
	get_tree().change_scene_to_file("res://scenes/login.tscn")
