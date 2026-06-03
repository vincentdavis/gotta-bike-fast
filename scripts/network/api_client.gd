extends Node

# Legacy single-shot signal — kept for callers (e.g. main.gd before the
# landing-page refactor) that listen for the first response and route.
# Prefer connection_status_changed for new code.
signal healthz_received(ok: bool, body: String)

# Modern persistent connection-status signal. Fires every time the
# status for either service changes. service is "fastapi" or "web";
# status is one of the Status enum values below.
signal connection_status_changed(service: String, status: int)

enum Status { CONNECTING, OK, OFFLINE }

const AUTH_FILE := "user://auth.cfg"

# Live origins — initialized from DevSettings on _ready so the in-game dev
# menu can override them without touching code.
var base_url: String = ""  # FastAPI — live game state
var web_url: String = ""   # Django — accounts + riders + profile

# Last-seen reachability of each backend. Read these directly for one-shot
# checks; subscribe to connection_status_changed for live updates.
var fastapi_status: int = Status.CONNECTING
var web_status: int = Status.CONNECTING

var _access_token: String = ""
var _refresh_token: String = ""
var user_id: String = ""
var user_email: String = ""
var user_display_name: String = ""


const RECHECK_INTERVAL_S := 3.0


func _ready() -> void:
	base_url = DevSettings.base_url
	web_url = DevSettings.web_url
	_load_auth()
	# First probe of each backend, then a recurring re-poll so any scene
	# listening to connection_status_changed gets live updates without
	# wiring its own timer. Cheap (one /healthz + one /api/docs every
	# few seconds) and keeps the menu / lobby pills accurate even when
	# nothing else triggers a request.
	ping_all()
	var t := Timer.new()
	t.wait_time = RECHECK_INTERVAL_S
	t.autostart = true
	t.timeout.connect(_on_recheck_tick)
	add_child(t)


func _on_recheck_tick() -> void:
	# Skip whichever service is mid-flight so we don't stack concurrent
	# /healthz requests when a backend is being slow.
	if fastapi_status != Status.CONNECTING:
		ping()
	if web_status != Status.CONNECTING:
		ping_web()


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


func web_riders_url() -> String:
	return web_url + "/riders/"


func web_games_url() -> String:
	return web_url + "/games/"


func web_rides_url() -> String:
	return web_url + "/rides/"


func logout() -> void:
	_access_token = ""
	_refresh_token = ""
	user_id = ""
	user_email = ""
	user_display_name = ""
	_save_auth()


func get_me() -> Dictionary:
	var result: Dictionary = await _do_request("GET", "/api/users/me", null, web_url)
	if result["ok"] and result["json"] is Dictionary:
		_set_user_from_dict(result["json"])
		_save_auth()
		return result["json"]
	return {}


func user_label() -> String:
	# Best-effort display name for nav / menu chrome. Falls back to email
	# if the User row has no display_name set yet, and to "(signed in)"
	# if we have a token but never fetched profile.
	if not user_display_name.is_empty():
		return user_display_name
	if not user_email.is_empty():
		return user_email
	return "(signed in)"


func _set_user_from_dict(u: Dictionary) -> void:
	user_id = str(u.get("id", user_id))
	user_email = str(u.get("email", user_email))
	user_display_name = str(u.get("display_name", user_display_name))


func update_me(updates: Dictionary) -> Dictionary:
	var result: Dictionary = await _do_request("PATCH", "/api/users/me", updates, web_url)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


# --- Riders (Django-owned; read-only from the game) ---

func list_riders() -> Array:
	var result: Dictionary = await _do_request("GET", "/api/riders", null, web_url)
	if result["ok"] and result["json"] is Array:
		return result["json"]
	return []


func get_rider(rider_id: String) -> Dictionary:
	var result: Dictionary = await _do_request(
		"GET", "/api/riders/%s" % rider_id, null, web_url
	)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func _set_tokens_from_response(data: Dictionary) -> void:
	var tokens: Dictionary = data.get("tokens", {})
	_access_token = str(tokens.get("access_token", ""))
	_refresh_token = str(tokens.get("refresh_token", ""))
	_set_user_from_dict(data.get("user", {}))
	_save_auth()


func _save_auth() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("auth", "access_token", _access_token)
	cfg.set_value("auth", "refresh_token", _refresh_token)
	cfg.set_value("auth", "user_id", user_id)
	cfg.set_value("user", "email", user_email)
	cfg.set_value("user", "display_name", user_display_name)
	cfg.save(AUTH_FILE)


