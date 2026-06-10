extends Node3D

# Phase 1 ride controller — builds the world, fetches a course, drives
# physics-based rider movement, batches samples to the backend, finishes
# the ride on Esc.

const HUD_SCENE := preload("res://scenes/hud.tscn")

const POWER_RATE_WPS := 80.0
const MAX_POWER_W := 1000.0
const STARTING_POWER_W := 100.0
const LATERAL_SPEED_MPS := 3.0
const ROAD_HALF_WIDTH_M := 2.0  # soft clamp so the rider stays on the road
# Vertical gap between path elevation and the rider's pivot. Road surface
# sits at path_elevation + 0.05 (road lift); RIDER_GROUND_CLEARANCE puts
# the wheel bottoms a hair above that so they don't z-fight on flat road
# or sink into the surface on steep climbs.
const RIDER_GROUND_CLEARANCE := 0.07
const SAMPLE_HZ := 4.0
const SAMPLE_FLUSH_S := 5.0
const WORLD_STATE_HZ := 10.0  # outbound multiplayer state rate
const TRAINER_SEND_HZ := 3.0  # grade updates to a smart trainer in SIM mode
const PLAYER_COLOR := Color(0.85, 0.20, 0.15)
const GHOST_COLOR := Color(0.15, 0.40, 0.85)
const DRAFT_MAX_DISTANCE_M := 10.0
const DRAFT_MAX_LATERAL_M := 2.0
const DRAFT_FULL_REDUCTION := 0.35  # max CdA savings at perfect draft

var rider_node: Node3D
var _player_visual: RiderVisual
# Shared ground shader (terrain mesh + ground strip), built lazily so both
# use the same noise texture and the colors match seamlessly.
var _ground_shader_material: ShaderMaterial = null
# Intermediate node that holds the rider visual + bib label. It pitches
# with the road grade so the bike rolls along the tilted surface, but the
# camera (a sibling on rider_node) stays at a fixed look angle.
var rider_visual_node: Node3D
var camera: Camera3D
var hud: CanvasLayer

var kit: PhysicsKit = PhysicsKit.new()
var rider_id: String = ""
var current_ride_id: String = ""
var current_course: Dictionary = {}

var is_riding: bool = false
var is_racing: bool = false  # false during the pre-race pen (game mode only)
var _finishing: bool = false
var target_power_w: float = STARTING_POWER_W
var velocity_mps: float = 0.0
var distance_m: float = 0.0
var elapsed_s: float = 0.0
var peak_speed_mps: float = 0.0
var peak_power_w: float = 0.0
var _power_sum: float = 0.0
var _power_count: int = 0
var heading: int = 1  # +1 = facing -Z, -1 = turned around (facing +Z)
var _start_line_node: Node3D = null

var _samples_buffer: Array = []
var _sample_accum_s: float = 0.0
var _flush_accum_s: float = 0.0
var _local_jsonl: FileAccess = null  # appended every sample tick
var _local_jsonl_path: String = ""
# Samples that failed to upload — retried on the next flush. Survives a
# brief network blip without losing data; gets cleared on success.
var _pending_uploads: Array = []

var _ghosts: Dictionary = {}  # rider_id (String) -> Node3D
var _ghost_visuals: Dictionary = {}  # rider_id -> RiderVisual (animated rig)
var _ghost_targets: Dictionary = {}  # rider_id -> {pos, velocity, yaw, t_ms}
var _ghost_names: Dictionary = {}  # rider_id -> display_name
var _ghost_bibs: Dictionary = {}  # rider_id -> bib_number
var _ghost_distances: Dictionary = {}  # rider_id -> latest reported distance_m
var _my_bib: int = 0
var _world_state_accum_s: float = 0.0
var _trainer_accum_s: float = 0.0
# Course path: list of {distance_m, x_m, y_m, elevation_m}. Populated from
# Course.path when the server provides it; otherwise synthesized as a
# straight path along world -Z so legacy elevation-only courses still work.
var _course_path: Array = []
# Per-waypoint smoothed tangent + right vectors (world XZ unit, y=0).
# Computed once in _build_course_visuals as the bisector of incoming and
# outgoing segment tangents. Used by every consumer (road mesh, ground
# strip, markers, rider physics) so corners meet without kinks and the
# rider's rotation eases through turns instead of snapping at segment
# boundaries.
var _waypoint_tangents: Array = []
var _waypoint_rights: Array = []
# Rider's perpendicular offset across the road (positive = right side
# when facing forward along the path). Replaces the implicit
# global_position.x in the old straight-road world.
var _lateral_offset: float = 0.0

# Heightmap of the terrain around the route. Populated asynchronously
# by _setup_terrain_async after fetching the PNG from the web app.
# Empty for synthetic / loop courses where no heightmap is provided.
var _terrain_inst: MeshInstance3D = null
var _terrain_heights: Array = []  # row-major float, size = width * height
var _terrain_width: int = 0
var _terrain_height: int = 0
var _terrain_grid_m: float = 0.0
var _terrain_origin_x_m: float = 0.0
var _terrain_origin_y_m: float = 0.0
var _terrain_min_ele: float = 0.0
var _terrain_max_ele: float = 0.0

# Topo minimap (in-ride). Loaded async; once present we project the rider
# position into image UV every physics tick so the HUD marker tracks them.
# Reuses the heightmap_* meta from the course (same origin / grid / extent).
var _topo_loaded: bool = false

# Flat 12 km × 12 km ground plane used as a backdrop for synthetic / loop
# courses. Tracked so we can hide it once the heightmap terrain arrives —
# otherwise the two co-planar surfaces z-fight and produce flickering
# black bands in the rider's view (visible whenever the heightmap min
# elevation lands close to y=0, which it always does after normalization).
var _ground_inst: MeshInstance3D = null

# Wide path-following green ribbon built synchronously in
# _build_course_visuals as a bridge between the road and the flat
# ground while the heightmap terrain is still fetching. Hidden once the
# real terrain arrives — at that point it would just z-fight with the
# terrain (both surfaces driven by the same elevations).
var _ground_strip_inst: MeshInstance3D = null

const GHOST_SMOOTH_RATE := 10.0  # higher = snappier, lower = smoother but more lag
const GHOST_DEAD_RECKON_CAP_S := 1.0  # stop extrapolating after this much silence


func _ready() -> void:
	_apply_rider_to_kit()
	_setup_environment()
	_setup_ground()
	_setup_sun()
	_setup_rider()
	_setup_camera()
	_setup_hud()
	# Road, markers, scenery depend on the chosen course — built post-pick
	# inside _start_solo / _start_game via _build_course_visuals().
	if GameSession.is_solo:
		_start_solo()
	else:
		_start_game()


func _apply_rider_to_kit() -> void:
	# Pull picked-rider stats from GameSession into the physics kit so the
	# weight, height, and aero factor that drive the simulation match the
	# profile the user chose. Defaults stay in PhysicsKit if no rider set.
	# (FTP is informational on the profile today; not consumed by physics.)
	if not GameSession.has_rider():
		return
	kit.rider.mass_kg = GameSession.rider_weight_kg
	kit.rider.height_m = GameSession.rider_height_m
	kit.rider.cda_factor = GameSession.rider_cda_factor

	# Apply the equipped loadout. Any slot the rider hasn't equipped yet
	# stays at the PhysicsKit default so the sim never crashes on an
	# un-configured profile.
	if not GameSession.rider_bike.is_empty():
		kit.bike.mass_kg = float(GameSession.rider_bike.get("mass_kg", kit.bike.mass_kg))
		kit.bike.cda_m2 = float(GameSession.rider_bike.get("cda_m2", kit.bike.cda_m2))
	if not GameSession.rider_wheels.is_empty():
		kit.wheels.mass_kg = float(GameSession.rider_wheels.get("mass_kg", kit.wheels.mass_kg))
		kit.wheels.cda_m2 = float(GameSession.rider_wheels.get("cda_m2", kit.wheels.cda_m2))
	if not GameSession.rider_tires.is_empty():
		kit.tires.mass_kg = float(GameSession.rider_tires.get("mass_kg", kit.tires.mass_kg))
		kit.tires.cda_m2 = float(GameSession.rider_tires.get("cda_m2", kit.tires.cda_m2))
		kit.tires.crr = float(GameSession.rider_tires.get("crr", kit.tires.crr))
		kit.tires.size_mm = int(GameSession.rider_tires.get("size_mm", kit.tires.size_mm))
		kit.tires.tread_type = str(GameSession.rider_tires.get("tread_type", kit.tires.tread_type))


