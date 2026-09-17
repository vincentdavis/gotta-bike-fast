extends "res://scripts/world/ride_controller.gd"
# Ground-flicker repro harness: the REAL ride world (ground plane, ground
# strip, road, scenery, towns, sun, Belleville post) built by the real
# ride_controller code on a course JSON from GET /v1/courses/{id}, with the
# rider auto-pedalling and frames captured. No network: the ride never
# registers with the API, and sample flushes are no-ops.
#
# Run it under the browser's renderer to reproduce web-only artifacts:
#   Godot --path . --rendering-method gl_compatibility \
#     res://tools/ground_flicker_probe.tscn -- \
#     --course=/abs/course.json --out=/abs/dir [--frames=8] [--every=1]
#     [--start=400] [--speed=12] [--hide=plane,strip,post,shadows,hud]
#     [--metric=N]  (print in-engine flicker % over N frame pairs)
#     [--view=N]    (camera preset index, 0 = Chase … see camera_rig.gd)
#
# Frames land in --out as f00.png, f01.png, … then the app quits.

var _out := ""
var _frames := 8
var _every := 1
var _warmup := 45
var _tick := 0
var _shot := 0


func _ready() -> void:
	var course_file := ""
	var start_m := 400.0
	var speed := 12.0
	var hide: PackedStringArray = []
	var view := -1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--course="):
			course_file = a.substr(9)
		elif a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--frames="):
			_frames = int(a.substr(9))
		elif a.begins_with("--every="):
			_every = maxi(1, int(a.substr(8)))
		elif a.begins_with("--start="):
			start_m = float(a.substr(8))
		elif a.begins_with("--speed="):
			speed = float(a.substr(8))
		elif a.begins_with("--hide="):
			hide = a.substr(7).split(",")
		elif a.begins_with("--view="):
			view = int(a.substr(7))

	# The ride's _ready, minus _start_solo/_start_game (network) — same order.
	GraphicsSettings.quality = GraphicsSettings.Quality.HIGH  # not saved
	_apply_rider_to_kit()
	_setup_environment()
	_setup_ground()
	_setup_sun()
	_setup_rider()
	_setup_camera()
	_setup_hud()
	if not hide.has("post"):
		add_child(BellevillePost.new())
	hud.apply_appearance()

	var f := FileAccess.open(course_file, FileAccess.READ)
	if f == null:
		push_error("probe: cannot open course %s" % course_file)
		get_tree().quit(2)
		return
	current_course = JSON.parse_string(f.get_as_text())
	hud.set_course(str(current_course["name"]), float(current_course["length_m"]))
	_build_course_visuals()
	_setup_cp_limiter({})

	if hide.has("plane") and _ground_inst != null:
		_ground_inst.visible = false
	if hide.has("strip") and _ground_strip_inst != null:
		_ground_strip_inst.visible = false
	if hide.has("hud"):
		hud.visible = false  # clean pixels for metrics (post is layer 0, unaffected)
	if hide.has("shadows"):
		for child in get_children():
			if child is DirectionalLight3D:
				child.shadow_enabled = false

	if view >= 0 and camera_rig != null and view < camera_rig.view_count():
		_apply_camera_change(camera_rig.select(view))

	distance_m = start_m
	velocity_mps = speed
	target_power_w = 260.0 if speed > 0.0 else 0.0
	is_riding = true
	is_racing = speed > 0.0
	_is_solo_ride = true
	print("PROBE_READY renderer=%s course=%s hide=%s" % [
		RenderingServer.get_current_rendering_method(),
		current_course.get("name", "?"), ",".join(hide),
	])


func _flush_samples() -> void:
	pass  # probe: never talks to the API


# --metric=N: measure flicker in-engine over N consecutive frames and print
# it (for web builds, where frames can't be written anywhere readable).
# Flicker = share of ground pixels whose luma jumps > 60/255 frame-to-frame,
# near band (either side of the road) and far band (below the horizon).
var _metric_frames := 0
var _metric_prev_near := PackedByteArray()
var _metric_prev_far := PackedByteArray()
var _metric_sum_near := 0.0
var _metric_sum_far := 0.0
var _metric_pairs := 0


func _metric_luma(img: Image, y0f: float, y1f: float) -> PackedByteArray:
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var bpp := 4 if img.get_format() == Image.FORMAT_RGBA8 else 3
	var out := PackedByteArray()
	for y in range(int(h * y0f), int(h * y1f), 2):
		for x in range(0, w, 2):
			if x > int(w * 0.31) and x < int(w * 0.69):
				continue  # skip the road + rider
			var i := (y * w + x) * bpp
			out.append(int(0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]))
	return out


func _metric_jumps(a: PackedByteArray, b: PackedByteArray) -> float:
	var n := mini(a.size(), b.size())
	if n == 0:
		return 0.0
	var jumps := 0
	for i in n:
		if absi(a[i] - b[i]) > 60:
			jumps += 1
	return float(jumps) / float(n)


func _metric_step() -> void:
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	var near := _metric_luma(img, 0.53, 0.78)
	var far := _metric_luma(img, 0.28, 0.42)
	if not _metric_prev_near.is_empty():
		_metric_sum_near += _metric_jumps(_metric_prev_near, near)
		_metric_sum_far += _metric_jumps(_metric_prev_far, far)
		_metric_pairs += 1
	_metric_prev_near = near
	_metric_prev_far = far
	if _metric_pairs >= _metric_frames:
		print("PROBE_FLICKER renderer=%s near=%.3f%% far=%.3f%% pairs=%d size=%dx%d" % [
			RenderingServer.get_current_rendering_method(),
			100.0 * _metric_sum_near / _metric_pairs,
			100.0 * _metric_sum_far / _metric_pairs,
			_metric_pairs, img.get_width(), img.get_height(),
		])
		_metric_frames = 0  # done; on the web keep riding, natively exit
		if not OS.has_feature("web") and _out.is_empty():
			get_tree().quit()


func _process(delta: float) -> void:
	super._process(delta)
	_tick += 1
	if _tick == 1:
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--metric="):
				_metric_frames = int(a.substr(9))
	if _metric_frames > 0 and _tick > _warmup:
		_metric_step()
	if _out.is_empty() or _shot >= _frames or _tick <= _warmup:
		return
	if (_tick - _warmup) % _every != 0:
		return
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/f%02d.png" % [_out, _shot])
	_shot += 1
	if _shot >= _frames:
		print("PROBE_DONE frames=%d" % _shot)
		get_tree().quit()