func _load_auth() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(AUTH_FILE) != OK:
		return
	_access_token = str(cfg.get_value("auth", "access_token", ""))
	_refresh_token = str(cfg.get_value("auth", "refresh_token", ""))
	user_id = str(cfg.get_value("auth", "user_id", ""))
	user_email = str(cfg.get_value("user", "email", ""))
	user_display_name = str(cfg.get_value("user", "display_name", ""))


# --- Public API ---

func ping() -> void:
	# FastAPI healthz probe. Marks fastapi_status as CONNECTING for the
	# duration of the request so any UI listening sees an immediate "in
	# flight" amber state, then flips to OK / OFFLINE based on the result.
	_set_status("fastapi", Status.CONNECTING)
	var result: Dictionary = await _do_request("GET", "/healthz", null)
	if result["ok"]:
		_set_status("fastapi", Status.OK)
		healthz_received.emit(true, result["body_text"])
	else:
		_set_status("fastapi", Status.OFFLINE)
		healthz_received.emit(false, "code=%s" % result["response_code"])


func ping_web() -> void:
	# Django reachability probe. There's no dedicated healthz on the
	# Django side, so we hit the auto-generated /api/docs (django-ninja
	# always exposes it) and treat any 2xx/3xx as alive.
	_set_status("web", Status.CONNECTING)
	var result: Dictionary = await _do_request("GET", "/api/docs", null, web_url)
	_set_status("web", Status.OK if result["ok"] else Status.OFFLINE)


func ping_all() -> void:
	# Convenience for landing-page / status-pill use: kick both probes
	# off concurrently. Each will update its own status independently.
	ping()
	ping_web()


func _set_status(service: String, status: int) -> void:
	var changed := false
	if service == "fastapi" and fastapi_status != status:
		fastapi_status = status
		changed = true
	elif service == "web" and web_status != status:
		web_status = status
		changed = true
	if changed:
		connection_status_changed.emit(service, status)


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


# --- Ride history (Django-owned) ---

func start_ride(
	rider_id: String,
	course_id: String,
	course_name: String = "",
	course_length_m: float = 0.0,
	is_solo: bool = true,
	race_code: String = "",
) -> Dictionary:
	var body: Dictionary = {
		"rider_id": rider_id,
		"course_id": course_id,
		"course_name": course_name,
		"course_length_m": course_length_m,
		"is_solo": is_solo,
		"race_code": race_code,
	}
	var result: Dictionary = await _do_request(
		"POST", "/api/history/rides", body, web_url
	)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func post_samples(ride_id: String, samples: Array) -> bool:
	var result: Dictionary = await _do_request(
		"POST",
		"/api/history/rides/%s/samples" % ride_id,
		{"samples": samples},
		web_url,
	)
	return result["ok"]


func finish_ride(
	ride_id: String,
	totals: Dictionary = {},
	reason: String = "explicit",
) -> Dictionary:
	var body: Dictionary = totals.duplicate()
	body["reason"] = reason
	var result: Dictionary = await _do_request(
		"POST", "/api/history/rides/%s/finish" % ride_id, body, web_url
	)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func list_active_rides(rider_id: String) -> Array:
	var result: Dictionary = await _do_request(
		"GET",
		"/api/history/rides/active?rider_id=%s" % rider_id,
		null,
		web_url,
	)
	if result["ok"] and result["json"] is Array:
		return result["json"]
	return []


# --- Games ---

func list_games() -> Array:
	var result: Dictionary = await _do_request("GET", "/v1/games", null)
	if result["ok"] and result["json"] is Array:
		return result["json"]
	return []


func create_game(
	host_rider_id: String,
	host_display_name: String,
	course_id: String,
	countdown_duration_s: int = 30,
	scheduled_start_in_s: int = -1,
) -> Dictionary:
	var body: Dictionary = {
		"host_rider_id": host_rider_id,
		"host_display_name": host_display_name,
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
	# After Phase 5e race results are derived from Django's RideHistory
	# rows tagged with this race code. The dedicated endpoint lands in
	# 5e-8; until then, results.tscn falls back to GameSession participants.
	var result: Dictionary = await _do_request(
		"GET",
		"/api/history/rides?race_code=%s&limit=50" % code,
		null,
		web_url,
	)
	if result["ok"] and result["json"] is Array:
		return result["json"]
	return []


func get_game(code: String) -> Dictionary:
	var result: Dictionary = await _do_request("GET", "/v1/games/" + code, null)
	if result["ok"] and result["json"] is Dictionary:
		return result["json"]
	return {}


func join_game(code: String, rider_id: String, display_name: String = "") -> Dictionary:
	var body: Dictionary = {"rider_id": rider_id}
	if not display_name.is_empty():
		body["display_name"] = display_name
	var result: Dictionary = await _do_request(
		"POST", "/v1/games/%s/join" % code, body
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