# --- World construction ---

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	# Procedural sky with a defined sun + ground horizon. ProceduralSkyMaterial
	# picks up the directional light's direction automatically through the
	# DirectionalLight3D's sky_mode, so the sun disc tracks the sun rotation
	# we set in _setup_sun().
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.55, 0.85)
	sky_mat.sky_horizon_color = Color(0.78, 0.85, 0.92)
	sky_mat.sky_curve = 0.15
	sky_mat.ground_bottom_color = Color(0.18, 0.22, 0.26)
	sky_mat.ground_horizon_color = Color(0.55, 0.62, 0.68)
	sky_mat.sun_angle_max = 12.0
	sky_mat.sun_curve = 0.10
	sky.sky_material = sky_mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6   # let shadowed faces stay legible without flattening contrast
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0

	# SSAO — contact darkening where bike meets road, trees meet ground.
	# Pulls the world out of "everything is floating" without a perf hit
	# on Forward+ (default Godot 4 renderer for this project).
	env.ssao_enabled = true
	env.ssao_radius = 1.5
	env.ssao_intensity = 2.5
	env.ssao_detail = 0.5
	env.ssao_horizon = 0.06
	env.ssao_sharpness = 0.98

	# Subtle screen-space reflections — bike chrome + wet pavement read as
	# shiny instead of plastic-flat. Cheap because the road is matte enough
	# that very little actually reflects.
	env.ssr_enabled = true
	env.ssr_max_steps = 32
	env.ssr_depth_tolerance = 0.4

	# Light bloom on the brightest highlights (sun edge, dash markings) for
	# the "lit warmly by a real sun" look.
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_strength = 1.0
	env.glow_bloom = 0.1

	# Volumetric fog instead of the older constant-density distance fog.
	# Receives sun lighting so backlit fog brightens and frontlit fog cools
	# — gives the world an atmospheric depth cue the linear fog lacked.
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.003
	env.volumetric_fog_albedo = Color(0.92, 0.94, 0.98)
	env.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
	env.volumetric_fog_emission_energy = 0.0
	env.volumetric_fog_length = 250.0  # in metres along the camera frustum
	env.volumetric_fog_anisotropy = 0.2
	env.volumetric_fog_ambient_inject = 0.4
	env.volumetric_fog_sky_affect = 1.0
	# Keep a thin layer of cheap distance fog as a safety net beyond the
	# volumetric fog's range — heightmap mesh edge would otherwise pop.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.0006
	env.fog_light_color = Color(0.78, 0.85, 0.92)
	env.fog_aerial_perspective = 0.5
	env.fog_sky_affect = 0.6

	# Slight saturation + contrast bump for the "stylized hyperreal" look
	# Zwift / Forza go for. Cheap, dramatic, easy to dial back.
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.15
	env.adjustment_contrast = 1.05
	env.adjustment_brightness = 1.0

	# Everything above is the HIGH look; the user's quality preset strips
	# the expensive effects (SSR, volumetric fog, SSAO, glow) below HIGH.
	GraphicsSettings.apply_environment_quality(env)

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _setup_ground() -> void:
	var ground := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	# Curved courses can stretch over a couple of kilometres laterally;
	# 12km × 12km plane keeps the horizon under us for any Test Curves or
	# typical-ride GPX shape we'll throw at it.
	mesh.size = Vector2(12000, 12000)
	ground.mesh = mesh

	# Procedural grass texture: tiled Perlin noise mapped through a green ramp.
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.04
	noise.fractal_octaves = 4
	var noise_tex := NoiseTexture2D.new()
	noise_tex.noise = noise
	noise_tex.width = 512
	noise_tex.height = 512
	noise_tex.seamless = true
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.22, 0.42, 0.20))
	ramp.set_color(1, Color(0.44, 0.64, 0.32))
	noise_tex.color_ramp = ramp

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = noise_tex
	mat.uv1_scale = Vector3(200, 200, 1)
	mat.roughness = 1.0
	ground.material_override = mat
	add_child(ground)
	_ground_inst = ground


func _build_course_visuals() -> void:
	# Course-dependent visuals: ground strip, road, markers, scenery —
	# all built from the course path. Terrain (when the server provides
	# a heightmap) is fetched asynchronously and added when it arrives
	# so the ride can start without waiting on the download.
	#
	# We always build the path-following ground strip + scenery first.
	# When a heightmap eventually arrives, it overlays the wider area
	# beyond the strip; the strip remains a guaranteed "the road sits
	# on something" backdrop. This way the road never visibly floats
	# even if the heightmap fetch is slow, fails, or was missing from
	# the upload entirely.
	_compute_course_path()
	_compute_waypoint_frames()
	_setup_ground_strip()
	_setup_road()
	_setup_markers()
	_setup_scenery()
	# Async terrain fetch — populates _terrain_heights + adds the mesh
	# beside the strip when it arrives. Re-places scenery onto the
	# heightmap once it does.
	if not str(current_course.get("heightmap_url", "")).is_empty():
		_setup_terrain_async()
	# Async topo PNG fetch for the in-ride minimap. Independent of the
	# heightmap fetch; either can fail without affecting the other.
	if not str(current_course.get("topo_map_url", "")).is_empty():
		_setup_minimap_async()


func _setup_terrain_async() -> void:
	var url: String = str(current_course.get("heightmap_url", ""))
	if url.is_empty():
		return  # synthetic / loop courses or upload failed — flat backdrop only
	var w: int = int(current_course.get("heightmap_width", 0))
	var h: int = int(current_course.get("heightmap_height", 0))
	if w < 2 or h < 2:
		return
	_terrain_width = w
	_terrain_height = h
	_terrain_grid_m = float(current_course.get("heightmap_grid_spacing_m", 0.0))
	_terrain_origin_x_m = float(current_course.get("heightmap_origin_x_m", 0.0))
	_terrain_origin_y_m = float(current_course.get("heightmap_origin_y_m", 0.0))
	_terrain_min_ele = float(current_course.get("heightmap_min_elevation_m", 0.0))
	_terrain_max_ele = float(current_course.get("heightmap_max_elevation_m", 0.0))

	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(url)
	if err != OK:
		push_warning("Heightmap fetch dispatch failed: %s" % err)
		http.queue_free()
		return
	var result: Array = await http.request_completed
	http.queue_free()
	var transport: int = result[0]
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	if transport != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		push_warning("Heightmap fetch failed: code=%s" % code)
		return

	var img := Image.new()
	var png_err := img.load_png_from_buffer(body)
	if png_err != OK:
		push_warning("Heightmap PNG decode failed: %s" % png_err)
		return
	if img.get_width() != w or img.get_height() != h:
		push_warning(
			"Heightmap dimensions mismatch: png=%dx%d expected=%dx%d"
			% [img.get_width(), img.get_height(), w, h]
		)
		return

	# Decode pixel values into world elevations. Color.r is in [0, 1]
	# regardless of the source PNG's bit depth, so this works whether
	# Godot loaded the 16-bit PNG as 16-bit or downconverted to 8-bit.
	var range_m: float = _terrain_max_ele - _terrain_min_ele
	_terrain_heights.resize(w * h)
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			_terrain_heights[y * w + x] = _terrain_min_ele + c.r * range_m

	if not is_inside_tree():
		return
	_build_terrain_mesh()
	# Hide the flat backdrop ground now that the heightmap mesh covers
	# everything visible. Leaving it on causes z-fighting wherever the
	# heightmap dips near its normalized 0-m minimum (the flat plane is
	# at exactly y=0), which manifests as the flickering black bands the
	# rider sees beside the road on real GPX courses.
	if _ground_inst != null:
		_ground_inst.visible = false
	# The path-following ground strip is now redundant — the terrain
	# mesh covers the same area at the same elevations. Hiding it avoids
	# a second co-planar z-fight near the road shoulder.
	if _ground_strip_inst != null:
		_ground_strip_inst.visible = false
	# Re-place scenery onto the heightmap. The initial pass in
	# _build_course_visuals used path-elevation fallbacks; now that the
	# terrain heights are known, scatter trees onto the real surface.
	# Existing tree MultiMeshInstance3D nodes are cleared so we don't
	# end up with two overlapping forests.
	_clear_existing_scenery()
	_setup_scenery()


func _setup_minimap_async() -> void:
	# Fetch the course's topo PNG and hand it to the HUD. The map's
	# world↔pixel projection reuses heightmap_* fields (origin, grid,
	# width, height). If those are missing we still display the topo
	# but can't place the rider marker — set_minimap_uv would no-op.
	var url: String = str(current_course.get("topo_map_url", ""))
	if url.is_empty():
		return
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(url)
	if err != OK:
		push_warning("Topo map fetch dispatch failed: %s" % err)
		http.queue_free()
		return
	var result: Array = await http.request_completed
	http.queue_free()
	var transport: int = result[0]
	var code: int = result[1]
	if transport != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		push_warning("Topo map fetch failed: code=%s" % code)
		return
	var img := Image.new()
	var png_err := img.load_png_from_buffer(result[3])
	if png_err != OK:
		push_warning("Topo map PNG decode failed: %s" % png_err)
		return
	if not is_inside_tree():
		return
	hud.set_minimap_texture(ImageTexture.create_from_image(img))
	_topo_loaded = true


func _clear_existing_scenery() -> void:
	# Find prior MultiMeshInstance3D children (the tree forest from the
	# first scenery pass) and remove them. Identified by the unique
	# MultiMesh resource used in _setup_scenery; fall back to checking
	# child type if needed.
	for child in get_children():
		if child is MultiMeshInstance3D:
			child.queue_free()


