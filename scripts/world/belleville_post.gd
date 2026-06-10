class_name BellevillePost
extends CanvasLayer

# Full-screen post-process that turns the 3D render into a hand-drawn,
# aged-paper picture — the visual core of the Belleville theme. A single
# canvas_item shader on a screen-filling ColorRect does it all:
#   - luma Sobel  -> ink contour lines on edges
#   - posterize   -> flat, painted bands instead of smooth gradients
#   - warm grade  -> a gentle sepia/ochre duotone over the (already muted) scene
#   - paper grain -> static film/paper texture
#   - vignette    -> darkened corners, like an old print
#
# It sits one layer below the HUD (default CanvasLayer layer = 1) so the stats
# stay crisp and only the world gets the treatment. The screen texture it
# samples is the 3D render, because at layer 0 nothing else has drawn yet.
#
# Cost: a 9-tap screen read per pixel, every frame. Being a CanvasLayer it
# composites in 2D, so it always runs at OUTPUT resolution — the render_scale
# / FSR2 setting only scales the 3D buffer, not this pass. ride_controller
# therefore skips it at the LOW quality preset (the muted palette + caricature
# carry the theme without the per-pixel ink cost).

const SHADER_CODE := "
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float edge_strength = 2.6;
uniform float edge_threshold = 0.045;
uniform float edge_radius = 1.4;
uniform float posterize_levels = 5.0;
uniform float sepia_amount = 0.46;
uniform float grain_amount = 0.06;
uniform float vignette_amount = 0.42;
uniform vec3 ink : source_color = vec3(0.12, 0.10, 0.08);
uniform vec3 shadow_col : source_color = vec3(0.18, 0.16, 0.13);
uniform vec3 mid_col : source_color = vec3(0.55, 0.45, 0.27);
uniform vec3 high_col : source_color = vec3(0.89, 0.85, 0.74);

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE * edge_radius;
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;

	// Sobel on luma over the 8 neighbours -> contour edges.
	float l00 = luma(texture(screen_tex, SCREEN_UV + px * vec2(-1.0, -1.0)).rgb);
	float l10 = luma(texture(screen_tex, SCREEN_UV + px * vec2(0.0, -1.0)).rgb);
	float l20 = luma(texture(screen_tex, SCREEN_UV + px * vec2(1.0, -1.0)).rgb);
	float l01 = luma(texture(screen_tex, SCREEN_UV + px * vec2(-1.0, 0.0)).rgb);
	float l21 = luma(texture(screen_tex, SCREEN_UV + px * vec2(1.0, 0.0)).rgb);
	float l02 = luma(texture(screen_tex, SCREEN_UV + px * vec2(-1.0, 1.0)).rgb);
	float l12 = luma(texture(screen_tex, SCREEN_UV + px * vec2(0.0, 1.0)).rgb);
	float l22 = luma(texture(screen_tex, SCREEN_UV + px * vec2(1.0, 1.0)).rgb);
	float gx = (l20 + 2.0 * l21 + l22) - (l00 + 2.0 * l01 + l02);
	float gy = (l02 + 2.0 * l12 + l22) - (l00 + 2.0 * l10 + l20);
	float grad = sqrt(gx * gx + gy * gy);
	float edge = clamp((grad - edge_threshold) * edge_strength, 0.0, 1.0);

	// Posterize into painted bands.
	vec3 p = floor(c * posterize_levels + 0.5) / posterize_levels;

	// Warm duotone grade keyed on luminance, mixed in gently so the muted
	// scene palette still shows through.
	float L = luma(p);
	vec3 graded = (L < 0.5)
		? mix(shadow_col, mid_col, L * 2.0)
		: mix(mid_col, high_col, (L - 0.5) * 2.0);
	vec3 col = mix(p, graded, sepia_amount);

	// Ink the contours.
	col = mix(col, ink, edge);

	// Paper grain (static — animating it would shimmer).
	float g = hash(SCREEN_UV / max(px.x, 0.0001) * 0.5);
	col += (g - 0.5) * grain_amount;

	// Vignette.
	float d = distance(SCREEN_UV, vec2(0.5));
	col *= 1.0 - smoothstep(0.45, 0.9, d) * vignette_amount;

	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
"


func _init() -> void:
	name = "BellevillePost"
	# One below the HUD (its CanvasLayer defaults to layer 1) so stats stay
	# untouched; still above the 3D, which is what the screen texture captures.
	layer = 0


func _ready() -> void:
	var shader := Shader.new()
	shader.code = SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader

	var rect := ColorRect.new()
	rect.material = mat
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE  # never eat ride input
	add_child(rect)
