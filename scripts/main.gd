extends Control

# Unified home page. Everything that used to be split across the landing
# page, login, rider picker, and main menu now lives here as tabs:
#
#   Ride    — Solo / Create / Join (needs auth + a selected rider)
#   Rider   — pick which rider to ride as (needs auth)
#   Garage  — view the selected rider's equipped loadout (read-only)
#   Account — signed-in user + logout, or an inline login form
#   System  — server status + recheck, dev menu, settings
#
# UI is constructed in code (same approach as course_picker.gd) rather
# than a .tscn — the page is highly dynamic (login-vs-signed-in swap,
# rider list, garage display, status dots) and code-built avoids a huge
# brittle scene file.
#
# Tab gating:
#   System  — always enabled (you need it to fix server URLs when down)
#   Account — always enabled (you need it to log in)
#   Rider   — enabled when authenticated
#   Garage  — enabled when authenticated AND a rider is selected
#   Ride    — enabled when authenticated AND a rider is selected

const TAB_RIDE := 0
const TAB_RIDER := 1
const TAB_GARAGE := 2
const TAB_ACCOUNT := 3
const TAB_SYSTEM := 4

const DOT_OK := Color(0.30, 0.78, 0.40, 1.0)
const DOT_OFFLINE := Color(0.85, 0.28, 0.28, 1.0)
const DOT_CONNECTING := Color(0.95, 0.75, 0.25, 1.0)

var _busy: bool = false

var _tabs: TabContainer
var _header_identity: Label

# Ride tab
var _solo_button: Button
var _create_button: Button
var _join_button: Button
var _ride_status: Label

# Rider tab
var _rider_list: VBoxContainer
var _rider_status: Label
var _rider_refresh_button: Button

# Garage tab
var _garage_root: VBoxContainer

# Account tab
var _account_root: VBoxContainer
var _email_input: LineEdit
var _password_input: LineEdit
var _account_status: Label

# System tab
var _fastapi_dot: ColorRect
var _fastapi_url_label: Label
var _fastapi_status_label: Label
var _web_dot: ColorRect
var _web_url_label: Label
var _web_status_label: Label


func _ready() -> void:
	_build_ui()
	# Wipe stale game state from a prior session, keep the picked rider.
	GameSession.reset()
	ApiClient.connection_status_changed.connect(_on_connection_status_changed)
	ApiClient.auth_expired.connect(_on_auth_expired)
	_refresh_status()
	_apply_auth_state()
	if ApiClient.is_authenticated():
		_load_riders()
		# Cached profile fields may be empty on a post-upgrade first launch.
		if ApiClient.user_display_name.is_empty() and ApiClient.user_email.is_empty():
			_fetch_user_async()


func _fetch_user_async() -> void:
	await ApiClient.get_me()
	if is_inside_tree():
		_update_header_identity()
		_rebuild_account_tab()


# --- UI construction ---

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	# Header row: title left, signed-in cue right.
	var header := HBoxContainer.new()
	root.add_child(header)

	var title := Label.new()
	title.text = "GOTTA BIKE FAST"
	title.add_theme_font_size_override("font_size", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	_header_identity = Label.new()
	_header_identity.add_theme_font_size_override("font_size", 14)
	_header_identity.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_header_identity)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_tabs)

	# Insertion order must match the TAB_* constants.
	_tabs.add_child(_build_ride_tab())
	_tabs.add_child(_build_rider_tab())
	_tabs.add_child(_build_garage_tab())
	_tabs.add_child(_build_account_tab())
	_tabs.add_child(_build_system_tab())