func _build_terrain_mesh() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := _terrain_width
	var h := _terrain_height
	var g := _terrain_grid_m
	var ox := _terrain_origin_x_m
	var oy := _terrain_origin_y_m
	# Pre-compute vertex world positions for every cell.
	var verts: Array = []
	verts.resize(w * h)
	for y in h:
		for x in w:
			var wx: float = ox + float(x) * g
			var wy: float = oy + float(y) * g
			var ele: float = _terrain_heights[y * w + x]
			verts[y * w + x] = Vector3(wx, ele, -wy)
	# Emit one quad per cell as two triangles. CCW from above for +Y normals.
	for y in range(h - 1):
		for x in range(w - 1):
			var v00: Vector3 = verts[y * w + x]
			var v10: Vector3 = verts[y * w + (x + 1)]
			var v01: Vector3 = verts[(y + 1) * w + x]
			var v11: Vector3 = verts[(y + 1) * w + (x + 1)]
			st.add_vertex(v00); st.add_vertex(v10); st.add_vertex(v01)
			st.add_vertex(v10); st.add_vertex(v11); st.add_vertex(v01)
	st.generate_normals()

	var inst := MeshInstance3D.new()
	inst.mesh = st.commit()
	inst.material_override = _ground_material()
	add_child(inst)
	_terrain_inst = inst


func _terrain_height_at(world_x: float, world_z: float) -> float:
	# Bilinear sample. World Z = -y_m in the path's local frame, so
	# convert before indexing the grid. Returns 0 (the fallback flat
	# plane's height) when no heightmap is loaded yet — the ride can
	# start before the PNG download completes.
	if _terrain_width < 2 or _terrain_grid_m <= 0.0:
		return 0.0
	var local_y_m: float = -world_z
	var fx: float = (world_x - _terrain_origin_x_m) / _terrain_grid_m
	var fy: float = (local_y_m - _terrain_origin_y_m) / _terrain_grid_m
	fx = clampf(fx, 0.0, float(_terrain_width) - 1.0001)
	fy = clampf(fy, 0.0, float(_terrain_height) - 1.0001)
	var ix := int(fx)
	var iy := int(fy)
	var tx: float = fx - float(ix)
	var ty: float = fy - float(iy)
	var w := _terrain_width
	var e00: float = _terrain_heights[iy * w + ix]
	var e10: float = _terrain_heights[iy * w + (ix + 1)]
	var e01: float = _terrain_heights[(iy + 1) * w + ix]
	var e11: float = _terrain_heights[(iy + 1) * w + (ix + 1)]
	var a: float = e00 + (e10 - e00) * tx
	var b: float = e01 + (e11 - e01) * tx
	return a + (b - a) * ty


func _compute_waypoint_frames() -> void:
	# Average the incoming and outgoing segment tangents at every waypoint.
	# Equivalent to a "miter join" — adjacent road / ground-strip quads
	# share corners along this smoothed normal, so seams disappear, and
	# the rider's rotation eases through curves instead of snapping at
	# segment boundaries.
	_waypoint_tangents = []
	_waypoint_rights = []
	var n := _course_path.size()
	if n < 2:
		return
	for i in range(n):
		var p: Dictionary = _course_path[i]
		var c := Vector3(float(p["x_m"]), 0, -float(p["y_m"]))
		var t_in := Vector3.ZERO
		var t_out := Vector3.ZERO
		if i > 0:
			var pp: Dictionary = _course_path[i - 1]
			t_in = c - Vector3(float(pp["x_m"]), 0, -float(pp["y_m"]))
			t_in = t_in.normalized() if t_in.length() > 1e-6 else Vector3.ZERO
		if i + 1 < n:
			var pn: Dictionary = _course_path[i + 1]
			t_out = Vector3(float(pn["x_m"]), 0, -float(pn["y_m"])) - c
			t_out = t_out.normalized() if t_out.length() > 1e-6 else Vector3.ZERO
		var tng := t_in + t_out
		if tng.length() < 1e-6:
			tng = t_out if t_out.length() > 0.5 else t_in
		if tng.length() < 1e-6:
			tng = Vector3(0, 0, -1)
		tng = tng.normalized()
		_waypoint_tangents.append(tng)
		_waypoint_rights.append(Vector3(-tng.z, 0, tng.x))


func _setup_ground_strip() -> void:
	# Wide green ribbon that follows the path's elevation. Without this
	# the flat ground plane sits at y=0 and the climbing road appears to
	# hover above it. Width is generous enough that the strip covers the
	# visible foreground on either side of the road for typical courses.
	const STRIP_HALF_WIDTH := 120.0
	if _course_path.size() < 2 or _waypoint_rights.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(_course_path.size() - 1):
		var p0: Dictionary = _course_path[i]
		var p1: Dictionary = _course_path[i + 1]
		var c0 := Vector3(float(p0["x_m"]), float(p0["elevation_m"]), -float(p0["y_m"]))
		var c1 := Vector3(float(p1["x_m"]), float(p1["elevation_m"]), -float(p1["y_m"]))
		var r0: Vector3 = _waypoint_rights[i]
		var r1: Vector3 = _waypoint_rights[i + 1]
		var l0 := c0 - r0 * STRIP_HALF_WIDTH
		var rr0 := c0 + r0 * STRIP_HALF_WIDTH
		var l1 := c1 - r1 * STRIP_HALF_WIDTH
		var rr1 := c1 + r1 * STRIP_HALF_WIDTH
		# CCW from above so the surface normal points +Y (up).
		st.add_vertex(l0); st.add_vertex(rr0); st.add_vertex(l1)
		st.add_vertex(rr0); st.add_vertex(rr1); st.add_vertex(l1)
	st.generate_normals()
	var inst := MeshInstance3D.new()
	inst.mesh = st.commit()
	inst.material_override = _ground_material()
	add_child(inst)
	_ground_strip_inst = inst


func _ground_material() -> ShaderMaterial:
	# Shared between the ground strip and the heightmap terrain so colors
	# match exactly where they meet (both sample world-space noise).
	if _ground_shader_material == null:
		_ground_shader_material = TerrainMaterial.build()
	return _ground_shader_material


func _compute_course_path() -> void:
	_course_path = []
	if current_course.is_empty():
		return
	var raw_path: Array = current_course.get("path", [])
	if raw_path.size() >= 2:
		# Normalize elevations: subtract the minimum so the route's lowest
		# point sits at y=0. GPX exports carry absolute m-above-sea-level
		# elevations (e.g., 1700 m for a mountain ride). At that magnitude
		# the rider + road sit way above the flat backdrop ground plane
		# and the depth buffer can't keep them visually separated.
		# Synthetic courses (Test Curves) already start at 0; min-shift is a no-op.
		var min_ele := INF
		for p in raw_path:
			var e := float(p["elevation_m"])
			if e < min_ele:
				min_ele = e
		if min_ele == INF:
			min_ele = 0.0
		for p in raw_path:
			_course_path.append({
				"distance_m": float(p["distance_m"]),
				"x_m": float(p["x_m"]),
				"y_m": float(p["y_m"]),
				"elevation_m": float(p["elevation_m"]) - min_ele,
			})
		return

	# Fallback: synthesize a straight path along world -Z (positive local
	# Y = forward) from elevation_profile. Cumulative elevation is the
	# integral of (gradient × distance step).
	var profile: Array = current_course.get("elevation_profile", [])
	if profile.size() < 2:
		_course_path = [{"distance_m": 0.0, "x_m": 0.0, "y_m": 0.0, "elevation_m": 0.0}]
		return
	var cum_ele := 0.0
	for i in profile.size():
		var p: Dictionary = profile[i]
		var d := float(p["distance_m"])
		var g := float(p["gradient"])
		if i > 0:
			var prev: Dictionary = profile[i - 1]
			var dd := d - float(prev["distance_m"])
			var avg_g := (float(prev["gradient"]) + g) * 0.5
			cum_ele += dd * avg_g
		_course_path.append({
			"distance_m": d,
			"x_m": 0.0,
			"y_m": d,
			"elevation_m": cum_ele,
		})


func _find_path_segment(d: float) -> int:
	# Returns index i such that path[i].distance_m <= d <= path[i+1].distance_m.
	if _course_path.size() < 2:
		return 0
	# Linear scan — bounded by path length (~500 for the Test Curves course,
	# fine at 60 Hz). Switch to binary search if real GPX routes get huge.
	for i in range(_course_path.size() - 1):
		if d <= float(_course_path[i + 1]["distance_m"]):
			return i
	return _course_path.size() - 2


func _wrap_distance(d: float) -> float:
	var length := float(current_course.get("length_m", 0.0))
	if length <= 0.0:
		return d
	return fposmod(d, length)


func _position_at_distance(d: float) -> Vector3:
	# World position (x east, y up, z = -y_north). Linearly interpolated
	# between consecutive path waypoints. Falls back to origin if path
	# isn't ready yet.
	if _course_path.size() < 2:
		return Vector3.ZERO
	var dd := _wrap_distance(d)
	var i := _find_path_segment(dd)
	var p0: Dictionary = _course_path[i]
	var p1: Dictionary = _course_path[i + 1]
	var d0 := float(p0["distance_m"])
	var d1 := float(p1["distance_m"])
	var t := 0.0 if d1 <= d0 else (dd - d0) / (d1 - d0)
	var x: float = lerpf(float(p0["x_m"]), float(p1["x_m"]), t)
	var y: float = lerpf(float(p0["y_m"]), float(p1["y_m"]), t)
	var ele: float = lerpf(float(p0["elevation_m"]), float(p1["elevation_m"]), t)
	return Vector3(x, ele, -y)


