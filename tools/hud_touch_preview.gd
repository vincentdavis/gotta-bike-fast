extends Node
# Screenshot harness for the HUD's touch controls: instantiates hud.tscn,
# forces the TouchScreenButtons visible (desktops have no touchscreen, so
# VISIBILITY_TOUCHSCREEN_ONLY would hide them), saves a PNG, quits.
#   Godot --path . res://tools/hud_touch_preview.tscn -- --shot=/tmp/out.png


func _ready() -> void:
	var hud: CanvasLayer = load("res://scenes/hud.tscn").instantiate()
	add_child(hud)
	hud.set_course("Flat 5K Loop", 5000.0)
	_force_touch_visible(hud)
	_shoot()


func _force_touch_visible(node: Node) -> void:
	if node is TouchScreenButton:
		node.visibility_mode = TouchScreenButton.VISIBILITY_ALWAYS
		node.visible = true
	for child in node.get_children():
		_force_touch_visible(child)


func _shoot() -> void:
	for _i in 6:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var path := "user://hud_touch_preview.png"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			path = arg.substr(7)
	img.save_png(path)
	print("SHOT_SAVED ", path)
	get_tree().quit()
