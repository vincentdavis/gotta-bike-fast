extends Control

# Sensor pairing + power-source screen. Talks to the SensorBridge autoload,
# which in turn talks to the local Python bleak bridge (see bridge/). Lets
# the player:
#   * choose their power source (Keyboard — default — or Sensor),
#   * scan for BLE cycling sensors and connect/disconnect them,
#   * watch a live power / cadence / heart-rate readout.
#
# Built in code (like main.gd / course_picker.gd) because the device list is
# dynamic. The keyboard is never disabled here — picking Sensor just lets a
# paired power meter take over when its feed is live.

const DOT_OK := Color(0.30, 0.78, 0.40, 1.0)
const DOT_OFFLINE := Color(0.85, 0.28, 0.28, 1.0)

const KIND_LABELS := {
	"power": "Power", "hr": "Heart rate", "csc": "Cadence", "trainer": "Trainer",
}

var _status_dot: ColorRect
var _status_label: Label
var _url_input: LineEdit
var _source_option: OptionButton
var _scan_button: Button
var _scan_status: Label
var _device_list: VBoxContainer
var _readout: Label

# Trainer section (shown only when a controllable trainer is connected).
var _trainer_section: VBoxContainer
var _trainer_mode_option: OptionButton
var _erg_row: HBoxContainer
var _erg_input: SpinBox
var _trainer_hint: Label


func _ready() -> void:
	_build_ui()
	SensorBridge.bridge_status_changed.connect(_on_bridge_status)
	SensorBridge.devices_updated.connect(_on_devices_updated)
	SensorBridge.scan_state_changed.connect(_on_scan_state)
	SensorBridge.sensor_data.connect(_on_sensor_data)
	SensorBridge.bridge_error.connect(_on_bridge_error)
	SensorBridge.trainer_availability_changed.connect(_on_trainer_availability)
	# Start (or reuse) the bridge connection while this screen is open.
	SensorBridge.ensure_connected()
	_refresh_bridge_status()
	_on_devices_updated(SensorBridge.devices.values())
	_on_scan_state(SensorBridge.scanning)
	_refresh_trainer_section()


# --- UI construction ---

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.10, 0.14, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 60)
	margin.add_theme_constant_override("margin_right", 60)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	var title := Label.new()
	title.text = "Sensors"
	title.add_theme_font_size_override("font_size", 34)
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.text = (
		"Pair BLE power meters, heart-rate straps, and cadence sensors. "
		+ "Run the bridge first:  cd bridge && uv run gbf-bridge"
	)
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.modulate = Color(0.75, 0.78, 0.85)
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(subtitle)

	# Bridge status row: dot · label · URL · Reconnect.
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 10)
	root.add_child(status_row)

	_status_dot = ColorRect.new()
	_status_dot.custom_minimum_size = Vector2(16, 16)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_row.add_child(_status_dot)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.custom_minimum_size = Vector2(260, 0)
	status_row.add_child(_status_label)

	_url_input = LineEdit.new()
	_url_input.text = SensorBridge.bridge_url
	_url_input.custom_minimum_size = Vector2(240, 0)
	_url_input.tooltip_text = "Bridge WebSocket URL"
	_url_input.text_submitted.connect(_on_url_submitted)
	status_row.add_child(_url_input)

	var reconnect := Button.new()
	reconnect.text = "Reconnect"
	reconnect.pressed.connect(_on_reconnect)
	status_row.add_child(reconnect)

	root.add_child(HSeparator.new())

	# Power source row.
	var source_row := HBoxContainer.new()
	source_row.add_theme_constant_override("separation", 12)
	root.add_child(source_row)

	var source_label := Label.new()
	source_label.text = "Power source"
	source_label.add_theme_font_size_override("font_size", 18)
	source_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	source_row.add_child(source_label)

	_source_option = OptionButton.new()
	_source_option.add_theme_font_size_override("font_size", 18)
	_source_option.custom_minimum_size = Vector2(240, 0)
	# Item index must match SensorBridge.PowerSource (KEYBOARD=0, SENSOR=1).
	_source_option.add_item("Keyboard (↑/↓)", SensorBridge.PowerSource.KEYBOARD)
	_source_option.add_item("Sensor (power meter)", SensorBridge.PowerSource.SENSOR)
	_source_option.select(SensorBridge.power_source)
	_source_option.item_selected.connect(_on_source_selected)
	source_row.add_child(_source_option)

	var source_hint := Label.new()
	source_hint.text = "Keyboard stays available as a fallback."
	source_hint.add_theme_font_size_override("font_size", 13)
	source_hint.modulate = Color(0.7, 0.73, 0.8)
	source_hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	source_row.add_child(source_hint)

	root.add_child(HSeparator.new())

	# Scan controls.
	var scan_row := HBoxContainer.new()
	scan_row.add_theme_constant_override("separation", 12)
	root.add_child(scan_row)

	_scan_button = Button.new()
	_scan_button.text = "Scan"
	_scan_button.add_theme_font_size_override("font_size", 18)
	_scan_button.custom_minimum_size = Vector2(140, 0)
	_scan_button.pressed.connect(_on_scan_pressed)
	scan_row.add_child(_scan_button)

	_scan_status = Label.new()
	_scan_status.add_theme_font_size_override("font_size", 14)
	_scan_status.modulate = Color(0.75, 0.78, 0.85)
	_scan_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	scan_row.add_child(_scan_status)

	# Device list.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	_device_list = VBoxContainer.new()
	_device_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_device_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_device_list)

	# Trainer control (smart-trainer resistance).
	root.add_child(_build_trainer_section())

	# Live readout.
	_readout = Label.new()
	_readout.add_theme_font_size_override("font_size", 20)
	_readout.modulate = Color(0.9, 0.92, 0.98)
	root.add_child(_readout)
	_update_readout()

	# Back.
	var back := Button.new()
	back.text = "Back"
	back.flat = true
	back.add_theme_font_size_override("font_size", 16)
	back.pressed.connect(_on_back)
	root.add_child(back)