func _tangent_at_distance(d: float) -> Vector3:
	# Unit world XZ vector pointing along the direction of travel. Falls
	# back to the segment-direction tangent when waypoint frames aren't
	# computed yet (e.g., during the first frame).
	if _course_path.size() < 2:
		return Vector3(0, 0, -1)
	var dd := _wrap_distance(d)
	var i := _find_path_segment(dd)
	if _waypoint_tangents.size() == _course_path.size():
		var p0: Dictionary = _course_path[i]
		var p1: Dictionary = _course_path[i + 1]
		var d0 := float(p0["distance_m"])
		var d1 := float(p1["distance_m"])
		var t: float = 0.0 if d1 <= d0 else (dd - d0) / (d1 - d0)
		var tng: Vector3 = (_waypoint_tangents[i] as Vector3).lerp(
			_waypoint_tangents[i + 1] as Vector3, t
		)
		if tng.length() < 1e-6:
			return Vector3(0, 0, -1)
		return tng.normalized()
	# Fallback: raw segment direction.
	var p0b: Dictionary = _course_path[i]
	var p1b: Dictionary = _course_path[i + 1]
	var dx := float(p1b["x_m"]) - float(p0b["x_m"])
	var dy := float(p1b["y_m"]) - float(p0b["y_m"])
	var tan_b := Vector3(dx, 0, -dy)
	if tan_b.length() < 1e-6:
		return Vector3(0, 0, -1)
	return tan_b.normalized()


func _heading_at_distance(d: float) -> float:
	# Godot rotation.y so that the rider's default forward (-Z) aligns
	# with the tangent. forward = (-sin(y), 0, -cos(y)), so for tangent
	# (tx, 0, tz) we need y = atan2(-tx, -tz).
	var tng := _tangent_at_distance(d)
	return atan2(-tng.x, -tng.z)


func _elevation_at_distance(d: float) -> float:
	return _position_at_distance(d).y


func _setup_road() -> void:
	const ROAD_WIDTH := 4.0
	const LINE_WIDTH := 0.15
	const DASH_LENGTH := 3.0
	const DASH_PERIOD := 8.0
	# UV repeat scale — every TEX_TILE_M metres of road length re-tiles the
	# asphalt texture once. ~4 m matches the road's own width so the grain
	# is consistent across both axes regardless of how the camera frames it.
	const TEX_TILE_M := 4.0
	if _course_path.size() < 2:
		return

	# Asphalt: one ArrayMesh assembled from quads whose corners use the
	# pre-computed waypoint right vectors. Sharing corners between adjacent
	# segments (miter join) keeps the surface continuous through turns
	# with no visible seams. UVs are set per-vertex so the procedural
	# asphalt texture tiles down the road's length without stretching.
	var asphalt := SurfaceTool.new()
	asphalt.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_w := ROAD_WIDTH * 0.5
	var lift := Vector3(0, 0.05, 0)
	for i in range(_course_path.size() - 1):
		var p0: Dictionary = _course_path[i]
		var p1: Dictionary = _course_path[i + 1]
		var pos0 := Vector3(float(p0["x_m"]), float(p0["elevation_m"]), -float(p0["y_m"])) + lift
		var pos1 := Vector3(float(p1["x_m"]), float(p1["elevation_m"]), -float(p1["y_m"])) + lift
		var r0: Vector3 = _waypoint_rights[i] if i < _waypoint_rights.size() else Vector3.ZERO
		var r1: Vector3 = _waypoint_rights[i + 1] if i + 1 < _waypoint_rights.size() else r0
		var left0 := pos0 - r0 * half_w
		var right0 := pos0 + r0 * half_w
		var left1 := pos1 - r1 * half_w
		var right1 := pos1 + r1 * half_w
		# v cycles every TEX_TILE_M of distance-along-path; u maps the road
		# width to [0, 1]. A small lateral repeat (uv1_scale on the material)
		# packs more grain per metre once both maps are in place.
		var v0: float = float(p0["distance_m"]) / TEX_TILE_M
		var v1: float = float(p1["distance_m"]) / TEX_TILE_M
		# Two triangles forming the quad. CCW from above so the surface
		# normal points +Y (up) — visible to a camera looking down at it.
		asphalt.set_uv(Vector2(0.0, v0)); asphalt.add_vertex(left0)
		asphalt.set_uv(Vector2(1.0, v0)); asphalt.add_vertex(right0)
		asphalt.set_uv(Vector2(0.0, v1)); asphalt.add_vertex(left1)
		asphalt.set_uv(Vector2(1.0, v0)); asphalt.add_vertex(right0)
		asphalt.set_uv(Vector2(1.0, v1)); asphalt.add_vertex(right1)
		asphalt.set_uv(Vector2(0.0, v1)); asphalt.add_vertex(left1)
	asphalt.generate_normals()
	asphalt.generate_tangents()  # needed for the asphalt normal map to light correctly
	var asphalt_inst := MeshInstance3D.new()
	asphalt_inst.mesh = asphalt.commit()
	asphalt_inst.material_override = _build_asphalt_material()
	add_child(asphalt_inst)

	# Dashed centre line — short rectangles laid along the path tangent
	# at regular distance intervals. Bright bone-white now and slightly
	# elevated so SSAO doesn't darken the leading edge.
	var dashes := SurfaceTool.new()
	dashes.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dash_half_w := LINE_WIDTH * 0.5
	var dash_half_l := DASH_LENGTH * 0.5
	var dash_lift := Vector3(0, 0.07, 0)
	var total_len: float = float(current_course.get("length_m", 0.0))
	if total_len <= 0.0 and _course_path.size() > 0:
		total_len = float(_course_path[-1]["distance_m"])
	var num_dashes := int(total_len / DASH_PERIOD)
	for i in num_dashes:
		var d_mid: float = float(i) * DASH_PERIOD + dash_half_l
		var center := _position_at_distance(d_mid) + dash_lift
		var tng := _tangent_at_distance(d_mid)
		var right := Vector3(-tng.z, 0, tng.x)
		var ahead := tng * dash_half_l
		var fl := center + ahead - right * dash_half_w
		var fr := center + ahead + right * dash_half_w
		var br := center - ahead + right * dash_half_w
		var bl := center - ahead - right * dash_half_w
		# CCW from above so the dash surface normal points +Y.
		dashes.add_vertex(bl)
		dashes.add_vertex(br)
		dashes.add_vertex(fl)
		dashes.add_vertex(br)
		dashes.add_vertex(fr)
		dashes.add_vertex(fl)
	dashes.generate_normals()
	var dash_inst := MeshInstance3D.new()
	dash_inst.mesh = dashes.commit()
	var dash_mat := StandardMaterial3D.new()
	dash_mat.albedo_color = Color(0.98, 0.97, 0.92)  # crisp warm white
	dash_mat.roughness = 0.55
	dash_mat.emission_enabled = true
	dash_mat.emission = Color(0.20, 0.20, 0.18)  # tiny self-emit so dashes punch through fog
	dash_mat.emission_energy_multiplier = 0.4
	dash_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	dash_inst.material_override = dash_mat
	add_child(dash_inst)


# --- Road materials (procedural, generated once per ride) ---

