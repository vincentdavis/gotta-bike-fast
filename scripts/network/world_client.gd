extends Node

# WebSocket client for the game-scoped world session. Emits signals when
# other riders join, leave, or update their state, and for game lifecycle
# events (lobby_update, countdown_started, race_started, race_ended).
# Polled in _process.

signal connected
signal disconnected
signal welcome(riders: Array)
signal rider_joined(rider_id: String, display_name: String, bib_number: int)
signal rider_left(rider_id: String)
signal rider_state(rider_id: String, state: Dictionary)
signal lobby_update(participants: Array)
signal countdown_started(countdown_starts_at: String, race_starts_at: String)
signal race_started
signal race_ended(reason: String)

var ws_url: String = ""  # initialized from DevSettings on _ready

var _peer: WebSocketPeer = null
var _last_state: int = WebSocketPeer.STATE_CLOSED


func _ready() -> void:
	ws_url = DevSettings.ws_url


func connect_to_game(code: String, rider_id: String, ride_id: String = "") -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	_peer = WebSocketPeer.new()
	var url := "%s/ws/game/%s?rider_id=%s" % [ws_url, code, rider_id]
	if not ride_id.is_empty():
		url += "&ride_id=" + ride_id
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
			rider_joined.emit(
				parsed.get("rider_id", ""),
				parsed.get("display_name", ""),
				int(parsed.get("bib_number", 0)),
			)
		"rider_left":
			rider_left.emit(parsed.get("rider_id", ""))
		"rider_state":
			rider_state.emit(parsed.get("rider_id", ""), parsed.get("state", {}))
		"lobby_update":
			lobby_update.emit(parsed.get("participants", []))
		"countdown_started":
			countdown_started.emit(
				str(parsed.get("countdown_starts_at", "")),
				str(parsed.get("race_starts_at", "")),
			)
		"race_started":
			race_started.emit()
		"race_ended":
			race_ended.emit(str(parsed.get("reason", "")))