func _build_ride_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "Ride"
	root.add_theme_constant_override("separation", 16)

	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 12)
	root.add_child(pad)

	_solo_button = _big_button("Solo Ride")
	_solo_button.pressed.connect(_on_solo_pressed)
	root.add_child(_solo_button)

	_create_button = _big_button("Create Game")
	_create_button.pressed.connect(_on_create_pressed)
	root.add_child(_create_button)

	_join_button = _big_button("Join Game")
	_join_button.pressed.connect(_on_join_pressed)
	root.add_child(_join_button)

	_ride_status = Label.new()
	_ride_status.add_theme_font_size_override("font_size", 16)
	_ride_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_ride_status)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	var games_link := Button.new()
	games_link.text = "My Games (web) →"
	games_link.flat = true
	games_link.add_theme_font_size_override("font_size", 14)
	games_link.pressed.connect(_open_games_web)
	root.add_child(games_link)

	return root


func _build_rider_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "Rider"
	root.add_theme_constant_override("separation", 10)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	_rider_list = VBoxContainer.new()
	_rider_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rider_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_rider_list)

	_rider_status = Label.new()
	_rider_status.add_theme_font_size_override("font_size", 14)
	_rider_status.modulate = Color(0.75, 0.78, 0.85)
	root.add_child(_rider_status)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 12)
	root.add_child(button_row)

	_rider_refresh_button = Button.new()
	_rider_refresh_button.text = "Refresh"
	_rider_refresh_button.pressed.connect(_load_riders)
	button_row.add_child(_rider_refresh_button)

	var manage := Button.new()
	manage.text = "Manage riders (web) →"
	manage.flat = true
	manage.pressed.connect(_open_riders_web)
	button_row.add_child(manage)

	return root


func _build_garage_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "Garage"
	root.add_theme_constant_override("separation", 12)

	_garage_root = VBoxContainer.new()
	_garage_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_garage_root.add_theme_constant_override("separation", 10)
	root.add_child(_garage_root)

	var manage := Button.new()
	manage.text = "Manage garage (web) →"
	manage.flat = true
	manage.pressed.connect(_open_garage_web)
	root.add_child(manage)

	return root


func _build_account_tab() -> Control:
	# The root is stable; its children are rebuilt by _rebuild_account_tab
	# whenever auth state changes (login form ⇆ signed-in view).
	_account_root = VBoxContainer.new()
	_account_root.name = "Account"
	_account_root.add_theme_constant_override("separation", 12)
	return _account_root


func _build_system_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "System"
	root.add_theme_constant_override("separation", 14)

	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 8)
	root.add_child(pad)

	# Game server (FastAPI) row.
	var fa := _status_row("Game server")
	_fastapi_dot = fa["dot"]
	_fastapi_url_label = fa["url"]
	_fastapi_status_label = fa["status"]
	fa["recheck"].pressed.connect(func() -> void: ApiClient.ping())
	root.add_child(fa["row"])

	# Profile server (Django) row.
	var web := _status_row("Profile server")
	_web_dot = web["dot"]
	_web_url_label = web["url"]
	_web_status_label = web["status"]
	web["recheck"].pressed.connect(func() -> void: ApiClient.ping_web())
	root.add_child(web["row"])

	var sep := HSeparator.new()
	root.add_child(sep)

	var links := HBoxContainer.new()
	links.add_theme_constant_override("separation", 12)
	root.add_child(links)

	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.pressed.connect(_open_settings)
	links.add_child(settings_btn)

	var dev_btn := Button.new()
	dev_btn.text = "Dev menu"
	dev_btn.flat = true
	dev_btn.pressed.connect(_open_dev_menu)
	links.add_child(dev_btn)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	return root


# --- Small UI builders ---

func _big_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 22)
	b.custom_minimum_size = Vector2(0, 56)
	return b