func _build_asphalt_material() -> StandardMaterial3D:
	# Two coupled textures generated from FastNoiseLite:
	#   1. albedo — high-frequency grayscale grain ramped through a narrow
	#      dark band (asphalt is almost-but-not-quite black, gets darker
	#      after the rain reading on day-1 cyclist photos).
	#   2. normal — same noise re-derived through NoiseTexture2D's
	#      as_normal_map for surface micro-bumps. Lit dynamically by the
	#      sun so the road gets specular highlights as the camera pans.
	#
	# Both tile seamlessly so the per-vertex UVs in _setup_road wrap
	# without visible joints.

	var albedo_noise := FastNoiseLite.new()
	albedo_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	albedo_noise.frequency = 0.85
	albedo_noise.fractal_octaves = 4
	albedo_noise.fractal_lacunarity = 2.2
	albedo_noise.fractal_gain = 0.55

	var albedo_tex := NoiseTexture2D.new()
	albedo_tex.noise = albedo_noise
	albedo_tex.width = 512
	albedo_tex.height = 512
	albedo_tex.seamless = true
	albedo_tex.seamless_blend_skirt = 0.10
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.08, 0.08, 0.09))
	ramp.set_color(1, Color(0.26, 0.26, 0.27))
	albedo_tex.color_ramp = ramp

	# Normal map from a sibling noise — slightly higher frequency to read
	# as the asphalt aggregate (small stones) rather than coarse rolls.
	var normal_noise := FastNoiseLite.new()
	normal_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	normal_noise.frequency = 1.6
	normal_noise.fractal_octaves = 3
	var normal_tex := NoiseTexture2D.new()
	normal_tex.noise = normal_noise
	normal_tex.width = 512
	normal_tex.height = 512
	normal_tex.seamless = true
	normal_tex.seamless_blend_skirt = 0.10
	normal_tex.as_normal_map = true
	normal_tex.bump_strength = 4.0

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = albedo_tex
	mat.normal_enabled = true
	mat.normal_texture = normal_tex
	mat.normal_scale = 0.55
	mat.roughness = 0.78
	mat.metallic = 0.0
	# Sub-metre lateral repeat × longer along-road tile — asphalt grain is
	# small and isotropic, so we want a lot of repetitions per visible
	# metre, not stretched ribbons down the centerline.
	mat.uv1_scale = Vector3(2.0, 1.0, 1.0)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _setup_markers() -> void:
	const SPACING_M := 100.0
	const SIDE_OFFSET := 3.2
	if _course_path.size() < 2:
		return
	var total_len: float = float(current_course.get("length_m", 0.0))
	if total_len <= 0.0:
		total_len = float(_course_path[-1]["distance_m"])
	var marker_count := int(total_len / SPACING_M)

	var post_mesh := CylinderMesh.new()
	post_mesh.height = 1.4
	post_mesh.top_radius = 0.08
	post_mesh.bottom_radius = 0.08
	var km_mesh := CylinderMesh.new()
	km_mesh.height = 2.4
	km_mesh.top_radius = 0.12
	km_mesh.bottom_radius = 0.12
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = Color(0.95, 0.95, 0.95)
	var km_mat := StandardMaterial3D.new()
	km_mat.albedo_color = Color(0.85, 0.25, 0.15)

	for i in range(1, marker_count + 1):
		var distance: float = float(i) * SPACING_M
		var center := _position_at_distance(distance)
		var tng := _tangent_at_distance(distance)
		var right := Vector3(-tng.z, 0, tng.x)
		var is_km: bool = (i % 10) == 0
		for side in [-1.0, 1.0]:
			var post := MeshInstance3D.new()
			post.mesh = km_mesh if is_km else post_mesh
			post.material_override = km_mat if is_km else post_mat
			var height: float = km_mesh.height if is_km else post_mesh.height
			# Add to the tree before assigning global_position so Godot
			# can resolve the world transform without warning.
			add_child(post)
			post.global_position = (
				center + right * (side * SIDE_OFFSET) + Vector3(0, height * 0.5, 0)
			)


func _setup_scenery() -> void:
	# Mixed-variety forest (pine / oak / poplar / bush from SceneryFactory)
	# scattered inside the bounding box of the path, rejecting candidates
	# too close to the road centerline. One MultiMesh per variety = four
	# draw calls; instance colors give per-tree foliage hue variation.
	# Density scales with the quality preset.
	var tree_count: int = GraphicsSettings.tree_count()
	const PADDING := 80.0
	const MIN_DIST_TO_ROAD := 6.0
	if _course_path.size() < 2:
		return

	# Bounding box of the path in world XZ.
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for p in _course_path:
		var px := float(p["x_m"])
		var pz := -float(p["y_m"])
		if px < min_x: min_x = px
		if px > max_x: max_x = px
		if pz < min_z: min_z = pz
		if pz > max_z: max_z = pz
	min_x -= PADDING
	max_x += PADDING
	min_z -= PADDING
	max_z += PADDING

	var rng := RandomNumberGenerator.new()
	rng.seed = 0xB1CE_F00D
	var min_d2_threshold := MIN_DIST_TO_ROAD * MIN_DIST_TO_ROAD

	# Collect placements per variety, then build one MultiMesh per variety
	# (instance_count must be known up front).
	var placements: Array = [[], [], [], []]
	var placed := 0
	var attempts := 0
	while placed < tree_count and attempts < tree_count * 8:
		attempts += 1
		var x := rng.randf_range(min_x, max_x)
		var z := rng.randf_range(min_z, max_z)
		# Nearest-point linear scan. Also returns the nearest path point's
		# elevation so we can sit the tree on the ground strip instead of
		# the y=0 fallback plane.
		var min_d2 := INF
		var nearest_ele := 0.0
		for p in _course_path:
			var dx := float(p["x_m"]) - x
			var dz := -float(p["y_m"]) - z
			var d2 := dx * dx + dz * dz
			if d2 < min_d2:
				min_d2 = d2
				nearest_ele = float(p["elevation_m"])
				if min_d2 < min_d2_threshold:
					break
		if min_d2 < min_d2_threshold:
			continue
		# If a heightmap is loaded, plant the tree on the terrain. Otherwise
		# fall back to the nearest path waypoint's elevation.
		var ground_y: float = nearest_ele
		if _terrain_width >= 2:
			ground_y = _terrain_height_at(x, z)
		var variety := _pick_tree_variety(rng)
		placements[variety].append({
			"pos": Vector3(x, ground_y, z),
			"scale": _tree_scale(rng, variety),
			"yaw": rng.randf_range(0.0, TAU),
			"color": _tree_foliage_color(rng, variety),
		})
		placed += 1

	for variety in SceneryFactory.VARIETY_COUNT:
		var list: Array = placements[variety]
		if list.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = SceneryFactory.variety_mesh(variety)
		mm.instance_count = list.size()
		for i in list.size():
			var t: Dictionary = list[i]
			var basis := Basis(Vector3.UP, float(t["yaw"])).scaled(Vector3.ONE * float(t["scale"]))
			mm.set_instance_transform(i, Transform3D(basis, t["pos"]))
			mm.set_instance_color(i, t["color"])
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = mm
		# Materials live on the mesh surfaces (brown trunk + tintable
		# foliage) — no override, or the per-surface split would be lost.
		add_child(inst)


func _pick_tree_variety(rng: RandomNumberGenerator) -> int:
	var roll := rng.randf()
	if roll < 0.32:
		return SceneryFactory.Variety.PINE
	if roll < 0.62:
		return SceneryFactory.Variety.OAK
	if roll < 0.76:
		return SceneryFactory.Variety.POPLAR
	return SceneryFactory.Variety.BUSH


func _tree_scale(rng: RandomNumberGenerator, variety: int) -> float:
	match variety:
		SceneryFactory.Variety.PINE: return rng.randf_range(0.8, 1.6)
		SceneryFactory.Variety.OAK: return rng.randf_range(0.7, 1.3)
		SceneryFactory.Variety.POPLAR: return rng.randf_range(0.9, 1.5)
		_: return rng.randf_range(0.7, 1.1)


func _tree_foliage_color(rng: RandomNumberGenerator, variety: int) -> Color:
	match variety:
		SceneryFactory.Variety.PINE:
			# Darker blue-greens.
			return Color(rng.randf_range(0.08, 0.14), rng.randf_range(0.30, 0.42), rng.randf_range(0.14, 0.20))
		SceneryFactory.Variety.POPLAR:
			# Yellow-greens.
			return Color(rng.randf_range(0.26, 0.36), rng.randf_range(0.42, 0.52), rng.randf_range(0.14, 0.20))
		_:
			# Oak / bush: mid greens.
			return Color(rng.randf_range(0.13, 0.22), rng.randf_range(0.38, 0.52), rng.randf_range(0.14, 0.22))


func _setup_sun() -> void:
	# Mid-morning sun: high enough to throw long-but-not-flat shadows along
	# the road, off-axis enough that climbing turns face into and away from
	# light so the heightmap mesh reads as three-dimensional.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.4
	sun.light_color = Color(1.0, 0.97, 0.92)  # warm sunlight, faint amber cast

	# Parallel split shadow maps — four cascades give crisp shadows under
	# the rider while still covering scenery out to ~200 m without the
	# perspective-aliasing "blocky shadow" look one big map produces.
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 200.0
	sun.directional_shadow_split_1 = 0.06   # tight near cascade for the bike/rider
	sun.directional_shadow_split_2 = 0.18
	sun.directional_shadow_split_3 = 0.45
	sun.directional_shadow_fade_start = 0.85
	sun.directional_shadow_blend_splits = true
	# Bias settings that work for our scene scale (1 unit = 1 m, mostly
	# flat-ish terrain). Lower-than-default normal bias prevents the
	# rider's shadow from detaching from his wheels on the road.
	sun.shadow_bias = 0.05
	sun.shadow_normal_bias = 1.5
	sun.shadow_blur = 1.2

	# Let the sun light the sky shader directly so the procedural sun disc
	# matches our directional light direction, and skybox lighting shows up
	# in ambient. Without this the sky disc would be static and ambient
	# wouldn't pick up the warm cast.
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY

	# Below HIGH the quality preset cuts shadow cascades + range.
	GraphicsSettings.apply_sun_quality(sun)

	add_child(sun)


func _setup_rider() -> void:
	rider_node = Node3D.new()
	rider_node.name = "Rider"
	add_child(rider_node)
	rider_visual_node = Node3D.new()
	rider_visual_node.name = "RiderVisual"
	rider_node.add_child(rider_visual_node)
	_player_visual = RiderVisual.new(PLAYER_COLOR)
	rider_visual_node.add_child(_player_visual)


func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.position = Vector3(0.0, 2.0, 5.0)
	camera.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	rider_node.add_child(camera)


func _setup_hud() -> void:
	hud = HUD_SCENE.instantiate()
	add_child(hud)


# --- Session startup ---

