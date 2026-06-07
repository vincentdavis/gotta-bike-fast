extends Node

# Game-side client for the local BLE sensor bridge (see bridge/). A separate
# Python `bleak` process does the actual Bluetooth work and serves
# ws://127.0.0.1:8770; this autoload connects to it, drives pairing
# (scan / connect), and exposes the latest power / cadence / heart-rate
# readings to the rest of the game.
#
# Power source is KEYBOARD by default. Only when the user explicitly picks
# SENSOR *and* a live power reading is fresh does ride_controller use the
# measured watts — otherwise the keyboard ↑/↓ ramp stays in control. The
# keyboard is therefore always the default and the automatic fallback if the
# bridge isn't running or a sensor drops out.
#
# Mirrors WorldClient's WebSocketPeer polling pattern. Connection is only
# attempted when something needs it (SENSOR selected, or the Sensors screen
# open), so a keyboard-only player never opens a socket.

signal bridge_status_changed(connected: bool)
signal devices_updated(devices: Array)
signal device_connected(info: Dictionary)
signal device_disconnected(address: String)
signal scan_state_changed(scanning: bool)
signal sensor_data(power_w: float, cadence_rpm: float, heart_rate_bpm: int)
signal power_source_changed(source: int)
signal bridge_error(message: String)
signal trainer_availability_changed(available: bool)
signal trainer_mode_changed(mode: int)

enum PowerSource { KEYBOARD, SENSOR }
# Smart-trainer (FTMS) resistance control:
#   OFF — don't drive resistance (trainer left flat)
#   SIM — resistance follows the road grade (the ride streams it)
#   ERG — hold a fixed target wattage
enum TrainerMode { OFF, SIM, ERG }

const FILE := "user://sensor.cfg"
const DEFAULT_URL := "ws://127.0.0.1:8770"
const FRESH_WINDOW_MS := 3000  # a reading older than this is treated as stale
const RECONNECT_INTERVAL_S := 4.0

var bridge_url: String = DEFAULT_URL
var power_source: int = PowerSource.KEYBOARD

# Trainer control. trainer_available is true once a connected device exposes
# the FTMS Control Point. Mode + ERG target persist across sessions.
var trainer_mode: int = TrainerMode.SIM
var erg_target_w: int = 150
var trainer_available: bool = false
var trainer_address: String = ""

# Latest merged reading. Timestamps are Time.get_ticks_msec() (monotonic) at
# receipt, used for freshness — independent of the bridge's wall clock.
var latest_power_w: float = 0.0
var latest_cadence_rpm: float = 0.0
var latest_hr_bpm: int = 0
var _power_ts_ms: int = 0
var _cadence_ts_ms: int = 0
var _hr_ts_ms: int = 0

var scanning: bool = false
var devices: Dictionary = {}            # address -> info dict
var connected_devices: Dictionary = {}  # address -> info dict

var _peer: WebSocketPeer = null
var _last_state: int = WebSocketPeer.STATE_CLOSED
var _want_connected: bool = false  # keep (re)connecting while true
var _reconnect_accum: float = RECONNECT_INTERVAL_S


func _ready() -> void:
	_load()
	# If the player left the source on SENSOR last session, start the bridge
	# connection now so measured power is ready when they enter a ride.
	if power_source == PowerSource.SENSOR:
		ensure_connected()


# --- public API ---

func is_bridge_connected() -> bool:
	return _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN


func ensure_connected() -> void:
	# Ask the autoload to maintain a connection to the bridge (used by the
	# Sensors screen and when SENSOR is selected). Safe to call repeatedly.
	_want_connected = true
	if _peer == null:
		_reconnect_accum = RECONNECT_INTERVAL_S  # connect on the next frame
		_open()


func stop() -> void:
	_want_connected = false
	if _peer != null:
		_peer.close()
		_peer = null
	_last_state = WebSocketPeer.STATE_CLOSED


func set_power_source(source: int) -> void:
	if source == power_source:
		return
	power_source = source
	_save()
	power_source_changed.emit(power_source)
	if power_source == PowerSource.SENSOR:
		ensure_connected()


func using_sensor() -> bool:
	return power_source == PowerSource.SENSOR


# --- trainer control ---

