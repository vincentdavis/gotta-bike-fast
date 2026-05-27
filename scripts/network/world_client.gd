extends Node

# WebSocket client for the course-scoped world session. Emits signals
# when other riders join, leave, or update their state. Polled in _process.

signal connected
signal disconnected
signal welcome(riders: Array)
signal rider_joined(rider_id: String, display_name: String)
signal rider_left(rider_id: String)
signal rider_state(rider_id: String, state: Dictionary)

const DEFAULT_WS_URL := "ws://127.0.0.1:8001"

var ws_url: String = DEFAULT_WS_URL

var _peer: WebSocketPeer = null
var _last_state: int = WebSocketPeer.STATE_CLOSED


func connect_to_course(course_id: String, rider_id: String) -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	_peer = WebSocketPeer.new()
	var url := "%s/ws/world/%s?rider_id=%s" % [ws_url, course_id, rider_id]
	var err := _peer.connect_to_url(url)
	if err != OK:
		push_warning("WorldClient: connect failed err=%s url=%s" % [err, url])
		_peer = null
		return
	_last_state = WebSocketPeer.STATE_CONNECTING


func send_state(state: Dictionary) -> void:
	if _peer == null:
		return
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_peer.send_text(JSON.stringify({"type": "state", "state": state}))


func disconnect_now() -> void:
	if _peer != null:
		_peer.close()


func _process(_delta: float) -> void:
	if _peer == null:
		return
	_peer.poll()
	var current_state: int = _peer.get_ready_state()

	if current_state != _last_state:
		if current_state == WebSocketPeer.STATE_OPEN:
			connected.emit()
		elif current_state == WebSocketPeer.STATE_CLOSED:
			disconnected.emit()
			_peer = null
			_last_state = current_state
			return
		_last_state = current_state

	while current_state == WebSocketPeer.STATE_OPEN and _peer.get_available_packet_count() > 0:
		var text := _peer.get_packet().get_string_from_utf8()
		_handle_message(text)


func _handle_message(text: String) -> void:
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return
	var msg_type: String = parsed.get("type", "")
	match msg_type:
		"welcome":
			welcome.emit(parsed.get("riders", []))
		"rider_joined":
			rider_joined.emit(parsed.get("rider_id", ""), parsed.get("display_name", ""))
		"rider_left":
			rider_left.emit(parsed.get("rider_id", ""))
		"rider_state":
			rider_state.emit(parsed.get("rider_id", ""), parsed.get("state", {}))