func _start_solo() -> void:
	rider_id = GameSession.rider_id
	if rider_id.is_empty():
		hud.set_status("Pick a rider first")
		await get_tree().create_timer(1.5).timeout
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		return

	var detail := await _resolve_course()
	if detail.is_empty():
		# Picker cancelled or load failed — back to home.
		await get_tree().create_timer(0.4).timeout
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		return

	current_course = detail
	hud.set_course(detail["name"], float(detail["length_m"]))
	_build_course_visuals()

	hud.set_status("Starting ride…")
	var ride: Dictionary = await ApiClient.start_ride(
		rider_id,
		str(detail["id"]),
		str(detail.get("name", "")),
		float(detail.get("length_m", 0.0)),
		true,  # is_solo
		"",    # no race code
	)
	if ride.is_empty():
		hud.set_status("Failed to start ride")
		return
	current_ride_id = str(ride["id"])
	_open_local_jsonl()

	target_power_w = STARTING_POWER_W
	is_riding = true
	is_racing = true  # solo starts racing immediately
	hud.set_status("Go!")
	await get_tree().create_timer(1.2).timeout
	if is_riding:
		hud.set_status("")


func _start_game() -> void:
	rider_id = GameSession.rider_id
	if rider_id.is_empty():
		hud.set_status("Missing rider id; return to menu")
		return
	if GameSession.course.is_empty():
		hud.set_status("Missing course; return to menu")
		return

	hud.set_status("Loading %s…" % GameSession.course.get("name", "course"))
	var detail: Dictionary = await ApiClient.get_course(str(GameSession.course["id"]))
	if detail.is_empty():
		hud.set_status("Failed to load course")
		return

	current_course = detail
	hud.set_course(detail["name"], float(detail["length_m"]))
	_build_course_visuals()
	_setup_start_line()

	# Subscribe to the WS signals — connection itself was opened by the lobby.
	WorldClient.rider_joined.connect(_on_rider_joined)
	WorldClient.rider_left.connect(_on_rider_left)
	WorldClient.rider_state.connect(_on_rider_state)
	WorldClient.race_started.connect(_on_race_started)
	WorldClient.race_ended.connect(_on_game_race_ended)

	# Bootstrap ghosts and bibs from the participant list captured by the lobby.
	for p in GameSession.participants:
		var rid := str(p.get("rider_id", ""))
		if rid == rider_id:
			_my_bib = int(p.get("bib_number", 0))
			continue
		if rid == "":
			continue
		_spawn_ghost(
			rid, str(p.get("display_name", "")), int(p.get("bib_number", 0))
		)
	if _my_bib > 0:
		_add_bib_label(rider_visual_node, _my_bib, PLAYER_COLOR)

	hud.set_status("Starting ride…")
	var ride: Dictionary = await ApiClient.start_ride(
		rider_id,
		str(detail["id"]),
		str(detail.get("name", "")),
		float(detail.get("length_m", 0.0)),
		false,  # not solo
		GameSession.code,  # race code
	)
	if ride.is_empty():
		hud.set_status("Failed to start ride")
		return
	current_ride_id = str(ride["id"])
	_open_local_jsonl()
	# Re-open the WS connection so it carries the new ride_id for the
	# server-side finish-on-disconnect path. Lobby opened it without one.
	WorldClient.connect_to_game(GameSession.code, rider_id, current_ride_id)

	target_power_w = STARTING_POWER_W
	is_riding = true
	is_racing = false  # held in the pen until race_started
	hud.set_status("Get ready")


func _resolve_course() -> Dictionary:
	# Solo: if the menu already set a course, use it; otherwise pick now.
	if not GameSession.course.is_empty():
		var course_id := str(GameSession.course.get("id", ""))
		if course_id != "":
			hud.set_status("Loading %s…" % GameSession.course.get("name", "course"))
			var detail: Dictionary = await ApiClient.get_course(course_id)
			if not detail.is_empty():
				return detail

	hud.set_status("Loading courses…")
	var courses: Array = await ApiClient.list_courses()
	if courses.is_empty():
		hud.set_status("No courses available")
		return {}
	hud.set_status("")
	var picker := CoursePicker.new()
	add_child(picker)
	var chosen: Dictionary = await picker.pick(courses)
	picker.queue_free()
	if chosen.is_empty():
		hud.set_status("Cancelled")
		return {}
	hud.set_status("Loading %s…" % chosen.get("name", "course"))
	var detail2: Dictionary = await ApiClient.get_course(str(chosen["id"]))
	if detail2.is_empty():
		hud.set_status("Failed to load course")
	return detail2


func _setup_start_line() -> void:
	var line := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(4.0, 0.3)
	line.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	line.material_override = mat
	# 1 m ahead of distance=0 on the path, lined up with the road tangent.
	var center := _position_at_distance(1.0) + Vector3(0, 0.08, 0)
	add_child(line)
	line.global_position = center
	line.rotation.y = _heading_at_distance(1.0)
	_start_line_node = line


func _on_race_started() -> void:
	is_racing = true
	hud.hide_countdown()
	if _start_line_node != null:
		_start_line_node.queue_free()
		_start_line_node = null
	hud.set_status("GO!")
	await get_tree().create_timer(1.2).timeout
	if is_riding:
		hud.set_status("")


func _on_game_race_ended(reason: String) -> void:
	hud.set_status("Game ended: %s" % reason)


# --- Input ---

func _notification(what: int) -> void:
	# Best-effort finish when the user closes the window mid-ride. Godot
	# stops the scene tree promptly so this is "fire and try"; the server
	# sweeper will catch us if the POST never reaches Django.
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_riding and not _finishing:
		_finishing = true
		_close_local_jsonl()
		ApiClient.finish_ride(
			current_ride_id,
			{
				"total_distance_m": distance_m,
				"total_duration_s": elapsed_s,
				"avg_power_w": _avg_power_so_far(),
				"max_power_w": _max_power_so_far(),
				"peak_speed_mps": peak_speed_mps,
			},
			"app_relaunch",
		)


func _input(event: InputEvent) -> void:
	if not is_riding:
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_SPACE:
			target_power_w = 0.0
		elif event.keycode == KEY_ESCAPE:
			_finish_ride()
		elif event.keycode == KEY_T:
			# Reverse direction along the path. The rider's rotation is
			# rebuilt every frame in _physics_process from the tangent,
			# so we just flip the heading state here.
			heading = -heading


func _process(delta: float) -> void:
	_update_ghost_visuals(delta)
	if not is_riding:
		return
	_update_power_input(delta)


func _update_power_input(delta: float) -> void:
	# Sensor power takes over only when the player selected SENSOR *and* a
	# live reading is fresh. Otherwise the keyboard ↑/↓ ramp stays in
	# control — so an unplugged bridge or a dropped sensor transparently
	# falls back to the keyboard, continuing from the last value with no
	# jump. The keyboard is always the default and the fallback.
	if SensorBridge.using_sensor() and SensorBridge.has_fresh_power():
		target_power_w = clampf(SensorBridge.latest_power_w, 0.0, MAX_POWER_W)
		return
	if Input.is_key_pressed(KEY_UP):
		target_power_w = min(target_power_w + POWER_RATE_WPS * delta, MAX_POWER_W)
	if Input.is_key_pressed(KEY_DOWN):
		target_power_w = max(target_power_w - POWER_RATE_WPS * delta, 0.0)


func _animation_cadence() -> float:
	# Real crank cadence when a sensor is feeding us; otherwise a plausible
	# estimate so the legs still pedal on keyboard power. Zero when coasting.
	if SensorBridge.has_fresh_cadence():
		return SensorBridge.latest_cadence_rpm
	if target_power_w < 5.0:
		return 0.0
	if velocity_mps > 0.5:
		return clampf(58.0 + velocity_mps * 3.6 * 1.15, 60.0, 105.0)
	# Stationary but pedalling (pre-race pen warm-up).
	return clampf(60.0 + target_power_w / 8.0, 60.0, 100.0)


func _trainer_hud_text() -> String:
	# Small HUD tag showing the smart-trainer control mode, if a controllable
	# trainer is connected. Empty string hides the row.
	if not SensorBridge.trainer_available:
		return ""
	match SensorBridge.trainer_mode:
		SensorBridge.TrainerMode.SIM:
			return "SIM"
		SensorBridge.TrainerMode.ERG:
			return "ERG %d W" % SensorBridge.erg_target_w
		_:
			return "off"


# --- Physics tick ---