func _status_row(title: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(16, 16)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.color = DOT_CONNECTING
	row.add_child(dot)

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_theme_constant_override("separation", 0)
	row.add_child(text_box)

	var name_lbl := Label.new()
	name_lbl.text = title
	name_lbl.add_theme_font_size_override("font_size", 18)
	text_box.add_child(name_lbl)

	var url_lbl := Label.new()
	url_lbl.add_theme_font_size_override("font_size", 12)
	url_lbl.modulate = Color(0.6, 0.65, 0.75)
	text_box.add_child(url_lbl)

	var status_lbl := Label.new()
	status_lbl.add_theme_font_size_override("font_size", 14)
	status_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(status_lbl)

	var recheck := Button.new()
	recheck.text = "↻"
	recheck.tooltip_text = "Recheck now"
	recheck.custom_minimum_size = Vector2(36, 0)
	recheck.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(recheck)

	return {
		"row": row, "dot": dot, "url": url_lbl,
		"status": status_lbl, "recheck": recheck,
	}


# --- Auth state + gating ---

func _apply_auth_state() -> void:
	var authed := ApiClient.is_authenticated()
	var has_rider := GameSession.has_rider()
	var ready_to_ride := authed and has_rider

	_tabs.set_tab_disabled(TAB_RIDE, not ready_to_ride)
	_tabs.set_tab_disabled(TAB_RIDER, not authed)
	_tabs.set_tab_disabled(TAB_GARAGE, not ready_to_ride)
	# Account + System always enabled.

	_update_header_identity()
	_rebuild_account_tab()
	_render_garage()

	# Pick a sensible default tab for the current state.
	if not authed:
		_tabs.current_tab = TAB_ACCOUNT
	elif not has_rider:
		_tabs.current_tab = TAB_RIDER
	else:
		_tabs.current_tab = TAB_RIDE


func _update_header_identity() -> void:
	if ApiClient.is_authenticated():
		_header_identity.text = "● %s" % ApiClient.user_label()
		_header_identity.add_theme_color_override("font_color", DOT_OK)
	else:
		_header_identity.text = "● not signed in"
		_header_identity.add_theme_color_override("font_color", Color(0.6, 0.62, 0.7))


# --- Account tab (login ⇆ signed-in) ---

func _rebuild_account_tab() -> void:
	for child in _account_root.get_children():
		child.queue_free()

	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 8)
	_account_root.add_child(pad)

	if ApiClient.is_authenticated():
		_build_signed_in_view()
	else:
		_build_login_form()


func _build_signed_in_view() -> void:
	var who := Label.new()
	who.text = "Signed in as %s" % ApiClient.user_label()
	who.add_theme_font_size_override("font_size", 22)
	_account_root.add_child(who)

	if not ApiClient.user_email.is_empty():
		var email := Label.new()
		email.text = ApiClient.user_email
		email.add_theme_font_size_override("font_size", 14)
		email.modulate = Color(0.7, 0.74, 0.82)
		_account_root.add_child(email)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 12)
	_account_root.add_child(button_row)

	var manage := Button.new()
	manage.text = "Manage account (web) →"
	manage.flat = true
	manage.pressed.connect(_open_account_web)
	button_row.add_child(manage)

	var logout := Button.new()
	logout.text = "Log out"
	logout.pressed.connect(_on_logout_pressed)
	button_row.add_child(logout)


func _build_login_form() -> void:
	var prompt := Label.new()
	prompt.text = "Sign in to choose a rider and ride."
	prompt.add_theme_font_size_override("font_size", 16)
	_account_root.add_child(prompt)

	_email_input = LineEdit.new()
	_email_input.placeholder_text = "Email"
	_email_input.custom_minimum_size = Vector2(320, 0)
	if not ApiClient.user_email.is_empty():
		_email_input.text = ApiClient.user_email
	_account_root.add_child(_email_input)

	_password_input = LineEdit.new()
	_password_input.placeholder_text = "Password"
	_password_input.secret = true
	_password_input.custom_minimum_size = Vector2(320, 0)
	_password_input.text_submitted.connect(func(_t: String) -> void: _on_login_submit())
	_account_root.add_child(_password_input)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 12)
	_account_root.add_child(button_row)

	var submit := Button.new()
	submit.text = "Sign in"
	submit.add_theme_font_size_override("font_size", 18)
	submit.pressed.connect(_on_login_submit)
	button_row.add_child(submit)

	var signup := Button.new()
	signup.text = "Sign up (web) →"
	signup.flat = true
	signup.pressed.connect(func() -> void: OS.shell_open(ApiClient.web_signup_url()))
	button_row.add_child(signup)

	var reset := Button.new()
	reset.text = "Forgot password (web) →"
	reset.flat = true
	reset.pressed.connect(func() -> void: OS.shell_open(ApiClient.web_password_reset_url()))
	button_row.add_child(reset)

	_account_status = Label.new()
	_account_status.add_theme_font_size_override("font_size", 14)
	_account_status.modulate = Color(0.85, 0.6, 0.6)
	_account_root.add_child(_account_status)


