extends Control

@onready var status_label: Label = $StatusLabel


func _ready() -> void:
	status_label.text = "Backend: connecting…"
	ApiClient.healthz_received.connect(_on_healthz)


func _on_healthz(ok: bool, body: String) -> void:
	if not ok:
		status_label.text = "Backend: UNREACHABLE\n%s\n\nIs uvicorn running?" % body
		return
	status_label.text = "Backend: OK"
	await get_tree().create_timer(0.4).timeout
	if not ApiClient.is_authenticated():
		get_tree().change_scene_to_file("res://scenes/login.tscn")
		return
	# Authed but no rider picked yet (or app was just relaunched) → roster.
	if not GameSession.has_rider():
		get_tree().change_scene_to_file("res://scenes/riders.tscn")
		return
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
