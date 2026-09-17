extends Node3D
# Color-space probe: which space does a renderer do shader math in?
# Four unshaded quads side by side, each meant to display Belleville.OLIVE:
#   0  StandardMaterial3D albedo_color
#   1  ShaderMaterial `source_color` uniform → ALBEDO
#   2  ShaderMaterial `source_color` sampler (1×1 OLIVE ImageTexture) → ALBEDO
#   3  StandardMaterial3D albedo_texture (same 1×1 texture)
# plus an L8 texture holding 0.5 passed straight to ALBEDO — the tell:
# a linear pipeline encodes it for display as ~(187,187,187), a gamma-space
# one (the browser's Compatibility renderer) shows ~(127,127,127).
# Linear tonemapper, no adjustments, so a correct pipeline shows OLIVE
# (111,122,78) on every color quad. Prints the readings, then quits.
# (For the terrain shader itself, use terrain_shader_probe.tscn.)
#   Godot --path . --rendering-method <m> res://tools/colorspace_probe.tscn

const SHADER_UNIFORM := "
shader_type spatial;
render_mode unshaded;
uniform vec3 c : source_color;
void fragment() { ALBEDO = c; }
"
const SHADER_SAMPLER := "
shader_type spatial;
render_mode unshaded;
uniform sampler2D t : source_color, filter_nearest;
void fragment() { ALBEDO = texture(t, UV).rgb; }
"


func _ready() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Belleville.OLIVE)
	var tex := ImageTexture.create_from_image(img)

	var mats: Array[Material] = []
	var m0 := StandardMaterial3D.new()
	m0.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m0.albedo_color = Belleville.OLIVE
	mats.append(m0)
	var m1 := ShaderMaterial.new()
	m1.shader = Shader.new()
	m1.shader.code = SHADER_UNIFORM
	m1.set_shader_parameter("c", Belleville.OLIVE)
	mats.append(m1)
	var m2 := ShaderMaterial.new()
	m2.shader = Shader.new()
	m2.shader.code = SHADER_SAMPLER
	m2.set_shader_parameter("t", tex)
	mats.append(m2)
	var m3 := StandardMaterial3D.new()
	m3.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m3.albedo_texture = tex
	m3.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mats.append(m3)

	for i in mats.size():
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.4, 0.4)
		q.mesh = qm
		q.material_override = mats[i]
		q.position = Vector3((float(i) - 1.5) * 0.5, 0.3, 0)
		add_child(q)

	# L8 noise-style texture holding 0.5 everywhere → shader shows it as grey.
	var l8 := Image.create(4, 4, true, Image.FORMAT_L8)
	l8.fill(Color(0.5, 0.5, 0.5))
	l8.generate_mipmaps()
	var l8m := ShaderMaterial.new()
	l8m.shader = Shader.new()
	l8m.shader.code = "shader_type spatial;\nrender_mode unshaded;\nuniform sampler2D t : filter_linear_mipmap, repeat_enable;\nvoid fragment() { float v = texture(t, UV).r; ALBEDO = vec3(v, texture(t, UV).g, texture(t, UV).b); }"
	l8m.set_shader_parameter("t", ImageTexture.create_from_image(l8))
	var lq := MeshInstance3D.new()
	var lqm := QuadMesh.new()
	lqm.size = Vector2(0.4, 0.4)
	lq.mesh = lqm
	lq.material_override = l8m
	lq.position = Vector3(-0.75, -0.3, 0)
	add_child(lq)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.2
	cam.position = Vector3(0, 0, 5)
	add_child(cam)
	cam.current = true
	_read()


func _read() -> void:
	for _i in 8:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var w := img.get_width()
	var h := img.get_height()
	var names := ["std color", "shader uniform", "shader sampler", "std texture"]
	var line := "COLORSPACE %s |" % RenderingServer.get_current_rendering_method()
	for i in 4:
		var px := img.get_pixel(_px_x(w, h, (float(i) - 1.5) * 0.5), _px_y(h, 0.3))
		line += " %s=(%d,%d,%d)" % [names[i], px.r8, px.g8, px.b8]
	var l8px := img.get_pixel(_px_x(w, h, -0.75), _px_y(h, -0.3))
	line += " L8(0.5)=(%d,%d,%d)" % [l8px.r8, l8px.g8, l8px.b8]
	print(line)
	get_tree().quit()


func _px_x(w: int, h: int, world_x: float) -> int:
	var half_w := 0.6 * float(w) / float(h)
	return clampi(int((world_x + half_w) / (2.0 * half_w) * float(w)), 0, w - 1)


func _px_y(h: int, world_y: float) -> int:
	return clampi(int((0.6 - world_y) / 1.2 * float(h)), 0, h - 1)