func _on_login_submit() -> void:
	if _email_input == null or _password_input == null:
		return
	var email := _email_input.text.strip_edges()
	var password := _password_input.text
	if email.is_empty() or password.is_empty():
		_account_status.text = "Email and password required"
		return
	_account_status.text = "Signing in…"
	var result: Dictionary = await ApiClient.login(email, password)
	if result.is_empty():
		if is_inside_tree():
			_account_status.text = "Invalid email or password"
		return
	# Fresh login → drop any cached rider so the list reflects this user.
	GameSession.clear_rider()
	_apply_auth_state()
	_load_riders()


func _on_logout_pressed() -> void:
	ApiClient.logout()
	GameSession.clear_rider()
	GameSession.reset()
	_render_riders([])
	_apply_auth_state()


func _on_auth_expired() -> void:
	# The cached session is fully expired (access + refresh both dead).
	# ApiClient has already cleared its tokens; mirror that here so the
	# page drops cleanly to the login form instead of showing "signed
	# in" with an empty rider list.
	GameSession.clear_rider()
	GameSession.reset()
	_render_riders([])
	_apply_auth_state()
	if _account_status != null and is_instance_valid(_account_status):
		_account_status.text = "Your session expired — please sign in again."


# --- Rider tab ---

func _load_riders() -> void:
	if not ApiClient.is_authenticated():
		return
	_rider_status.text = "Loading riders…"
	_rider_refresh_button.disabled = true
	var riders: Array = await ApiClient.list_riders()
	_rider_refresh_button.disabled = false
	if not is_inside_tree():
		return
	_rider_status.text = ""
	_render_riders(riders)


func _render_riders(riders: Array) -> void:
	for child in _rider_list.get_children():
		child.queue_free()
	if riders.is_empty():
		var empty := Label.new()
		empty.text = "No riders yet — create one with “Manage riders (web)”."
		empty.add_theme_font_size_override("font_size", 16)
		empty.modulate = Color(0.8, 0.8, 0.85)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_rider_list.add_child(empty)
		return
	for r in riders:
		_rider_list.add_child(_build_rider_row(r))


