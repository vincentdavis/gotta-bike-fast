extends Node

signal healthz_received(ok: bool, body: String)

const DEFAULT_BASE_URL := "http://127.0.0.1:8001"

var base_url: String = DEFAULT_BASE_URL


func _ready() -> void:
	ping()


# --- Public API ---

func ping() -> void:
	var result: Dictionary = await _do_request("GET", "/healthz", null)
	if result["ok"]:
		healthz_received.emit(true, result["body_text"])
	else:
		healthz_received.emit(false, "code=%s" % result["response_code"])


func list_courses() -> Array:
	var result: Dictionary = await _do_request("GET", "/v1/courses", null)
	if result["ok"] and result["json"] is Array:
		return result["json"]
	return []


func get_course(course_id: String) -> Dictionary:
	var result: Dictionary = await _do_request("GET", "/v1/courses/" + course_id, null)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func create_rider(
	display_name: String, weight_kg: float, height_m: float, ftp_w: int
) -> Dictionary:
	var result: Dictionary = await _do_request(
		"POST",
		"/v1/riders",
		{
			"display_name": display_name,
			"weight_kg": weight_kg,
			"height_m": height_m,
			"ftp_w": ftp_w,
		},
	)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func start_ride(rider_id: String, course_id: String) -> Dictionary:
	var result: Dictionary = await _do_request(
		"POST",
		"/v1/rides",
		{"rider_id": rider_id, "course_id": course_id},
	)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func post_samples(ride_id: String, samples: Array) -> bool:
	var result: Dictionary = await _do_request(
		"POST", "/v1/rides/%s/samples" % ride_id, {"samples": samples}
	)
	return result["ok"]


func finish_ride(ride_id: String) -> Dictionary:
	var result: Dictionary = await _do_request("POST", "/v1/rides/%s/finish" % ride_id, null)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


# --- Internal ---

func _do_request(method: String, path: String, body) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)

	var headers := PackedStringArray()
	var body_str := ""
	if body != null:
		headers.append("Content-Type: application/json")
		body_str = JSON.stringify(body)

	var http_method: int = HTTPClient.METHOD_GET
	match method:
		"POST":
			http_method = HTTPClient.METHOD_POST
		"PUT":
			http_method = HTTPClient.METHOD_PUT
		"PATCH":
			http_method = HTTPClient.METHOD_PATCH
		"DELETE":
			http_method = HTTPClient.METHOD_DELETE

	var err := http.request(base_url + path, headers, http_method, body_str)
	if err != OK:
		push_error("ApiClient: %s %s dispatch failed err=%s" % [method, path, err])
		http.queue_free()
		return {"ok": false, "response_code": 0, "body_text": "", "json": null}

	var result: Array = await http.request_completed
	http.queue_free()

	var transport_result: int = result[0]
	var response_code: int = result[1]
	var body_bytes: PackedByteArray = result[3]
	var body_text := body_bytes.get_string_from_utf8()

	var ok: bool = (
		transport_result == HTTPRequest.RESULT_SUCCESS
		and response_code >= 200
		and response_code < 300
	)
	if not ok:
		push_warning(
			"ApiClient: %s %s failed result=%s code=%s body=%s"
			% [method, path, transport_result, response_code, body_text]
		)

	var json: Variant = null
	if not body_text.is_empty():
		json = JSON.parse_string(body_text)

	return {"ok": ok, "response_code": response_code, "body_text": body_text, "json": json}
