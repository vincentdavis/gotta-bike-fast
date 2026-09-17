extends Node3D
# Terrain-shader probe: the REAL TerrainMaterial on a flat 400 m plane,
# viewed straight down by an orthographic camera. --unshaded swaps in an
# unshaded copy of the shader so lighting is out of the picture; otherwise a
# plain sun + flat ambient light it. Prints luminance stats, saves a PNG.
#   Godot --path . --rendering-method <m> res://tools/terrain_shader_probe.tscn \
#     -- --shot=/abs/out.png [--unshaded]


func _ready() -> void:
	var unshaded := OS.get_cmdline_user_args().has("--unshaded")
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.MAGENTA
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.5)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	if not unshaded:
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-60, 30, 0)
		add_child(sun)

	var mat := TerrainMaterial.build()
	if unshaded:
		var sh := Shader.new()
		sh.code = TerrainMaterial.SHADER_CODE.replace(
			"render_mode cull_disabled;", "render_mode cull_disabled, unshaded;"
		)
		mat.shader = sh
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	plane.mesh = pm
	plane.material_override = mat
	add_child(plane)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 200.0
	cam.position = Vector3(0, 50, 0)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	add_child(cam)
	cam.current = true
	_read(unshaded)


func _read(unshaded: bool) -> void:
	for _i in 8:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var lums := PackedFloat32Array()
	var seen := {}
	for y in range(0, img.get_height(), 3):
		for x in range(0, img.get_width(), 3):
			var c := img.get_pixel(x, y)
			lums.append(c.get_luminance())
			seen[Vector3i(c.r8, c.g8, c.b8)] = true
	lums.sort()
	var n := lums.size()
	print("TSHADER %s %s lum p5=%.3f p25=%.3f p50=%.3f p75=%.3f p95=%.3f distinct=%d" % [
		RenderingServer.get_current_rendering_method(),
		"unshaded" if unshaded else "lit",
		lums[int(n * 0.05)], lums[int(n * 0.25)], lums[n / 2],
		lums[int(n * 0.75)], lums[int(n * 0.95)], seen.size(),
	])
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			img.save_png(arg.substr(7))
	get_tree().quit()
