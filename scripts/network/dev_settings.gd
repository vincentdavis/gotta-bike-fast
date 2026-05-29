extends Node

# Dev-only overrides for the service URLs. Loaded at startup by ApiClient
# and WorldClient so a tester can point the game at a different backend
# without touching code. Persisted to user://dev_settings.cfg.

const FILE := "user://dev_settings.cfg"

const DEFAULT_BASE_URL := "http://127.0.0.1:8001"  # FastAPI
const DEFAULT_WEB_URL := "http://127.0.0.1:8000"   # Django
const DEFAULT_WS_URL := "ws://127.0.0.1:8001"      # FastAPI WebSocket

var base_url: String = DEFAULT_BASE_URL
var web_url: String = DEFAULT_WEB_URL
var ws_url: String = DEFAULT_WS_URL


func _ready() -> void:
	_load()


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(FILE) != OK:
		return
	base_url = str(cfg.get_value("urls", "base_url", DEFAULT_BASE_URL))
	web_url = str(cfg.get_value("urls", "web_url", DEFAULT_WEB_URL))
	ws_url = str(cfg.get_value("urls", "ws_url", DEFAULT_WS_URL))


func save() -> void:
	var cfg := ConfigFile.new()
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
	base_url = DEFAULT_BASE_URL
	web_url = DEFAULT_WEB_URL
	ws_url = DEFAULT_WS_URL