func _physics_process(delta: float) -> void:
	if not is_riding:
		return

	# Distance-along-path drives everything. Gradient is signed by course
	# direction so "backwards up the hill" reads as a descent.
	var raw_grade := _gradient_at_distance(distance_m)
	var gradient := raw_grade * float(heading) if is_racing else 0.0
	var draft_mult := _compute_draft_multiplier()
	if is_racing:
		velocity_mps = CyclingPhysics.step_velocity(
			target_power_w, velocity_mps, gradient, kit, delta, draft_mult
		)
		if velocity_mps > peak_speed_mps:
			peak_speed_mps = velocity_mps
		distance_m += velocity_mps * delta * float(heading)
		elapsed_s += delta
	else:
		# Pen: bike is held; even with power applied no real forward speed.
		velocity_mps = 0.0

	# Lateral steering: input is in the rider's frame (left/right relative
	# to forward), so flip when heading is reversed.
	var lateral_input := 0.0
	if Input.is_key_pressed(KEY_LEFT):
		lateral_input -= LATERAL_SPEED_MPS * delta
	if Input.is_key_pressed(KEY_RIGHT):
		lateral_input += LATERAL_SPEED_MPS * delta
	_lateral_offset += lateral_input * float(heading)
	if _lateral_offset > ROAD_HALF_WIDTH_M:
		_lateral_offset = ROAD_HALF_WIDTH_M
	elif _lateral_offset < -ROAD_HALF_WIDTH_M:
		_lateral_offset = -ROAD_HALF_WIDTH_M

	# Place + orient the rider from the path. center is the road centerline
	# at this distance; right is the perpendicular world XZ vector. We
	# lift the rider above center by RIDER_GROUND_CLEARANCE so the wheels
	# sit on the road's lifted surface instead of clipping into it.
	var center := _position_at_distance(distance_m)
	var tng := _tangent_at_distance(distance_m)
	var right := Vector3(-tng.z, 0, tng.x)
	rider_node.global_position = (
		center + right * _lateral_offset + Vector3(0, RIDER_GROUND_CLEARANCE, 0)
	)
	var face_y := _heading_at_distance(distance_m)
	if heading == -1:
		face_y += PI
	rider_node.rotation.y = face_y
	# Pitch only the visual sub-node, not the whole rider_node — the
	# camera is a child of rider_node and we want it to keep its fixed
	# look angle. Tilting only the visual means the bike rolls along the
	# tilted surface without the camera also pitching up on every climb.
	rider_visual_node.rotation.x = atan(raw_grade * float(heading))

	_sample_accum_s += delta
	var sample_dt := 1.0 / SAMPLE_HZ
	if _sample_accum_s >= sample_dt:
		_sample_accum_s -= sample_dt
		_samples_buffer.append(
			{
				"t_offset_ms": int(elapsed_s * 1000.0),
				"distance_m": distance_m,
				"speed_mps": velocity_mps,
				"power_w": target_power_w,
			}
		)
		# Track running max/avg so finish() has them without re-scanning.
		if target_power_w > peak_power_w:
			peak_power_w = target_power_w
		_power_sum += target_power_w
		_power_count += 1

	_flush_accum_s += delta
	if _flush_accum_s >= SAMPLE_FLUSH_S and not _samples_buffer.is_empty():
		_flush_accum_s = 0.0
		_flush_samples()

	# Stream our world state to the WS server at WORLD_STATE_HZ.
	_world_state_accum_s += delta
	var world_dt := 1.0 / WORLD_STATE_HZ
	if _world_state_accum_s >= world_dt:
		_world_state_accum_s -= world_dt
		var pos := rider_node.global_position
		WorldClient.send_state(
			{
				"x": pos.x,
				"z": pos.z,
				"heading": heading,
				"speed_mps": velocity_mps,
				"power_w": target_power_w,
				"distance_m": distance_m,
			}
		)

	# Stream the live grade to a smart trainer in SIM mode so resistance
	# follows the road. `gradient` is already 0 in the pre-race pen, so the
	# trainer stays flat until the race starts. The bridge throttles
	# redundant writes; we just tick at a steady low rate here.
	_trainer_accum_s += delta
	if _trainer_accum_s >= 1.0 / TRAINER_SEND_HZ:
		_trainer_accum_s = 0.0
		if SensorBridge.trainer_mode == SensorBridge.TrainerMode.SIM:
			SensorBridge.send_sim_grade(gradient * 100.0, kit.tires.crr)

	# Animate the player's rig: wheels from road speed, legs/cranks from
	# cadence (real sensor cadence when fresh), torso sway from power.
	_player_visual.animate(delta, velocity_mps, _animation_cadence(), target_power_w)

	var sensor_power: bool = SensorBridge.using_sensor() and SensorBridge.has_fresh_power()
	hud.set_power(target_power_w, sensor_power)
	hud.set_trainer(_trainer_hud_text())
	hud.set_speed(velocity_mps)
	hud.set_cadence(SensorBridge.latest_cadence_rpm if SensorBridge.has_fresh_cadence() else -1.0)
	hud.set_heart_rate(SensorBridge.latest_hr_bpm if SensorBridge.has_fresh_hr() else 0)
	hud.set_distance(distance_m)
	var course_length := float(current_course.get("length_m", 0.0))
	if course_length > 0.0:
		hud.set_lap(int(distance_m / course_length) + 1)
	hud.set_grade(gradient * 100.0)
	hud.set_elapsed(elapsed_s)
	hud.set_draft(int(round((1.0 - draft_mult) * 100.0)))
	hud.set_leaderboard(_build_leaderboard())

	# Minimap rider marker. Project XZ → topo UV using the heightmap
	# meta (the topo PNG covers the same area as the heightmap with
	# row 0 = north). Only meaningful after the topo PNG has loaded.
	if _topo_loaded and _terrain_grid_m > 0.0:
		var rp := rider_node.global_position
		var world_w_m: float = float(_terrain_width) * _terrain_grid_m
		var world_h_m: float = float(_terrain_height) * _terrain_grid_m
		if world_w_m > 0.0 and world_h_m > 0.0:
			var max_y_m: float = _terrain_origin_y_m + world_h_m
			var u: float = (rp.x - _terrain_origin_x_m) / world_w_m
			var v: float = (max_y_m - (-rp.z)) / world_h_m
			hud.set_minimap_uv(u, v)

	if not is_racing and GameSession.race_starts_at_unix_s > 0.0:
		var remaining_s: float = GameSession.race_starts_at_unix_s - Time.get_unix_time_from_system()
		hud.show_countdown(max(0.0, remaining_s))


# --- Drafting ---

func _build_leaderboard() -> Array:
	var entries: Array = [
		{
			"name": "You",
			"bib": _my_bib,
			"distance_m": distance_m,
			"is_me": true,
		}
	]
	for rid in _ghosts:
		entries.append(
			{
				"name": str(_ghost_names.get(rid, "Rider")),
				"bib": int(_ghost_bibs.get(rid, 0)),
				"distance_m": float(_ghost_distances.get(rid, 0.0)),
				"is_me": false,
			}
		)
	entries.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["distance_m"]) > float(b["distance_m"])
	)
	return entries


func _compute_draft_multiplier() -> float:
	if _ghosts.is_empty():
		return 1.0

	# Direction "forward" in world Z based on heading.
	var forward_z: float = -1.0 if heading == 1 else 1.0
	var my_pos := rider_node.global_position
	var best_savings := 0.0

	for rid in _ghosts:
		var ghost: Node3D = _ghosts[rid]
		var ghost_pos := ghost.global_position
		# How far ahead (positive = ahead, negative = behind).
		var dz := (ghost_pos.z - my_pos.z) * forward_z
		if dz <= 0.0 or dz > DRAFT_MAX_DISTANCE_M:
			continue
		var dx := absf(ghost_pos.x - my_pos.x)
		if dx > DRAFT_MAX_LATERAL_M:
			continue
		var distance_factor := 1.0 - dz / DRAFT_MAX_DISTANCE_M
		var lateral_factor := 1.0 - dx / DRAFT_MAX_LATERAL_M
		var savings := distance_factor * lateral_factor
		if savings > best_savings:
			best_savings = savings

	var global_factor: float = kit.settings.draft_strength_factor
	return 1.0 - best_savings * DRAFT_FULL_REDUCTION * global_factor


# --- Course profile lookup ---

func _gradient_at_distance(d: float) -> float:
	# Derived from the path's per-segment elevation delta. Falls through
	# to 0.0 when the path isn't ready or has only one waypoint.
	if _course_path.size() < 2:
		return 0.0
	var dd := _wrap_distance(d)
	var i := _find_path_segment(dd)
	var p0: Dictionary = _course_path[i]
	var p1: Dictionary = _course_path[i + 1]
	var de := float(p1["elevation_m"]) - float(p0["elevation_m"])
	var ddist := float(p1["distance_m"]) - float(p0["distance_m"])
	if ddist <= 0.0:
		return 0.0
	return de / ddist


# --- Sample flush + finish ---

func _flush_samples() -> void:
	if _samples_buffer.is_empty() and _pending_uploads.is_empty():
		return
	# Drain the buffer to disk first — that's the durable copy.
	if _local_jsonl != null and not _samples_buffer.is_empty():
		for s in _samples_buffer:
			_local_jsonl.store_line(JSON.stringify(s))
		_local_jsonl.flush()
	# Combine any leftover retries with this flush's payload.
	var to_send: Array = _pending_uploads + _samples_buffer
	_samples_buffer.clear()
	_pending_uploads.clear()
	if to_send.is_empty():
		return
	var ok: bool = await ApiClient.post_samples(current_ride_id, to_send)
	if not ok:
		_pending_uploads = to_send
		push_warning("Sample flush failed, buffering %d for retry" % to_send.size())


