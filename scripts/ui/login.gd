extends Control

@onready var email_input: LineEdit = $Center/Panel/Margin/VBox/EmailInput
@onready var password_input: LineEdit = $Center/Panel/Margin/VBox/PasswordInput
@onready var status_label: Label = $Center/Panel/Margin/VBox/StatusLabel
@onready var submit_button: Button = $Center/Panel/Margin/VBox/SubmitButton
@onready var signup_link: Button = $Center/Panel/Margin/VBox/SignupLink
@onready var reset_link: Button = $Center/Panel/Margin/VBox/ResetLink


func _ready() -> void:
	submit_button.pressed.connect(_on_submit)
	signup_link.pressed.connect(_on_signup_browser)
	reset_link.pressed.connect(_on_reset_browser)
	password_input.text_submitted.connect(func(_t: String) -> void: _on_submit())


func _on_submit() -> void:
	var email := email_input.text.strip_edges()
	var password := password_input.text
	if email.is_empty() or password.is_empty():
		status_label.text = "Email and password required"
		return
	submit_button.disabled = true
	status_label.text = "Signing in…"
	var result: Dictionary = await ApiClient.login(email, password)
	submit_button.disabled = false
	if result.is_empty():
		status_label.text = "Invalid email or password"
		return
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_signup_browser() -> void:
	OS.shell_open(ApiClient.web_signup_url())


func _on_reset_browser() -> void:
	OS.shell_open(ApiClient.web_password_reset_url())
