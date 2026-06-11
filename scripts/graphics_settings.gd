extends Node

# Graphics preferences — device-local (they depend on this machine's GPU /
# display, so they live in user://graphics.cfg rather than the server-side
# account preferences). Applied at startup and live when changed from the
# Settings screen:
#
#   quality       LOW / MEDIUM / HIGH preset gating the expensive ride
#                 effects (SSR, volumetric fog, SSAO, glow, shadow splits).
#                 The ride builds its Environment at HIGH and then calls
#                 apply_environment_quality()/apply_sun_quality() to
#                 downgrade, so it takes effect on the next ride.
#   render_scale  0.5–1.0 of output resolution for the 3D scene; below 1.0
#                 we upscale with FSR 2, so "render 1080p, output 4K" looks
#                 far better than running the panel at native 1080p. UI is
#                 unaffected (always native).
#   frame_limit   VSync (default) / 60 / 30 (quiet) / uncapped. Sessions run
#                 for an hour next to the rider — capping fps is as much
#                 about fan noise and heat as performance.
#   fullscreen    fullscreen vs windowed.
#   show_fps      small always-on-top fps readout to sanity-check settings.
#
# Defaults match the game's behaviour before this autoload existed (HIGH,
# native scale, vsync, windowed) so existing installs see no change.

enum Quality { LOW, MEDIUM, HIGH }
enum FrameLimit { VSYNC, FPS_60, FPS_30, UNCAPPED }

const FILE := "user://graphics.cfg"

var quality: int = Quality.HIGH
var render_scale: float = 1.0
var frame_limit: int = FrameLimit.VSYNC
var fullscreen: bool = false
var show_fps: bool = false

var _fps_layer: CanvasLayer = null
var _fps_label: Label = null
var _fps_accum: float = 0.0


func _ready() -> void:
	_load()
	apply_all()


# --- public setters (apply + persist immediately) ---

func set_quality(value: int) -> void:
	quality = clampi(value, Quality.LOW, Quality.HIGH)
	_save()
	# Takes effect when the next ride builds its Environment.


func set_render_scale(value: float) -> void:
	render_scale = clampf(value, 0.5, 1.0)
	_apply_render_scale()
	_save()


func set_frame_limit(value: int) -> void:
	frame_limit = clampi(value, FrameLimit.VSYNC, FrameLimit.UNCAPPED)
	_apply_frame_limit()
	_save()


func set_fullscreen(value: bool) -> void:
	fullscreen = value
	_apply_window_mode()
	_save()


func set_show_fps(value: bool) -> void:
	show_fps = value
	_apply_fps_overlay()
	_save()


# --- ride-quality hooks ---
# The ride controller builds its Environment / sun with the HIGH settings it
# always used, then hands them here to be downgraded per the preset. HIGH is
# a deliberate no-op so the visuals stay byte-identical to pre-settings
# builds. Dropping SSR + volumetric fog (MEDIUM) removes the two most
# expensive effects; LOW also sheds SSAO, glow, and most of the shadow cost.

func apply_environment_quality(env: Environment) -> void:
	if quality == Quality.HIGH:
		return
	env.ssr_enabled = false
	env.volumetric_fog_enabled = false
	# The cheap exponential fog was a thin safety net behind the volumetric
	# fog; thicken it slightly so distance still fades out.
	env.fog_density = 0.0012
	if quality == Quality.LOW:
		env.ssao_enabled = false
		env.glow_enabled = false


func apply_sun_quality(sun: DirectionalLight3D) -> void:
	if quality == Quality.HIGH:
		return
	if quality == Quality.MEDIUM:
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		sun.directional_shadow_max_distance = 150.0
	else:  # LOW — single cascade, short range; keeps grounding without the cost
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.directional_shadow_max_distance = 100.0
		sun.shadow_blur = 1.0


func tree_count() -> int:
	# Roadside scenery density for _setup_scenery — the per-tree cost is
	# small (MultiMesh), but vertex + overdraw load still scales with count.
	match quality:
		Quality.LOW: return 160
		Quality.MEDIUM: return 320
		_: return 520


func quality_name() -> String:
	match quality:
		Quality.LOW: return "Low"
		Quality.MEDIUM: return "Medium"
		_: return "High"


# --- application ---

func apply_all() -> void:
	_apply_frame_limit()
	_apply_window_mode()
	_apply_render_scale()
	_apply_fps_overlay()


func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


func _apply_frame_limit() -> void:
	match frame_limit:
		FrameLimit.VSYNC:
			Engine.max_fps = 0
		FrameLimit.FPS_60:
			Engine.max_fps = 60
		FrameLimit.FPS_30:
			Engine.max_fps = 30
		FrameLimit.UNCAPPED:
			Engine.max_fps = 0
	if _is_headless():
		return
	# VSync stays ON for every capped mode (no tearing; the cap just lowers
	# the rate below the display's). Only "uncapped" turns it off.
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_DISABLED if frame_limit == FrameLimit.UNCAPPED
		else DisplayServer.VSYNC_ENABLED
	)


func _apply_window_mode() -> void:
	if _is_headless():
		return
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen
		else DisplayServer.WINDOW_MODE_WINDOWED
	)


func _apply_render_scale() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	vp.scaling_3d_scale = render_scale
	# FSR 2 reconstructs detail when rendering below output resolution;
	# at native scale plain bilinear (a no-op at 1.0) avoids its overhead.
	vp.scaling_3d_mode = (
		Viewport.SCALING_3D_MODE_FSR2 if render_scale < 0.999
		else Viewport.SCALING_3D_MODE_BILINEAR
	)


# --- fps overlay ---

func _apply_fps_overlay() -> void:
	if show_fps and _fps_layer == null:
		_fps_layer = CanvasLayer.new()
		_fps_layer.layer = 100
		_fps_label = Label.new()
		_fps_label.add_theme_font_size_override("font_size", 14)
		_fps_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
		_fps_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		_fps_label.add_theme_constant_override("outline_size", 3)
		_fps_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_fps_label.offset_left = -90.0
		_fps_label.offset_top = 6.0
		_fps_label.offset_right = -8.0
		_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_fps_layer.add_child(_fps_label)
		add_child(_fps_layer)
	elif not show_fps and _fps_layer != null:
		_fps_layer.queue_free()
		_fps_layer = null
		_fps_label = null
	set_process(show_fps)


func _process(delta: float) -> void:
	_fps_accum += delta
	if _fps_accum < 0.25:
		return
	_fps_accum = 0.0
	if _fps_label != null:
		_fps_label.text = "%d fps" % int(Engine.get_frames_per_second())


# --- persistence ---

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(FILE) != OK:
		return
	quality = clampi(int(cfg.get_value("graphics", "quality", Quality.HIGH)), Quality.LOW, Quality.HIGH)
	render_scale = clampf(float(cfg.get_value("graphics", "render_scale", 1.0)), 0.5, 1.0)
	frame_limit = clampi(int(cfg.get_value("graphics", "frame_limit", FrameLimit.VSYNC)), FrameLimit.VSYNC, FrameLimit.UNCAPPED)
	fullscreen = bool(cfg.get_value("graphics", "fullscreen", false))
	show_fps = bool(cfg.get_value("graphics", "show_fps", false))


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("graphics", "quality", quality)
	cfg.set_value("graphics", "render_scale", render_scale)
	cfg.set_value("graphics", "frame_limit", frame_limit)
	cfg.set_value("graphics", "fullscreen", fullscreen)
	cfg.set_value("graphics", "show_fps", show_fps)
	cfg.save(FILE)