func _open_local_jsonl() -> void:
	if current_ride_id.is_empty():
		return
	var dir := "user://activities/%s" % rider_id
	DirAccess.make_dir_recursive_absolute(dir)
	_local_jsonl_path = "%s/%s.jsonl" % [dir, current_ride_id]
	_local_jsonl = FileAccess.open(_local_jsonl_path, FileAccess.WRITE)
	if _local_jsonl == null:
		push_warning("Could not open local JSONL: %s" % _local_jsonl_path)


func _close_local_jsonl() -> void:
	if _local_jsonl != null:
		_local_jsonl.flush()
		_local_jsonl.close()
		_local_jsonl = null


func _finish_ride() -> void:
	if _finishing:
		return
	_finishing = true
	is_riding = false
	# Hand trainer resistance back to flat so the rider isn't left pushing
	# against the last climb's grade after the ride ends.
	SensorBridge.release_trainer()
	WorldClient.disconnect_now()
	hud.set_status("Finishing ride…")

	# Flush the in-memory tail to disk + Django before announcing finish.
	await _flush_samples()
	_close_local_jsonl()

	# Pass the client's locally-computed aggregates so Django can record
	# them without having to re-scan the JSONL.
	var totals: Dictionary = {
		"total_distance_m": distance_m,
		"total_duration_s": elapsed_s,
		"avg_power_w": _avg_power_so_far(),
		"max_power_w": _max_power_so_far(),
		"peak_speed_mps": peak_speed_mps,
	}
	var result: Dictionary = await ApiClient.finish_ride(
		current_ride_id, totals, "explicit"
	)
	if result.is_empty():
		hud.set_status("Finish failed")
		return

	var dist_km := float(result.get("total_distance_m", distance_m)) / 1000.0
	var time_s := float(result.get("total_duration_s", elapsed_s))
	var avg_w := int(round(float(result.get("avg_power_w", totals["avg_power_w"]))))
	var max_w := int(round(float(result.get("max_power_w", totals["max_power_w"]))))
	hud.set_status("")
	hud.hide_countdown()
	# Game mode: jump to the shared race-results screen (live standings).
	# Solo: show the inline ride-complete panel.
	if not GameSession.is_solo:
		get_tree().change_scene_to_file("res://scenes/results.tscn")
		return
	_show_summary(dist_km, time_s, avg_w, max_w)


func _avg_power_so_far() -> float:
	if _power_count <= 0:
		return 0.0
	return _power_sum / float(_power_count)


func _max_power_so_far() -> float:
	return peak_power_w


func _show_summary(dist_km: float, time_s: float, avg_w: int, max_w: int) -> void:
	var course_length := float(current_course.get("length_m", 0.0))
	var laps: int = (
		int(distance_m / course_length) + 1 if course_length > 0.0 else 1
	)
	var peak_kph := peak_speed_mps * 3.6

	var canvas := CanvasLayer.new()
	add_child(canvas)

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.7)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 36)
	margin.add_theme_constant_override("margin_right", 36)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 28)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Ride Complete"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var minutes: int = int(time_s) / 60
	var seconds: int = int(time_s) % 60
	for line in [
		"Distance:    %.2f km" % dist_km,
		"Time:           %d:%02d" % [minutes, seconds],
		"Laps:           %d" % laps,
		"Avg power: %d W" % avg_w,
		"Max power: %d W" % max_w,
		"Peak speed: %.1f km/h" % peak_kph,
	]:
		var l := Label.new()
		l.text = line
		l.add_theme_font_size_override("font_size", 22)
		vbox.add_child(l)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	vbox.add_child(spacer)

	var btn := Button.new()
	btn.text = "Back to Menu"
	btn.add_theme_font_size_override("font_size", 22)
	btn.custom_minimum_size = Vector2(280, 0)
	btn.pressed.connect(
		func() -> void:
			GameSession.reset()
			get_tree().change_scene_to_file("res://scenes/main.tscn")
	)
	vbox.add_child(btn)


# --- Multiplayer ghosts ---

func _on_welcome(riders: Array) -> void:
	for r in riders:
		var rid: String = str(r.get("rider_id", ""))
		if rid.is_empty():
			continue
		_spawn_ghost(
			rid, str(r.get("display_name", "")), int(r.get("bib_number", 0))
		)
		var state = r.get("state", {})
		if state is Dictionary and not state.is_empty():
			_record_ghost_state(rid, state, true)


func _on_rider_joined(rid: String, display_name: String, bib_number: int) -> void:
	if rid.is_empty():
		return
	_spawn_ghost(rid, display_name, bib_number)


func _on_rider_left(rid: String) -> void:
	if _ghosts.has(rid):
		_ghosts[rid].queue_free()
		_ghosts.erase(rid)
	_ghost_visuals.erase(rid)
	_ghost_targets.erase(rid)
	_ghost_names.erase(rid)
	_ghost_bibs.erase(rid)
	_ghost_distances.erase(rid)


func _on_rider_state(rid: String, state: Dictionary) -> void:
	if not _ghosts.has(rid):
		_spawn_ghost(rid, "", 0)
	# First state for this ghost: snap into place (avoids a visible slide
	# from world origin). Subsequent states only update the target; _process
	# lerps the visual node toward it.
	var snap := not _ghost_targets.has(rid)
	_record_ghost_state(rid, state, snap)


func _spawn_ghost(rid: String, display_name: String = "", bib: int = 0) -> void:
	if _ghosts.has(rid):
		# Already spawned — just update name/bib if newly provided.
		if not display_name.is_empty():
			_ghost_names[rid] = display_name
		if bib > 0 and int(_ghost_bibs.get(rid, 0)) == 0:
			_ghost_bibs[rid] = bib
			_add_bib_label(_ghosts[rid], bib, GHOST_COLOR)
		return
	var ghost := Node3D.new()
	ghost.name = "Ghost_%s" % rid
	var visual := RiderVisual.new(GHOST_COLOR)
	ghost.add_child(visual)
	add_child(ghost)
	_ghosts[rid] = ghost
	_ghost_visuals[rid] = visual
	if not display_name.is_empty():
		_ghost_names[rid] = display_name
	if bib > 0:
		_ghost_bibs[rid] = bib
		_add_bib_label(ghost, bib, GHOST_COLOR)


func _add_bib_label(parent: Node3D, number: int, jersey: Color) -> void:
	var label := Label3D.new()
	label.text = "%d" % number
	label.font_size = 64
	label.outline_size = 12
	label.modulate = Color.WHITE
	label.outline_modulate = jersey.darkened(0.5)
	# Sit on the upper back of the jersey. Label3D's front face is +Z by
	# default, which is the side the chase camera lives on.
	label.position = Vector3(0.0, 1.30, 0.22)
	label.fixed_size = true
	label.pixel_size = 0.00117  # was 0.0035, ~3× smaller
	label.no_depth_test = true
	parent.add_child(label)


func _record_ghost_state(rid: String, state: Dictionary, snap: bool) -> void:
	if not _ghosts.has(rid):
		return
	var pos := Vector3(float(state.get("x", 0.0)), 0.0, float(state.get("z", 0.0)))
	var h: int = int(state.get("heading", 1))
	var speed: float = float(state.get("speed_mps", 0.0))
	var velocity := Vector3(0.0, 0.0, speed * (-1.0 if h == 1 else 1.0))
	var yaw: float = 0.0 if h == 1 else PI
	_ghost_targets[rid] = {
		"pos": pos,
		"velocity": velocity,
		"yaw": yaw,
		"t_ms": Time.get_ticks_msec(),
	}
	if state.has("distance_m"):
		_ghost_distances[rid] = float(state["distance_m"])
	if snap:
		var ghost: Node3D = _ghosts[rid]
		ghost.global_position = Vector3(pos.x, _elevation_at_distance(-pos.z), pos.z)
		ghost.rotation.y = yaw


func _update_ghost_visuals(delta: float) -> void:
	if _ghost_targets.is_empty():
		return
	var now_ms: int = Time.get_ticks_msec()
	var smoothing: float = clampf(GHOST_SMOOTH_RATE * delta, 0.0, 1.0)
	for rid in _ghost_targets:
		if not _ghosts.has(rid):
			continue
		var ghost: Node3D = _ghosts[rid]
		var t: Dictionary = _ghost_targets[rid]
		var elapsed: float = minf(float(now_ms - int(t["t_ms"])) / 1000.0, GHOST_DEAD_RECKON_CAP_S)
		var predicted_pos: Vector3 = t["pos"] + t["velocity"] * elapsed
		ghost.global_position = ghost.global_position.lerp(predicted_pos, smoothing)
		# WS protocol doesn't carry Y; plant the ghost on the same road we render.
		ghost.global_position.y = _elevation_at_distance(-ghost.global_position.z)
		ghost.rotation.y = lerp_angle(ghost.rotation.y, t["yaw"], smoothing)
		# Animate the ghost's rig from its reported speed (cadence estimated —
		# the wire protocol doesn't carry it).
		var gv: RiderVisual = _ghost_visuals.get(rid)
		if gv != null:
			var gspeed: float = (t["velocity"] as Vector3).length()
			var gcad: float = 0.0 if gspeed < 0.5 else clampf(58.0 + gspeed * 3.6 * 1.15, 60.0, 105.0)
			gv.animate(delta, gspeed, gcad, 0.0)
