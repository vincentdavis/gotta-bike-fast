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
# Cheap: one texture fetch ×3, no lighting changes — safe at every quality
# preset.

const SHADER_CODE := "
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;

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

	// Grass: light/dark mottling, with large dry patches from the macro noise.
	vec3 grass = mix(vec3(0.20, 0.34, 0.15), vec3(0.37, 0.53, 0.24),
		clamp(n_mid * 0.7 + n_fine * 0.3, 0.0, 1.0));
	grass = mix(grass, vec3(0.46, 0.46, 0.25), smoothstep(0.58, 0.85, n_macro) * 0.55);

	// Rock for steep faces.
	vec3 rock = mix(vec3(0.31, 0.28, 0.25), vec3(0.47, 0.44, 0.40), n_fine);
	float slope = 1.0 - clamp(w_up, 0.0, 1.0);
	float rockiness = smoothstep(0.28, 0.55, slope + (n_mid - 0.5) * 0.16);

	vec3 col = mix(grass, rock, rockiness);
	col *= 0.92 + 0.16 * n_fine;  // micro contact-shading breakup
	ALBEDO = col;
	ROUGHNESS = 1.0;
}
"


static func build() -> ShaderMaterial:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.02
	noise.fractal_octaves = 4
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = 512
	tex.height = 512
	tex.seamless = true
	tex.seamless_blend_skirt = 0.10

	var shader := Shader.new()
	shader.code = SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("noise_tex", tex)
	return mat
