extends Control

@onready var status_label: Label = $StatusLabel


func _ready() -> void:
	status_label.text = "Backend: connecting…"
	ApiClient.healthz_received.connect(_on_healthz)


func _on_healthz(ok: bool, body: String) -> void:
	if ok:
		status_label.text = "Backend: OK\nStarting ride…"
		await get_tree().create_timer(0.8).timeout
		get_tree().change_scene_to_file("res://scenes/ride.tscn")
	else:
		status_label.text = "Backend: UNREACHABLE\n%s\n\nIs uvicorn running?" % body
