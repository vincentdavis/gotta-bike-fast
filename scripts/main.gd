extends Control

@onready var status_label: Label = $StatusLabel


func _ready() -> void:
	status_label.text = "Backend: connecting…"
	ApiClient.healthz_received.connect(_on_healthz)


func _on_healthz(ok: bool, body: String) -> void:
	if ok:
		status_label.text = "Backend: OK\n%s" % body
	else:
		status_label.text = "Backend: UNREACHABLE\n%s" % body
