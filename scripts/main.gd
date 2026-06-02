extends Control

# Landing page — the always-loadable home you can reach even when both
# backends are down. Shows live connection status for FastAPI + Django,
# re-polls every 3 seconds, exposes a Retry button + a Dev Menu door
# (where URLs can be edited) + a Continue button that's only enabled
# once both services are reachable. Continue routes to the same target
# the original boot script chose (login → riders → main menu) based on
# auth + rider-pick state.

const RECHECK_INTERVAL_S := 3.0

const DOT_OK := Color(0.30, 0.78, 0.40, 1.0)
const DOT_OFFLINE := Color(0.85, 0.28, 0.28, 1.0)
const DOT_CONNECTING := Color(0.95, 0.75, 0.25, 1.0)

@onready var fastapi_dot: ColorRect = $Center/VBox/StatusPanel/Margin/VBox/FastAPIRow/FastAPIDot
@onready var fastapi_url_label: Label = $Center/VBox/StatusPanel/Margin/VBox/FastAPIRow/FastAPIText/FastAPIURL
@onready var fastapi_status_label: Label = $Center/VBox/StatusPanel/Margin/VBox/FastAPIRow/FastAPIStatus
@onready var web_dot: ColorRect = $Center/VBox/StatusPanel/Margin/VBox/WebRow/WebDot
@onready var web_url_label: Label = $Center/VBox/StatusPanel/Margin/VBox/WebRow/WebText/WebURL
@onready var web_status_label: Label = $Center/VBox/StatusPanel/Margin/VBox/WebRow/WebStatus
@onready var retry_button: Button = $Center/VBox/ButtonRow/RetryButton
@onready var dev_button: Button = $Center/VBox/ButtonRow/DevButton
@onready var continue_button: Button = $Center/VBox/ButtonRow/ContinueButton

var _recheck_timer: Timer


func _ready() -> void:
	# Reflect whatever URLs are actually in use right now (which may have
	# been overridden in the dev menu since last launch).
	_refresh_url_labels()
	_refresh_pills()

	ApiClient.connection_status_changed.connect(_on_connection_status_changed)
	retry_button.pressed.connect(_on_retry_pressed)
	dev_button.pressed.connect(_on_dev_pressed)
	continue_button.pressed.connect(_on_continue_pressed)

	# Kick off the first check immediately. ApiClient already ran ping()
	# on its own _ready() so fastapi_status may already be OK by now —
	# this also lights up the Django pill, which ApiClient doesn't probe
	# automatically.
	ApiClient.ping_all()

	# Recurring re-poll so the page self-heals when a backend comes
	# back online without the user clicking anything.
	_recheck_timer = Timer.new()
	_recheck_timer.wait_time = RECHECK_INTERVAL_S
	_recheck_timer.autostart = true
	_recheck_timer.timeout.connect(_on_recheck_tick)
	add_child(_recheck_timer)


func _on_connection_status_changed(_service: String, _status: int) -> void:
	_refresh_pills()


func _on_recheck_tick() -> void:
	# Only re-poll services that aren't currently mid-flight. Avoids
	# stacking concurrent /healthz requests if a backend is slow.
	if ApiClient.fastapi_status != ApiClient.Status.CONNECTING:
		ApiClient.ping()
	if ApiClient.web_status != ApiClient.Status.CONNECTING:
		ApiClient.ping_web()


func _on_retry_pressed() -> void:
	# Manual re-poll. Picks up URL edits made in the dev menu since the
	# last tick, because ApiClient.base_url / web_url were already updated
	# by DevSettings.save().
	_refresh_url_labels()
	ApiClient.ping_all()


func _on_dev_pressed() -> void:
	# Tell the dev menu to come back here when the user clicks Back.
	# Without this, dev_menu falls through to main_menu — which an
	# offline player can't navigate from.
	GameSession.dev_menu_return_scene = "res://scenes/main.tscn"
	get_tree().change_scene_to_file("res://scenes/dev_menu.tscn")


func _on_continue_pressed() -> void:
	# Same routing logic the original bootstrap had — auth gate first,
	# then rider gate, then main menu.
	if not ApiClient.is_authenticated():
		get_tree().change_scene_to_file("res://scenes/login.tscn")
		return
	if not GameSession.has_rider():
		get_tree().change_scene_to_file("res://scenes/riders.tscn")
		return
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _refresh_url_labels() -> void:
	fastapi_url_label.text = ApiClient.base_url
	web_url_label.text = ApiClient.web_url


func _refresh_pills() -> void:
	_apply_pill(fastapi_dot, fastapi_status_label, ApiClient.fastapi_status)
	_apply_pill(web_dot, web_status_label, ApiClient.web_status)
	# Continue is gated on BOTH services being reachable — anything that
	# clicks past this page will hit one or the other immediately.
	continue_button.disabled = not (
		ApiClient.fastapi_status == ApiClient.Status.OK
		and ApiClient.web_status == ApiClient.Status.OK
	)


func _apply_pill(dot: ColorRect, label: Label, status: int) -> void:
	match status:
		ApiClient.Status.OK:
			dot.color = DOT_OK
			label.text = "Online"
			label.add_theme_color_override("font_color", DOT_OK)
		ApiClient.Status.OFFLINE:
			dot.color = DOT_OFFLINE
			label.text = "Unreachable"
			label.add_theme_color_override("font_color", DOT_OFFLINE)
		_:
			dot.color = DOT_CONNECTING
			label.text = "Checking…"
			label.add_theme_color_override("font_color", DOT_CONNECTING)