func _build_rider_row(rider: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	margin.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = "%s · %s" % [
		str(rider.get("display_name", "?")),
		str(rider.get("rider_type", "virtual")).capitalize(),
	]
	name_lbl.add_theme_font_size_override("font_size", 20)
	info.add_child(name_lbl)

	var stats := Label.new()
	stats.text = "%.1f kg · %.2f m · FTP %d W" % [
		float(rider.get("weight_kg", 0.0)),
		float(rider.get("height_m", 0.0)),
		int(rider.get("ftp_w", 0)),
	]
	stats.add_theme_font_size_override("font_size", 15)
	info.add_child(stats)

	var loadout := Label.new()
	loadout.text = _rider_loadout_line(rider)
	loadout.add_theme_font_size_override("font_size", 13)
	loadout.modulate = Color(0.75, 0.78, 0.85)
	info.add_child(loadout)

	var is_active := str(rider.get("id", "")) == GameSession.rider_id
	var select_btn := Button.new()
	select_btn.text = "✓ Active" if is_active else "Select"
	select_btn.disabled = is_active
	select_btn.add_theme_font_size_override("font_size", 16)
	select_btn.custom_minimum_size = Vector2(120, 0)
	var captured := rider.duplicate()
	select_btn.pressed.connect(func() -> void: _select_rider(captured))
	hbox.add_child(select_btn)

	return panel


func _rider_loadout_line(rider: Dictionary) -> String:
	var b: String = "stock"
	var w: String = "stock"
	var t: String = "stock"
	var bike: Variant = rider.get("bike")
	var wheels: Variant = rider.get("wheels")
	var tires: Variant = rider.get("tires")
	if bike is Dictionary:
		b = str((bike as Dictionary).get("name", "stock"))
	if wheels is Dictionary:
		w = str((wheels as Dictionary).get("name", "stock"))
	if tires is Dictionary:
		t = str((tires as Dictionary).get("name", "stock"))
	return "Bike: %s · Wheels: %s · Tires: %s" % [b, w, t]


func _select_rider(rider: Dictionary) -> void:
	if _busy:
		return
	GameSession.set_rider(rider)
	# Close out any rides left active by a prior crash / force-quit for
	# this rider so "My Rides" reflects truth immediately.
	_rider_status.text = "Cleaning up prior rides…"
	await _auto_finalize_active(str(rider.get("id", "")))
	if not is_inside_tree():
		return
	_rider_status.text = "Riding as %s" % GameSession.rider_display_name
	# Re-render the list so the active marker moves, refresh the garage,
	# unlock the Ride + Garage tabs, and jump the user to Ride.
	_render_riders_from_cache_marker()
	_render_garage()
	_tabs.set_tab_disabled(TAB_RIDE, false)
	_tabs.set_tab_disabled(TAB_GARAGE, false)
	_tabs.current_tab = TAB_RIDE


func _render_riders_from_cache_marker() -> void:
	# Cheap re-mark: re-pull the list so the ✓ Active button tracks the
	# new selection. (The list is small; a refetch is fine and also picks
	# up any edits made on the web in the meantime.)
	_load_riders()


func _auto_finalize_active(rider_id: String) -> void:
	if rider_id.is_empty():
		return
	var active: Array = await ApiClient.list_active_rides(rider_id)
	for r in active:
		var rid := str(r.get("id", ""))
		if rid.is_empty():
			continue
		await ApiClient.finish_ride(rid, {}, "app_relaunch")


# --- Garage tab ---

func _render_garage() -> void:
	for child in _garage_root.get_children():
		child.queue_free()
	if not GameSession.has_rider():
		var hint := Label.new()
		hint.text = "Select a rider on the Rider tab to see its loadout."
		hint.add_theme_font_size_override("font_size", 16)
		hint.modulate = Color(0.8, 0.8, 0.85)
		_garage_root.add_child(hint)
		return

	var heading := Label.new()
	heading.text = "Loadout for %s" % GameSession.rider_display_name
	heading.add_theme_font_size_override("font_size", 20)
	_garage_root.add_child(heading)

	_garage_root.add_child(_garage_row(
		"Bike", GameSession.rider_bike,
		["mass_kg", "cda_m2"], ["kg", "m² CdA"]
	))
	_garage_root.add_child(_garage_row(
		"Wheels", GameSession.rider_wheels,
		["mass_kg", "depth_mm"], ["kg", "mm deep"]
	))
	_garage_root.add_child(_garage_row(
		"Tires", GameSession.rider_tires,
		["size_mm", "crr"], ["mm", "Crr"]
	))


func _garage_row(slot: String, item: Dictionary, keys: Array, units: Array) -> PanelContainer:
	var panel := PanelContainer.new()
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	margin.add_child(hbox)

	var slot_lbl := Label.new()
	slot_lbl.text = slot
	slot_lbl.add_theme_font_size_override("font_size", 16)
	slot_lbl.custom_minimum_size = Vector2(80, 0)
	slot_lbl.modulate = Color(0.7, 0.74, 0.82)
	hbox.add_child(slot_lbl)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info)

	var name_lbl := Label.new()
	if item.is_empty():
		name_lbl.text = "(stock)"
		name_lbl.modulate = Color(0.7, 0.7, 0.75)
	else:
		var brand := str(item.get("brand", ""))
		var nm := str(item.get("name", "?"))
		name_lbl.text = ("%s %s" % [brand, nm]).strip_edges()
	name_lbl.add_theme_font_size_override("font_size", 18)
	info.add_child(name_lbl)

	if not item.is_empty():
		var bits: Array[String] = []
		for i in keys.size():
			var k: String = keys[i]
			if item.has(k):
				bits.append("%s %s" % [str(item[k]), units[i]])
		if not bits.is_empty():
			var spec := Label.new()
			spec.text = " · ".join(bits)
			spec.add_theme_font_size_override("font_size", 13)
			spec.modulate = Color(0.72, 0.75, 0.82)
			info.add_child(spec)

	return panel


