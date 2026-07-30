extends Node3D
# Screenshot harness for BuildingFactory: one of each variety in a row under
# Belleville lighting, framed by a fixed camera; saves a PNG and quits.
# Run windowed (rendering needs a real display):
#   Godot --path . res://tools/building_showcase.tscn -- --shot=/tmp/out.png

const SPACING := 17.0


func _ready() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Belleville.PAPER
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Belleville.PAPER_LIGHT
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 35, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)

	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(240, 140)
	ground.mesh = pm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Belleville.OLIVE.darkened(0.1)
	gmat.roughness = 1.0
	ground.material_override = gmat
	add_child(ground)

	var tints: Array = [
		Belleville.PAPER,
		Belleville.OCHRE.lerp(Belleville.PAPER, 0.3),
		Belleville.TERRACOTTA.lerp(Belleville.PAPER, 0.45),
		Belleville.PAPER_LIGHT,
		Belleville.UMBER.lerp(Belleville.TERRACOTTA, 0.3),
	]
	for v in BuildingFactory.VARIETY_COUNT:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = BuildingFactory.variety_mesh(v)
		mm.instance_count = 1
		# Fronts (+X) turned to the camera (+Z), with the Belleville wobble.
		var yaw := -PI / 2.0 + deg_to_rad(6.0) * float(v - 2)
		var basis := Basis.from_euler(Vector3(0.015, yaw, -0.02))
		var x := SPACING * (float(v) - float(BuildingFactory.VARIETY_COUNT - 1) / 2.0)
		mm.set_instance_transform(0, Transform3D(basis, Vector3(x, 0, 0)))
		mm.set_instance_color(0, tints[v])
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = mm
		add_child(inst)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 10, 46)
	add_child(cam)
	cam.look_at(Vector3(0, 4.0, 0))
	cam.current = true

	_shoot()


func _shoot() -> void:
	for _i in 6:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var path := "user://building_showcase.png"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			path = arg.substr(7)
	img.save_png(path)
	print("SHOT_SAVED ", path)
	get_tree().quit()