func set_trainer_mode(mode: int) -> void:
	if mode == trainer_mode:
		return
	trainer_mode = mode
	_save()
	trainer_mode_changed.emit(trainer_mode)
	match trainer_mode:
		TrainerMode.ERG:
			send_erg_watts(erg_target_w)
		TrainerMode.OFF:
			# Hand resistance back to flat so the rider isn't left pushing.
			if trainer_available:
				_send({"cmd": "set_sim", "grade": 0.0})
		_:
			pass  # SIM is driven by the ride streaming grade


func set_erg_target(watts: int) -> void:
	erg_target_w = clampi(watts, 0, 2000)
	_save()
	if trainer_mode == TrainerMode.ERG:
		send_erg_watts(erg_target_w)


func send_sim_grade(grade_pct: float, crr: float = 0.004, cw: float = 0.51) -> void:
	# Called by the ride each tick in SIM mode. No-op unless a controllable
	# trainer is connected; the bridge further throttles redundant writes.
	if not trainer_available:
		return
	_send({"cmd": "set_sim", "grade": grade_pct, "crr": crr, "cw": cw})


func send_erg_watts(watts: int) -> void:
	if not trainer_available:
		return
	_send({"cmd": "set_erg", "watts": watts})


func release_trainer() -> void:
	# Flatten resistance — used when a ride ends so the trainer doesn't hold
	# the last climb's grade.
	if trainer_available:
		_send({"cmd": "set_sim", "grade": 0.0})


func _set_trainer_available(available: bool, addr: String) -> void:
	if available == trainer_available and addr == trainer_address:
		return
	trainer_available = available
	trainer_address = addr
	trainer_availability_changed.emit(available)
	# Apply the current mode the moment a controllable trainer appears.
	if available:
		if trainer_mode == TrainerMode.ERG:
			send_erg_watts(erg_target_w)
		elif trainer_mode == TrainerMode.OFF:
			_send({"cmd": "set_sim", "grade": 0.0})


func has_fresh_power() -> bool:
	return _power_ts_ms > 0 and (Time.get_ticks_msec() - _power_ts_ms) < FRESH_WINDOW_MS


func has_fresh_cadence() -> bool:
	return _cadence_ts_ms > 0 and (Time.get_ticks_msec() - _cadence_ts_ms) < FRESH_WINDOW_MS


func has_fresh_hr() -> bool:
	return _hr_ts_ms > 0 and (Time.get_ticks_msec() - _hr_ts_ms) < FRESH_WINDOW_MS


func scan() -> void:
	ensure_connected()
	_send({"cmd": "scan"})


func stop_scan() -> void:
	_send({"cmd": "stop_scan"})


func connect_device(address: String, kind: String = "auto") -> void:
	_send({"cmd": "connect", "address": address, "kind": kind})


func disconnect_device(address: String) -> void:
	_send({"cmd": "disconnect", "address": address})


func disconnect_all() -> void:
	_send({"cmd": "disconnect_all"})


func set_bridge_url(url: String) -> void:
	bridge_url = url.strip_edges()
	_save()
	# Reconnect against the new URL if we were maintaining a connection.
	if _want_connected:
		if _peer != null:
			_peer.close()
			_peer = null
		ensure_connected()


# --- connection plumbing ---

func _open() -> void:
	_peer = WebSocketPeer.new()
	var err := _peer.connect_to_url(bridge_url)
	if err != OK:
		_peer = null
		return
	_last_state = WebSocketPeer.STATE_CONNECTING


func _send(msg: Dictionary) -> void:
	if not is_bridge_connected():
		return
	_peer.send_text(JSON.stringify(msg))


func _process(delta: float) -> void:
	if _peer == null:
		if _want_connected:
			_reconnect_accum += delta
			if _reconnect_accum >= RECONNECT_INTERVAL_S:
				_reconnect_accum = 0.0
				_open()
		return

	_peer.poll()
	var current_state: int = _peer.get_ready_state()

	if current_state != _last_state:
		if current_state == WebSocketPeer.STATE_OPEN:
			bridge_status_changed.emit(true)
			# Ask for a snapshot of any already-connected sensors.
			_send({"cmd": "status"})
		elif current_state == WebSocketPeer.STATE_CLOSED:
			_peer = null
			_last_state = WebSocketPeer.STATE_CLOSED
			_reconnect_accum = 0.0
			scanning = false
			connected_devices.clear()
			_set_trainer_available(false, "")
			bridge_status_changed.emit(false)
			return
		_last_state = current_state

	while current_state == WebSocketPeer.STATE_OPEN and _peer.get_available_packet_count() > 0:
		_handle_message(_peer.get_packet().get_string_from_utf8())