# --- System tab (status) ---

func _on_connection_status_changed(_service: String, _status: int) -> void:
	_refresh_status()


func _refresh_status() -> void:
	_fastapi_url_label.text = ApiClient.base_url
	_web_url_label.text = ApiClient.web_url
	_apply_status(_fastapi_dot, _fastapi_status_label, ApiClient.fastapi_status)
	_apply_status(_web_dot, _web_status_label, ApiClient.web_status)


func _apply_status(dot: ColorRect, label: Label, status: int) -> void:
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


# SSO-bridged web links — named methods (rather than inline await
# lambdas) so the coroutine runs cleanly off the button signal.
func _open_games_web() -> void:
	await ApiClient.open_web_link("/games/")


func _open_riders_web() -> void:
	await ApiClient.open_web_link("/riders/")


func _open_garage_web() -> void:
	await ApiClient.open_web_link("/garage/")


func _open_account_web() -> void:
	await ApiClient.open_web_link("/accounts/account/")


func _open_settings() -> void:
	get_tree().change_scene_to_file("res://scenes/settings.tscn")


func _open_dev_menu() -> void:
	GameSession.dev_menu_return_scene = "res://scenes/main.tscn"
	get_tree().change_scene_to_file("res://scenes/dev_menu.tscn")


# --- Ride tab handlers ---

func _set_ride_busy(busy: bool, message: String = "") -> void:
	_busy = busy
	_solo_button.disabled = busy
	_create_button.disabled = busy
	_join_button.disabled = busy
	_ride_status.text = message


func _on_solo_pressed() -> void:
	if _busy:
		return
	GameSession.is_solo = true
	get_tree().change_scene_to_file("res://scenes/ride.tscn")


func _on_create_pressed() -> void:
	if _busy:
		return
	_set_ride_busy(true, "Loading courses…")
	var courses: Array = await ApiClient.list_courses()
	if courses.is_empty():
		_set_ride_busy(false, "No courses available")
		return

	var picker := CoursePicker.new()
	add_child(picker)
	var chosen: Dictionary = await picker.pick(courses)
	picker.queue_free()
	if chosen.is_empty():
		_set_ride_busy(false, "")
		return

	var cd_picker := CountdownPicker.new()
	add_child(cd_picker)
	var start_opt: Dictionary = await cd_picker.pick()
	cd_picker.queue_free()

	_set_ride_busy(true, "Creating game…")
	var game: Dictionary = await ApiClient.create_game(
		GameSession.rider_id,
		GameSession.rider_display_name,
		str(chosen["id"]),
		int(start_opt.get("countdown_duration_s", 30)),
		int(start_opt.get("scheduled_start_in_s", -1)),
	)
	if game.is_empty():
		_set_ride_busy(false, "Failed to create game")
		return

	GameSession.code = str(game["code"])
	GameSession.host_rider_id = str(game["host_rider_id"])
	GameSession.course = {
		"id": str(game["course_id"]),
		"name": game.get("course_name", ""),
		"length_m": float(game.get("course_length_m", 0.0)),
	}
	GameSession.participants = game.get("participants", [])
	GameSession.state = str(game.get("state", "LOBBY"))
	GameSession.scheduled_start_at_unix_s = GameSession.parse_iso_to_unix(
		str(game.get("scheduled_start_at", ""))
	)
	GameSession.is_solo = false
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")


func _on_join_pressed() -> void:
	if _busy:
		return
	get_tree().change_scene_to_file("res://scenes/join.tscn")
