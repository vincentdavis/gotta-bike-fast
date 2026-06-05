extends Node

# Service URLs the client talks to, switchable between named environments.
# Loaded at startup by ApiClient + WorldClient so a tester can point the
# game at a different backend without touching code. Persisted to
# user://dev_settings.cfg.
#
# Pick an environment by name (LOCAL / ALPHA_1 / …) or hand-edit the three
# URLs (which switches to the CUSTOM environment). Add new deployments by
# appending to ENVIRONMENTS below.

const FILE := "user://dev_settings.cfg"
const CUSTOM := "CUSTOM"
const DEFAULT_ENV := "LOCAL"

# name -> { base_url (FastAPI), web_url (Django), ws_url (FastAPI WebSocket) }
const ENVIRONMENTS := {
	"LOCAL": {
		"base_url": "http://127.0.0.1:8001",
		"web_url": "http://127.0.0.1:8000",
		"ws_url": "ws://127.0.0.1:8001",
	},
	"ALPHA_1": {
		"base_url": "https://fastapi-production-e5cc.up.railway.app",
		"web_url": "https://web-production-f89db.up.railway.app",
		"ws_url": "wss://fastapi-production-e5cc.up.railway.app",
	},
}

var environment: String = DEFAULT_ENV
var base_url: String = ENVIRONMENTS[DEFAULT_ENV]["base_url"]
var web_url: String = ENVIRONMENTS[DEFAULT_ENV]["web_url"]
var ws_url: String = ENVIRONMENTS[DEFAULT_ENV]["ws_url"]


func _ready() -> void:
	_load()


func environment_names() -> Array:
	# Preset names in declaration order, plus CUSTOM at the end.
	var names: Array = ENVIRONMENTS.keys()
	names.append(CUSTOM)
	return names


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(FILE) != OK:
		# Fresh install — keep the LOCAL defaults set above.
		return
	var saved_base := str(cfg.get_value("urls", "base_url", ""))
	var saved_web := str(cfg.get_value("urls", "web_url", ""))
	var saved_ws := str(cfg.get_value("urls", "ws_url", ""))
	environment = str(cfg.get_value("env", "name", ""))
	if environment.is_empty():
		# Migrate older configs (no env key): infer the env from the saved
		# URLs, so a tester who had pointed at a preset keeps it.
		environment = _infer_env(saved_base, saved_web, saved_ws)

	if ENVIRONMENTS.has(environment):
		var preset: Dictionary = ENVIRONMENTS[environment]
		base_url = str(preset["base_url"])
		web_url = str(preset["web_url"])
		ws_url = str(preset["ws_url"])
	else:
		# CUSTOM (or unknown) — use whatever was saved, falling back to LOCAL.
		environment = CUSTOM
		var local: Dictionary = ENVIRONMENTS[DEFAULT_ENV]
		base_url = saved_base if not saved_base.is_empty() else str(local["base_url"])
		web_url = saved_web if not saved_web.is_empty() else str(local["web_url"])
		ws_url = saved_ws if not saved_ws.is_empty() else str(local["ws_url"])


func _infer_env(base: String, web: String, ws: String) -> String:
	if base.is_empty() and web.is_empty() and ws.is_empty():
		return DEFAULT_ENV
	for name in ENVIRONMENTS.keys():
		var p: Dictionary = ENVIRONMENTS[name]
		if base == str(p["base_url"]) and web == str(p["web_url"]) and ws == str(p["ws_url"]):
			return name
	return CUSTOM


func apply_environment(name: String) -> void:
	# Switch to a named preset and persist. No-op for an unknown name.
	if not ENVIRONMENTS.has(name):
		return
	var preset: Dictionary = ENVIRONMENTS[name]
	environment = name
	base_url = str(preset["base_url"])
	web_url = str(preset["web_url"])
	ws_url = str(preset["ws_url"])
	save()


func set_custom_urls(new_base: String, new_web: String, new_ws: String) -> void:
	# Manual override. If the URLs happen to match a known preset, record
	# that preset name instead of CUSTOM so the selector reflects it.
	base_url = new_base
	web_url = new_web
	ws_url = new_ws
	environment = _infer_env(new_base, new_web, new_ws)
	save()


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("env", "name", environment)
	cfg.set_value("urls", "base_url", base_url)
	cfg.set_value("urls", "web_url", web_url)
	cfg.set_value("urls", "ws_url", ws_url)
	cfg.save(FILE)
	# Push the new values into the live singletons so subsequent requests
	# go to the new origin without an app restart.
	ApiClient.base_url = base_url
	ApiClient.web_url = web_url
	WorldClient.ws_url = ws_url


func reset_to_defaults() -> void:
	apply_environment(DEFAULT_ENV)
