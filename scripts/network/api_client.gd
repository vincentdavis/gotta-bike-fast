extends Node

signal healthz_received(ok: bool, body: String)

const DEFAULT_BASE_URL := "http://127.0.0.1:8001"  # FastAPI — live game state
const DEFAULT_WEB_URL := "http://127.0.0.1:8000"  # Django — accounts + profile
const AUTH_FILE := "user://auth.cfg"

var base_url: String = DEFAULT_BASE_URL
var web_url: String = DEFAULT_WEB_URL

var _access_token: String = ""
var _refresh_token: String = ""
var user_id: String = ""


func _ready() -> void:
	_load_auth()
	ping()


# --- Auth ---

func is_authenticated() -> bool:
	return not _access_token.is_empty()


func login(email: String, password: String) -> Dictionary:
	var result: Dictionary = await _do_request(
		"POST", "/api/auth/login", {"email": email, "password": password}, web_url
	)
	if result["ok"] and result["json"] is Dictionary:
		_set_tokens_from_response(result["json"])
		return result["json"]
	return {}


func web_signup_url() -> String:
	return web_url + "/accounts/signup/"


func web_password_reset_url() -> String:
	return web_url + "/accounts/password_reset/"


func web_account_url() -> String:
	return web_url + "/accounts/account/"


func logout() -> void:
	_access_token = ""
	_refresh_token = ""
	user_id = ""
	_save_auth()


func get_me() -> Dictionary:
	var result: Dictionary = await _do_request("GET", "/api/users/me", null, web_url)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func update_me(updates: Dictionary) -> Dictionary:
	var result: Dictionary = await _do_request("PATCH", "/api/users/me", updates, web_url)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func _set_tokens_from_response(data: Dictionary) -> void:
	var tokens: Dictionary = data.get("tokens", {})
	_access_token = str(tokens.get("access_token", ""))
	_refresh_token = str(tokens.get("refresh_token", ""))
	var u: Dictionary = data.get("user", {})
	user_id = str(u.get("id", ""))
	_save_auth()


func _save_auth() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("auth", "access_token", _access_token)
	cfg.set_value("auth", "refresh_token", _refresh_token)
	cfg.set_value("auth", "user_id", user_id)
	cfg.save(AUTH_FILE)


func _load_auth() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(AUTH_FILE) != OK:
		return
	_access_token = str(cfg.get_value("auth", "access_token", ""))
	_refresh_token = str(cfg.get_value("auth", "refresh_token", ""))
	user_id = str(cfg.get_value("auth", "user_id", ""))


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


# --- Games ---

func list_games() -> Array:
	var result: Dictionary = await _do_request("GET", "/v1/games", null)
	if result["ok"] and result["json"] is Array:
		return result["json"]
	return []


func create_game(
	host_rider_id: String,
	course_id: String,
	countdown_duration_s: int = 30,
	scheduled_start_in_s: int = -1,
) -> Dictionary:
	var body: Dictionary = {
		"host_rider_id": host_rider_id,
		"course_id": course_id,
		"countdown_duration_s": countdown_duration_s,
	}
	if scheduled_start_in_s > 0:
		body["scheduled_start_in_s"] = scheduled_start_in_s
	var result: Dictionary = await _do_request("POST", "/v1/games", body)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func list_my_games(rider_id: String) -> Array:
	var result: Dictionary = await _do_request(
		"GET", "/v1/games/by-rider/%s" % rider_id, null
	)
	if result["ok"] and result["json"] is Array:
		return result["json"]
	return []


func list_game_results(code: String) -> Array:
	var result: Dictionary = await _do_request(
		"GET", "/v1/games/%s/results" % code, null
	)
	if result["ok"] and result["json"] is Array:
		return result["json"]
	return []


func get_game(code: String) -> Dictionary:
	var result: Dictionary = await _do_request("GET", "/v1/games/" + code, null)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func join_game(code: String, rider_id: String) -> Dictionary:
	var result: Dictionary = await _do_request(
		"POST", "/v1/games/%s/join" % code, {"rider_id": rider_id}
	)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func leave_game(code: String, rider_id: String) -> Dictionary:
	var result: Dictionary = await _do_request(
		"POST", "/v1/games/%s/leave" % code, {"rider_id": rider_id}
	)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func start_game(code: String, rider_id: String) -> Dictionary:
	var result: Dictionary = await _do_request(
		"POST", "/v1/games/%s/start" % code, {"rider_id": rider_id}
	)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


# --- Internal ---

func _do_request(method: String, path: String, body, base: String = "") -> Dictionary:
	var origin: String = base if not base.is_empty() else base_url
	var http := HTTPRequest.new()
	add_child(http)

	var headers := PackedStringArray()
	var body_str := ""
	if body != null:
		headers.append("Content-Type: application/json")
		body_str = JSON.stringify(body)
	if not _access_token.is_empty():
		headers.append("Authorization: Bearer " + _access_token)

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

	var err := http.request(origin + path, headers, http_method, body_str)
	if err != OK:
		push_error("ApiClient: %s %s dispatch failed err=%s" % [method, origin + path, err])
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
