extends Node

signal healthz_received(ok: bool, body: String)

const DEFAULT_BASE_URL := "http://127.0.0.1:8000"

var base_url: String = DEFAULT_BASE_URL

var _http: HTTPRequest


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	ping()


func ping() -> void:
	_http.request_completed.connect(_on_ping_completed, CONNECT_ONE_SHOT)
	var err := _http.request(base_url + "/healthz")
	if err != OK:
		push_warning("ApiClient: failed to send /healthz request, err=%s" % err)
		healthz_received.emit(false, "request error %s" % err)


func _on_ping_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
) -> void:
	var text := body.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning(
			"ApiClient: /healthz failed result=%s code=%s body=%s"
			% [result, response_code, text]
		)
		healthz_received.emit(false, "result=%s code=%s" % [result, response_code])
		return
	print("[ApiClient] /healthz %s -> %s" % [response_code, text])
	healthz_received.emit(true, text)