# --- trainer section ---

func _build_trainer_section() -> VBoxContainer:
	_trainer_section = VBoxContainer.new()
	_trainer_section.add_theme_constant_override("separation", 8)

	_trainer_section.add_child(HSeparator.new())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_trainer_section.add_child(row)

	var label := Label.new()
	label.text = "Trainer resistance"
	label.add_theme_font_size_override("font_size", 18)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(label)

	_trainer_mode_option = OptionButton.new()
	_trainer_mode_option.add_theme_font_size_override("font_size", 18)
	_trainer_mode_option.custom_minimum_size = Vector2(220, 0)
	# Item index must match SensorBridge.TrainerMode (OFF=0, SIM=1, ERG=2).
	_trainer_mode_option.add_item("Off (flat)", SensorBridge.TrainerMode.OFF)
	_trainer_mode_option.add_item("SIM — follow the road", SensorBridge.TrainerMode.SIM)
	_trainer_mode_option.add_item("ERG — hold target watts", SensorBridge.TrainerMode.ERG)
	_trainer_mode_option.select(SensorBridge.trainer_mode)
	_trainer_mode_option.item_selected.connect(_on_trainer_mode_selected)
	row.add_child(_trainer_mode_option)

	# ERG target row (shown only in ERG mode).
	_erg_row = HBoxContainer.new()
	_erg_row.add_theme_constant_override("separation", 10)
	_trainer_section.add_child(_erg_row)

	var erg_label := Label.new()
	erg_label.text = "Target power"
	erg_label.add_theme_font_size_override("font_size", 15)
	erg_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_erg_row.add_child(erg_label)

	_erg_input = SpinBox.new()
	_erg_input.min_value = 30
	_erg_input.max_value = 600
	_erg_input.step = 5
	_erg_input.value = SensorBridge.erg_target_w
	_erg_input.suffix = "W"
	_erg_input.value_changed.connect(_on_erg_target_changed)
	_erg_row.add_child(_erg_input)

	_trainer_hint = Label.new()
	_trainer_hint.add_theme_font_size_override("font_size", 13)
	_trainer_hint.modulate = Color(0.7, 0.73, 0.8)
	_trainer_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_trainer_section.add_child(_trainer_hint)

	return _trainer_section


func _on_trainer_availability(_available: bool) -> void:
	_refresh_trainer_section()


func _on_trainer_mode_selected(index: int) -> void:
	SensorBridge.set_trainer_mode(index)
	_refresh_trainer_section()


func _on_erg_target_changed(value: float) -> void:
	SensorBridge.set_erg_target(int(value))


func _refresh_trainer_section() -> void:
	if _trainer_section == null:
		return
	# The whole section appears only when a controllable trainer is present.
	_trainer_section.visible = SensorBridge.trainer_available
	_trainer_mode_option.select(SensorBridge.trainer_mode)
	_erg_row.visible = SensorBridge.trainer_mode == SensorBridge.TrainerMode.ERG
	match SensorBridge.trainer_mode:
		SensorBridge.TrainerMode.SIM:
			_trainer_hint.text = "Resistance follows the road grade as you ride."
		SensorBridge.TrainerMode.ERG:
			_trainer_hint.text = "Holds a fixed target wattage regardless of grade."
		_:
			_trainer_hint.text = "Resistance control off — the trainer stays flat."


