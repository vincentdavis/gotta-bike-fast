class_name TerrainMaterial
extends RefCounted

# Shared ground shader for the heightmap terrain mesh and the path-following
# ground strip. Replaces the flat green albedo with:
#   - grass tones broken up by world-space noise at three scales (no UVs —
#     the meshes are built in world coordinates, so we sample by position
#     and adjacent meshes match seamlessly)
#   - dry/yellowed macro patches so big hillsides aren't one green
#   - rock blended in by slope (terrain normals), so steep faces on real
#     GPX mountains read as rock instead of vertical lawn
#
# The five palette colors and a posterize control are uniforms, so build()
# can swap in the muted olive/ochre/umber Belleville palette (and flatten the
# shading into painted bands) without a second shader. Cheap: one texture
# fetch ×3, no lighting changes — safe at every quality preset.

const SHADER_CODE := "
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 grass_lo : source_color = vec3(0.13, 0.25, 0.09);
uniform vec3 grass_hi : source_color = vec3(0.27, 0.42, 0.16);
uniform vec3 dry_col : source_color = vec3(0.36, 0.35, 0.17);
uniform vec3 rock_lo : source_color = vec3(0.24, 0.21, 0.18);
uniform vec3 rock_hi : source_color = vec3(0.38, 0.35, 0.31);
uniform float posterize = 0.0;  // 0 = smooth; >0 = quantize to N bands

varying vec3 w_pos;
varying float w_up;

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	w_up = (MODEL_MATRIX * vec4(NORMAL, 0.0)).y;
}

void fragment() {
	float n_macro = texture(noise_tex, w_pos.xz * 0.0045).r;
	float n_mid = texture(noise_tex, w_pos.xz * 0.030).r;
	float n_fine = texture(noise_tex, w_pos.xz * 0.180).r;

	vec3 grass = mix(grass_lo, grass_hi, clamp(n_mid * 0.7 + n_fine * 0.3, 0.0, 1.0));
	grass = mix(grass, dry_col, smoothstep(0.60, 0.86, n_macro) * 0.45);

	vec3 rock = mix(rock_lo, rock_hi, n_fine);
	float slope = 1.0 - clamp(w_up, 0.0, 1.0);
	float rockiness = smoothstep(0.28, 0.55, slope + (n_mid - 0.5) * 0.16);

	vec3 col = mix(grass, rock, rockiness);
	col *= 0.92 + 0.16 * n_fine;  // micro contact-shading breakup
	if (posterize > 0.5) {
		col = floor(col * posterize + 0.5) / posterize;
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
}
"


static func build() -> ShaderMaterial:
	# Generate the noise image synchronously. NoiseTexture2D fills its image
	# on a background thread, and a ShaderMaterial sampler bound before that
	# completes keeps sampling the white fallback forever — which rendered
	# the whole terrain white. get_seamless_image blocks (~tens of ms, once
	# per ride) and gives us a ready texture up front.
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.02
	noise.fractal_octaves = 4
	var img := noise.get_seamless_image(512, 512, false, false, 0.10)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)

	var shader := Shader.new()
	shader.code = SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("noise_tex", tex)

	# Muted sun-faded meadow: olive grass, mustard dry patches, umber rock,
	# quantized into painted bands to match the hand-drawn post-process.
	mat.set_shader_parameter("grass_lo", Belleville.OLIVE.darkened(0.28))
	mat.set_shader_parameter("grass_hi", Belleville.OLIVE.lerp(Belleville.BRONZE, 0.45))
	mat.set_shader_parameter("dry_col", Belleville.BRONZE.lerp(Belleville.OCHRE, 0.4))
	mat.set_shader_parameter("rock_lo", Belleville.UMBER.darkened(0.1))
	mat.set_shader_parameter("rock_hi", Belleville.UMBER.lerp(Belleville.SAGE, 0.35))
	mat.set_shader_parameter("posterize", 6.0)
	return mat