func _handle_message(text: String) -> void:
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return
	match str(parsed.get("type", "")):
		"hello":
			pass  # version handshake; nothing to do
		"status":
			_apply_status(parsed)
		"device":
			_apply_device(parsed)
		"scan_started":
			scanning = true
			scan_state_changed.emit(true)
		"scan_stopped":
			scanning = false
			scan_state_changed.emit(false)
		"connected":
			_apply_connected(parsed)
		"disconnected":
			_apply_disconnected(parsed)
		"sensor":
			_apply_sensor(parsed)
		"trainer_ready":
			_set_trainer_available(true, str(parsed.get("address", "")))
		"trainer_response":
			pass  # control-point ack; nothing to surface yet
		"error":
			bridge_error.emit(str(parsed.get("message", "")))


func _apply_status(msg: Dictionary) -> void:
	scanning = bool(msg.get("scanning", false))
	connected_devices.clear()
	for entry in msg.get("connected", []):
		if entry is Dictionary:
			var addr := str(entry.get("address", ""))
			connected_devices[addr] = entry
	var tr: Variant = msg.get("trainer")
	if tr is Dictionary:
		_set_trainer_available(true, str((tr as Dictionary).get("address", "")))
	else:
		_set_trainer_available(false, "")
	_apply_sensor(msg)  # status carries the merged reading too
	scan_state_changed.emit(scanning)
	devices_updated.emit(_device_list())


func _apply_device(msg: Dictionary) -> void:
	var addr := str(msg.get("address", ""))
	if addr.is_empty():
		return
	devices[addr] = msg
	devices_updated.emit(_device_list())


func _apply_connected(msg: Dictionary) -> void:
	var addr := str(msg.get("address", ""))
	if addr.is_empty():
		return
	connected_devices[addr] = msg
	if devices.has(addr):
		devices[addr]["connected"] = true
	if bool(msg.get("controllable", false)):
		_set_trainer_available(true, addr)
	device_connected.emit(msg)
	devices_updated.emit(_device_list())


func _apply_disconnected(msg: Dictionary) -> void:
	var addr := str(msg.get("address", ""))
	connected_devices.erase(addr)
	if devices.has(addr):
		devices[addr]["connected"] = false
	if addr == trainer_address:
		_set_trainer_available(false, "")
	device_disconnected.emit(addr)
	devices_updated.emit(_device_list())


func _apply_sensor(msg: Dictionary) -> void:
	var now := Time.get_ticks_msec()
	var p: Variant = msg.get("power_w")
	if p != null:
		latest_power_w = float(p)
		_power_ts_ms = now
	var c: Variant = msg.get("cadence_rpm")
	if c != null:
		latest_cadence_rpm = float(c)
		_cadence_ts_ms = now
	var h: Variant = msg.get("heart_rate_bpm")
	if h != null:
		latest_hr_bpm = int(h)
		_hr_ts_ms = now
	sensor_data.emit(latest_power_w, latest_cadence_rpm, latest_hr_bpm)


func _device_list() -> Array:
	return devices.values()


# --- persistence ---

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(FILE) != OK:
		return
	bridge_url = str(cfg.get_value("bridge", "url", DEFAULT_URL))
	power_source = int(cfg.get_value("bridge", "power_source", PowerSource.KEYBOARD))
	trainer_mode = int(cfg.get_value("trainer", "mode", TrainerMode.SIM))
	erg_target_w = int(cfg.get_value("trainer", "erg_target_w", 150))


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("bridge", "url", bridge_url)
	cfg.set_value("bridge", "power_source", power_source)
	cfg.set_value("trainer", "mode", trainer_mode)
	cfg.set_value("trainer", "erg_target_w", erg_target_w)
	cfg.save(FILE)