# --- bridge status ---

func _refresh_bridge_status() -> void:
	_on_bridge_status(SensorBridge.is_bridge_connected())


func _on_bridge_status(connected: bool) -> void:
	if connected:
		_status_dot.color = DOT_OK
		_status_label.text = "Bridge connected"
	else:
		_status_dot.color = DOT_OFFLINE
		_status_label.text = "Bridge not running"


func _on_bridge_error(message: String) -> void:
	if message.is_empty():
		return
	_scan_status.text = "Error: %s" % message


# --- power source ---

func _on_source_selected(index: int) -> void:
	SensorBridge.set_power_source(index)


# --- scanning ---

func _on_scan_pressed() -> void:
	if SensorBridge.scanning:
		SensorBridge.stop_scan()
	else:
		SensorBridge.scan()


func _on_scan_state(scanning: bool) -> void:
	_scan_button.text = "Stop scan" if scanning else "Scan"
	_scan_status.text = "Scanning for sensors…" if scanning else ""


# --- device list ---

func _on_devices_updated(device_values: Array) -> void:
	for child in _device_list.get_children():
		child.queue_free()
	if device_values.is_empty():
		var empty := Label.new()
		empty.text = "No sensors found yet. Press Scan with a sensor awake (pedal / move the strap)."
		empty.add_theme_font_size_override("font_size", 15)
		empty.modulate = Color(0.75, 0.78, 0.85)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_device_list.add_child(empty)
		return
	# Connected devices first, then by signal strength.
	var sorted := device_values.duplicate()
	sorted.sort_custom(_device_sort)
	for info in sorted:
		_device_list.add_child(_build_device_row(info))


func _device_sort(a: Dictionary, b: Dictionary) -> bool:
	var ac := bool(a.get("connected", false))
	var bc := bool(b.get("connected", false))
	if ac != bc:
		return ac  # connected ones first
	return int(a.get("rssi", -999)) > int(b.get("rssi", -999))


func _build_device_row(info: Dictionary) -> PanelContainer:
	var address := str(info.get("address", ""))
	var connected := bool(info.get("connected", false))

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

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(col)

	var name_lbl := Label.new()
	name_lbl.text = str(info.get("name", "(unknown)"))
	name_lbl.add_theme_font_size_override("font_size", 18)
	col.add_child(name_lbl)

	var detail := Label.new()
	detail.text = "%s · %s · %d dBm" % [_kinds_text(info.get("kinds", [])), address, int(info.get("rssi", 0))]
	detail.add_theme_font_size_override("font_size", 13)
	detail.modulate = Color(0.72, 0.75, 0.82)
	col.add_child(detail)

	var action := Button.new()
	action.custom_minimum_size = Vector2(130, 0)
	action.add_theme_font_size_override("font_size", 15)
	if connected:
		action.text = "Disconnect"
		action.pressed.connect(func() -> void: SensorBridge.disconnect_device(address))
	else:
		action.text = "Connect"
		action.pressed.connect(func() -> void: SensorBridge.connect_device(address))
	hbox.add_child(action)

	return panel


func _kinds_text(kinds: Array) -> String:
	var parts: Array[String] = []
	for k in kinds:
		parts.append(str(KIND_LABELS.get(str(k), str(k))))
	if parts.is_empty():
		return "Sensor"
	return ", ".join(parts)


# --- live readout ---

func _on_sensor_data(_power: float, _cadence: float, _hr: int) -> void:
	_update_readout()


func _update_readout() -> void:
	var p := "-- W"
	var c := "-- rpm"
	var h := "-- bpm"
	if SensorBridge.has_fresh_power():
		p = "%d W" % int(round(SensorBridge.latest_power_w))
	if SensorBridge.has_fresh_cadence():
		c = "%d rpm" % int(round(SensorBridge.latest_cadence_rpm))
	if SensorBridge.has_fresh_hr():
		h = "%d bpm" % SensorBridge.latest_hr_bpm
	_readout.text = "Power: %s    Cadence: %s    HR: %s" % [p, c, h]


# --- url / reconnect / back ---

func _on_url_submitted(text: String) -> void:
	SensorBridge.set_bridge_url(text)


func _on_reconnect() -> void:
	SensorBridge.set_bridge_url(_url_input.text)  # also reconnects
	SensorBridge.ensure_connected()
	_scan_status.text = "Reconnecting…"


func _on_back() -> void:
	# Stop scanning to save battery/airtime, but keep the connection alive so
	# the source selection keeps working once a ride starts.
	if SensorBridge.scanning:
		SensorBridge.stop_scan()
	get_tree().change_scene_to_file("res://scenes/main.tscn")
