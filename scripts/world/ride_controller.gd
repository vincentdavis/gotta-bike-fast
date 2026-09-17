extends Node3D

# Phase 1 ride controller — builds the world, fetches a course, drives
# physics-based rider movement, batches samples to the backend, finishes
# the ride on Esc.

const HUD_SCENE := preload("res://scenes/hud.tscn")

const POWER_RATE_WPS := 80.0
# Absolute input ceiling only — the real keyboard cap is the rider's CP curve
# (cp_limiter). High enough that no preset's 5s point gets truncated.
const MAX_POWER_W := 2000.0
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
var camera_rig: CameraRig
var hud: CanvasLayer

var kit: PhysicsKit = PhysicsKit.new()
var rider_id: String = ""
var current_ride_id: String = ""
var current_course: Dictionary = {}
# Critical Power limiter: caps keyboard power to the rider's CP curve (clamped
# to the race's limits). Sensor power is never clamped — real legs are real.
var cp_limiter: CPLimiter = null
# Procedural ride audio (wind bed + countdown beeps + finish stinger).
var ride_audio: RideAudio = null
var _last_countdown_n: int = -1
# Settlement centres along the course (distance_m) — drives the crowd murmur.
var _town_centers_d: Array = []

var is_riding: bool = false
var is_racing: bool = false  # false during the pre-race pen (game mode only)
var _is_solo_ride: bool = false  # solo vs. multiplayer game — gates Game Speed
# The ride never started (server problem): Esc / the finish tap go back.
var _start_failed: bool = false
var _game_speed: float = 1.0     # ride time-scale (GraphicsSettings.game_speed)
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

# Minimap (in-ride). _minimap_kind: 0 = none, 1 = client-side fallback drawn
# from the course path polyline, 2 = the server's hillshaded topo PNG (used
# when it loads). Either way we project the rider into image UV every physics
# tick so the HUD marker tracks them: topo reuses the heightmap_* meta, the
# fallback uses _minimap_bounds (the path's x_m/y_m extent).
var _minimap_kind: int = 0
var _minimap_bounds: Dictionary = {}
var _topo_loaded: bool = false  # mirrors _minimap_kind == 2 (kept for clarity)

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
# The strip's height grid, kept so _ground_height_at can sample the exact
# surface the mesh draws (same cell origin/spacing/triangle split).
var _strip_heights := PackedFloat32Array()
var _strip_min_x := 0.0
var _strip_min_y := 0.0
var _strip_g := 0.0
var _strip_w := 0
var _strip_h := 0
# Road-proximity index: densified path points bucketed on a coarse grid, so
# "is (x, z) within r of the road" works for sparse paths too (the synthetic
# Flat 5K Loop is ONE 5 km segment between two waypoints).
const ROAD_INDEX_CELL_M := 16.0
const ROAD_INDEX_STEP_M := 1.0
var _road_index: Dictionary = {}
# distance_m of every waypoint, for binary-search segment lookup (the linear
# scan cost O(route) per call — per physics tick, and per dash at build).
var _path_dists := PackedFloat64Array()
# Backdrop depth extension. The ring rides at the rider's height (so peaks
# keep the same place on the horizon everywhere), and its pieces would hover
# over the y = 0 ground on raised sections — so a column under each mountain
# and the tower shafts are stretched down to the ground each time the rider's
# height changes. Per-piece rest data, filled when the backdrop is built.
var _backdrop_columns: MultiMesh = null
var _backdrop_col_data: Array = []    # [px, pz, yaw, width]
var _backdrop_towers: MultiMesh = null
var _backdrop_tower_data: Array = []  # [rest Basis, roof-centre Vector3]
var _backdrop_depth := -1.0

# Belleville theme set-dressing — telegraph poles, path-anchored. Parented
# under one node rebuilt wholesale when terrain arrives. Held off
# _clear_existing_scenery's path (those are direct-child MultiMeshInstance3D);
# freed/rebuilt explicitly in _setup_belleville_dressing.
var _belleville_dressing: Node3D = null
# Towns along the course (building MultiMeshes) — nested under one Node3D so
# _clear_existing_scenery's direct-child sweep never touches it; rebuilt
# wholesale when terrain arrives, same contract as the dressing.
var _towns: Node3D = null
# Distant mountains + leaning city — a rider-locked backdrop. Built once and
# moved to the rider's position every physics tick, so the horizon stays
# populated for the whole ride (a midpoint-anchored ring vanished into the fog
# on long point-to-point courses) and a peak can never sit on the road the
# rider is actually on (it's permanently distant — the rider never reaches it).
var _backdrop: Node3D = null

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
	# The full-screen ink/posterize/grain post-process sits below the HUD and
	# turns the world into an aged hand-drawn picture. Built last so it
	# composites over everything 3D. It's a 9-tap full-screen pass at OUTPUT
	# resolution (render_scale doesn't touch it), so it's skipped at LOW
	# quality — the muted palette + caricature still carry the look without the
	# per-pixel ink cost. HUD theming is cheap, so it always applies.
	if GraphicsSettings.quality != GraphicsSettings.Quality.LOW:
		add_child(BellevillePost.new())
	hud.apply_appearance()
	# A login ended from the website (or another device) mid-ride.
	ApiClient.auth_expired.connect(_on_auth_expired)
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

	# Repaint the atmosphere muted + flat, dropping the shiny/bloomy effects
	# that fight a hand-drawn look. The post-process adds the ink + grain; here
	# we just set a sun-faded sepia world.
	sky_mat.sky_top_color = Belleville.SAGE.darkened(0.05)
	sky_mat.sky_horizon_color = Belleville.PAPER
	sky_mat.sky_curve = 0.25
	sky_mat.ground_bottom_color = Belleville.UMBER
	sky_mat.ground_horizon_color = Belleville.PAPER_DARK
	sky_mat.sun_angle_max = 18.0
	sky_mat.sun_curve = 0.05
	env.ambient_light_color = Belleville.PAPER
	env.ambient_light_energy = 0.7
	env.ssr_enabled = false
	env.glow_enabled = false
	env.volumetric_fog_albedo = Belleville.PAPER
	env.fog_light_color = Belleville.PAPER
	env.fog_density = 0.0009
	# Desaturate toward sepia + lift contrast a touch; the duotone grade in
	# the post-process finishes the job.
	env.adjustment_saturation = 0.72
	env.adjustment_contrast = 1.08
	env.adjustment_brightness = 1.02

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

	# The shared world-space ground shader, so this backdrop matches the
	# strip/terrain seamlessly. (It used to be a StandardMaterial3D with a
	# NoiseTexture2D, which fills asynchronously — the browser renderer kept
	# its white placeholder and drew the plane washed-out cream.) Only seen
	# until the course's ground strip replaces it.
	ground.material_override = _ground_material()
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
	_build_road_index()
	_setup_ground_strip()
	_setup_road()
	_setup_markers()
	_setup_scenery()
	_setup_belleville_dressing()
	_setup_towns()
	_setup_backdrop()
	# Async terrain fetch — populates _terrain_heights + adds the mesh
	# beside the strip when it arrives. Re-places scenery onto the
	# heightmap once it does.
	if not str(current_course.get("heightmap_url", "")).is_empty():
		_setup_terrain_async()
	# Always draw a client-side fallback minimap from the course path so every
	# ride shows a map immediately — even synthetic/loop courses and rides where
	# the server never produced a topo PNG.
	_setup_fallback_minimap()
	# Async topo PNG fetch for the in-ride minimap. Independent of the
	# heightmap fetch; either can fail without affecting the other. When it
	# lands it upgrades the fallback to the nicer hillshaded version.
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

	# Decode pixel values into world elevations. Two encodings exist:
	#  - legacy: 16-bit grayscale PNG, which Godot DOWNCONVERTS to 8 bits
	#    (loads as FORMAT_L8) — quantized to range/255 steps, kept only so
	#    courses pushed before the fix still render;
	#  - rg16: RGB8 with the 16-bit value split R=high byte, G=low byte —
	#    lossless through any decoder (value = R*256 + G).
	var range_m: float = _terrain_max_ele - _terrain_min_ele
	var rg16: bool = img.get_format() != Image.FORMAT_L8
	_terrain_heights.resize(w * h)
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var t: float
			if rg16:
				t = (roundf(c.r * 255.0) * 256.0 + roundf(c.g * 255.0)) / 65535.0
			else:
				t = c.r
			_terrain_heights[y * w + x] = _terrain_min_ele + t * range_m

	# Pin a corridor of terrain under the road BEFORE meshing — the DEM and
	# the GPX's own elevations disagree by metres in places, which used to
	# bury stretches of road inside hillsides. Tree placement also samples
	# the carved heights, so trees won't float over the corridor.
	_carve_road_corridor()

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
	# Rebuild the Belleville dressing too so its poles sit on the real terrain
	# height instead of the path-elevation fallback used at first build.
	_setup_belleville_dressing()
	# And the towns — their foundations also snap to the real ground.
	_setup_towns()


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
	_minimap_kind = 2  # upgrade from the fallback to the hillshaded topo


func _setup_fallback_minimap() -> void:
	# Draw the course centerline into a small square texture and hand it to the
	# HUD as a minimap. Uses the path's own x_m/y_m extent (no heightmap needed),
	# so it works for every course — including synthetic/loop rides. The rider
	# marker is projected with the same transform in _physics_process.
	if _minimap_kind == 2:
		return  # the nicer topo already loaded; don't downgrade
	var pts: Array = _course_path
	if pts.size() < 2:
		return
	var min_x := INF
	var max_x := -INF
	var min_y := INF
	var max_y := -INF
	for p in pts:
		var x := float(p["x_m"])
		var y := float(p["y_m"])
		min_x = minf(min_x, x); max_x = maxf(max_x, x)
		min_y = minf(min_y, y); max_y = maxf(max_y, y)
	# Square + undistorted: fit the larger extent and centre the route.
	var span := maxf(maxf(max_x - min_x, max_y - min_y), 1.0)
	var size := 256
	var pad := 20
	_minimap_bounds = {
		"cx": (min_x + max_x) * 0.5,
		"cy": (min_y + max_y) * 0.5,
		"span": span,
		"size": size,
		"pad": pad,
		"inner": float(size - 2 * pad),
	}
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Belleville.PAPER)
	var px_pts := PackedVector2Array()
	for p in pts:
		var uv := _path_minimap_uv(float(p["x_m"]), float(p["y_m"]))
		px_pts.append(Vector2(uv.x * float(size), uv.y * float(size)))
	for i in range(1, px_pts.size()):
		_draw_seg_on_image(img, px_pts[i - 1], px_pts[i], Belleville.INK, 3)
	# Start (terracotta) + finish (teal) dots.
	_stamp_disc(img, px_pts[0], Belleville.TERRACOTTA, 8)
	_stamp_disc(img, px_pts[px_pts.size() - 1], Belleville.TEAL, 8)
	hud.set_minimap_texture(ImageTexture.create_from_image(img))
	_minimap_kind = 1


func _path_minimap_uv(x_m: float, y_m: float) -> Vector2:
	# Path frame (x_m east, y_m north) → texture UV, north at the top, matching
	# how _setup_fallback_minimap drew the polyline. Clamped so a rider straying
	# just past the path bounds still pins inside the map.
	var b := _minimap_bounds
	if b.is_empty():
		return Vector2(0.5, 0.5)
	var span: float = b["span"]
	var half := span * 0.5
	var cu := (x_m - (float(b["cx"]) - half)) / span
	var cv := ((float(b["cy"]) + half) - y_m) / span
	var size: float = float(b["size"])
	var pad: float = float(b["pad"])
	var inner: float = float(b["inner"])
	var pxp := pad + clampf(cu, 0.0, 1.0) * inner
	var pyp := pad + clampf(cv, 0.0, 1.0) * inner
	return Vector2(pxp / size, pyp / size)


func _draw_seg_on_image(img: Image, a: Vector2, b: Vector2, col: Color, thick: int) -> void:
	var d := b - a
	var steps := int(maxf(absf(d.x), absf(d.y)))
	if steps <= 0:
		_stamp_disc(img, a, col, thick)
		return
	for s in steps + 1:
		_stamp_disc(img, a + d * (float(s) / float(steps)), col, thick)


func _stamp_disc(img: Image, p: Vector2, col: Color, diameter: int) -> void:
	var r := diameter / 2
	var cx := int(round(p.x))
	var cy := int(round(p.y))
	var w := img.get_width()
	var h := img.get_height()
	for oy in range(-r, r + 1):
		for ox in range(-r, r + 1):
			if ox * ox + oy * oy > r * r:
				continue
			var xx := cx + ox
			var yy := cy + oy
			if xx >= 0 and yy >= 0 and xx < w and yy < h:
				img.set_pixel(xx, yy, col)


func _clear_existing_scenery() -> void:
	# Find prior MultiMeshInstance3D children (the tree forest from the
	# first scenery pass) and remove them. Identified by the unique
	# MultiMesh resource used in _setup_scenery; fall back to checking
	# child type if needed.
	for child in get_children():
		if child is MultiMeshInstance3D:
			child.queue_free()


func _carve_road_corridor() -> void:
	# Blend the heightmap toward (path elevation − DROP_M) within outer_m of
	# the course centerline, fully pinned inside inner_m. Where multiple path
	# points influence a cell, the strongest (nearest) wins. This guarantees
	# the road sits proud of the terrain everywhere along the route while the
	# corridor's edges fade smoothly back into the real DEM.
	const DROP_M := 0.35
	if _terrain_width < 2 or _terrain_grid_m <= 0.0 or _course_path.size() < 2:
		return
	var g := _terrain_grid_m
	var w := _terrain_width
	var h := _terrain_height
	# Radii must scale with the grid: long routes get coarse heightmaps
	# (40–60 m between vertices), and a fixed radius smaller than the
	# spacing misses every vertex near most of the road. Pinning ~1.3
	# cells fully guarantees all corners of any cell the road crosses sit
	# below it, so the triangulated surface can't poke through.
	var inner_m := maxf(6.0, g * 1.3)
	var outer_m := maxf(28.0, g * 2.4)
	var carve_w := PackedFloat32Array()
	carve_w.resize(w * h)  # zero-filled
	var carve_ele := PackedFloat32Array()
	carve_ele.resize(w * h)
	var reach := int(ceil(outer_m / g)) + 1
	for p in _course_path:
		# Path x/y are in the same local frame as the heightmap origin.
		var cx := (float(p["x_m"]) - _terrain_origin_x_m) / g
		var cy := (float(p["y_m"]) - _terrain_origin_y_m) / g
		var target := float(p["elevation_m"]) - DROP_M
		var ix0 := maxi(int(floor(cx)) - reach, 0)
		var ix1 := mini(int(floor(cx)) + reach, w - 1)
		var iy0 := maxi(int(floor(cy)) - reach, 0)
		var iy1 := mini(int(floor(cy)) + reach, h - 1)
		for iy in range(iy0, iy1 + 1):
			for ix in range(ix0, ix1 + 1):
				var dx := (float(ix) - cx) * g
				var dy := (float(iy) - cy) * g
				var dist := sqrt(dx * dx + dy * dy)
				if dist >= outer_m:
					continue
				var wgt := 1.0 - smoothstep(inner_m, outer_m, dist)
				var idx := iy * w + ix
				if wgt > carve_w[idx]:
					carve_w[idx] = wgt
					carve_ele[idx] = target
	for i in w * h:
		if carve_w[i] > 0.0:
			_terrain_heights[i] = lerpf(float(_terrain_heights[i]), carve_ele[i], carve_w[i])


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
	# Emit one quad per cell as two triangles. Godot front faces wind
	# CLOCKWISE seen from the camera, so for an up-facing surface the order
	# below makes generate_normals() produce +Y normals (the old order gave
	# downward normals — the shader's slope test then read every face as a
	# cliff and painted the whole terrain rock).
	for y in range(h - 1):
		for x in range(w - 1):
			var v00: Vector3 = verts[y * w + x]
			var v10: Vector3 = verts[y * w + (x + 1)]
			var v01: Vector3 = verts[(y + 1) * w + x]
			var v11: Vector3 = verts[(y + 1) * w + (x + 1)]
			st.add_vertex(v00); st.add_vertex(v01); st.add_vertex(v10)
			st.add_vertex(v10); st.add_vertex(v01); st.add_vertex(v11)
	st.generate_normals()

	var inst := MeshInstance3D.new()
	inst.mesh = st.commit()
	inst.material_override = _ground_material()
	add_child(inst)
	_terrain_inst = inst


func _terrain_height_at(world_x: float, world_z: float) -> float:
	# Height of the terrain mesh. World Z = -y_m in the path's local frame, so
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
	# Same v01–v10 triangle split as _build_terrain_mesh, so objects sit on
	# the surface actually drawn (a bilinear blend is off by up to a quarter
	# of the cell's twist).
	if tx + ty <= 1.0:
		return e00 + tx * (e10 - e00) + ty * (e01 - e00)
	return e11 + (1.0 - tx) * (e01 - e11) + (1.0 - ty) * (e10 - e11)


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


func _path_samples(max_step: float) -> PackedVector3Array:
	# Every waypoint plus evenly spaced fill-ins, so consecutive samples are at
	# most max_step apart. World coords (x, elevation, -path_y); elevation is
	# linear between waypoints, exactly like the road mesh.
	var out := PackedVector3Array()
	for i in _course_path.size():
		var p: Dictionary = _course_path[i]
		var a := Vector3(float(p["x_m"]), float(p["elevation_m"]), -float(p["y_m"]))
		if i > 0:
			var q: Dictionary = _course_path[i - 1]
			var b := Vector3(float(q["x_m"]), float(q["elevation_m"]), -float(q["y_m"]))
			var n := int(ceil(Vector2(a.x - b.x, a.z - b.z).length() / max_step))
			for k in range(1, n):
				out.append(b.lerp(a, float(k) / float(n)))
		out.append(a)
	return out


func _build_road_index() -> void:
	_road_index = {}
	for s in _path_samples(ROAD_INDEX_STEP_M):
		var key := Vector2i(floori(s.x / ROAD_INDEX_CELL_M), floori(s.z / ROAD_INDEX_CELL_M))
		if not _road_index.has(key):
			_road_index[key] = PackedVector2Array()
		var bucket: PackedVector2Array = _road_index[key]
		bucket.append(Vector2(s.x, s.z))
		_road_index[key] = bucket


func _near_road(x: float, z: float, radius: float) -> bool:
	# True if any densified road point lies within radius of (x, z). The 3×3
	# bucket neighbourhood covers radius ≤ ROAD_INDEX_CELL_M.
	var r2 := radius * radius
	var cx := floori(x / ROAD_INDEX_CELL_M)
	var cz := floori(z / ROAD_INDEX_CELL_M)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var key := Vector2i(cx + dx, cz + dz)
			if not _road_index.has(key):
				continue
			for q in _road_index[key]:
				var ex: float = q.x - x
				var ez: float = q.y - z
				if ex * ex + ez * ez < r2:
					return true
	return false


func _ground_height_at(x: float, z: float) -> float:
	# Height of the ground actually drawn at world (x, z): the DEM terrain
	# once loaded, else the ground strip (sampled with the mesh's own
	# triangle split, so objects sit exactly on it), else the flat y = 0
	# skirt/plane.
	# _terrain_inst, not _terrain_width: the width is known before the DEM
	# downloads (and stays set if the download fails).
	if _terrain_inst != null:
		return _terrain_height_at(x, z)
	if _strip_w < 2 or _strip_h < 2 or _strip_g <= 0.0:
		return 0.0
	var tri := _strip_triangle(x, z)
	if tri.is_empty():
		return 0.0  # on the skirt
	return (
		_strip_heights[tri[0]] * tri[3]
		+ _strip_heights[tri[1]] * tri[4]
		+ _strip_heights[tri[2]] * tri[5]
	)


func _setup_ground_strip() -> void:
	# Path-following backdrop ground used until (or instead of) the real
	# heightmap terrain. Built as a RASTERIZED heightfield — a grid whose
	# cells take the elevation of the nearest road point (minus a road-bed
	# drop), fading toward the flat y=0 skirt with distance. The previous
	# approach (a 120 m-wide ribbon swept along the path) self-overlapped on
	# any bend tighter than its half-width, and overlap pieces from higher
	# waypoints buried stretches of road ("road disappears" on real GPX
	# courses). A grid cannot self-overlap, and _clamp_strip_under_road then
	# lowers it under every asphalt triangle, so the road stays proud of the
	# ground by construction — even across dips and where two legs of the
	# route pass close (the upper leg then reads as a low causeway rather
	# than burying the lower one).
	const REACH_M := 170.0  # min ground influence radius around the path
	const DROP_M := 0.35    # ground sits this far below the road bed
	if _course_path.size() < 2:
		return

	# Grid over the path bbox + margin. Spacing adapts so big routes keep
	# a sane vertex count (~200 cells along the larger side).
	var min_x := INF; var max_x := -INF
	var min_y := INF; var max_y := -INF
	for p in _course_path:
		min_x = minf(min_x, float(p["x_m"])); max_x = maxf(max_x, float(p["x_m"]))
		min_y = minf(min_y, float(p["y_m"])); max_y = maxf(max_y, float(p["y_m"]))
	var extent := maxf(max_x - min_x, max_y - min_y) + 2.0 * REACH_M
	var g := maxf(15.0, ceilf(extent / 200.0 / 5.0) * 5.0)
	# Ground within INNER of the road keeps the road's own grade (every vertex
	# a road-touching triangle can use), then fades toward y = 0 by REACH.
	# Fading from the road itself sank those vertices metres below high roads,
	# and so did a fixed reach once coarse grids (big routes) outgrew it.
	var inner_m := g * 1.5 + 3.0
	var reach := maxf(REACH_M, inner_m + 40.0)
	# Margin = reach: the fade finishes inside the grid, so the border sits at
	# exactly y = 0 for the skirt, and it is wider than any triangle the road
	# can touch, so the clamp below never moves a border vertex (it cracked
	# the skirt seam once g reached 170 m, on > ~33 km routes).
	var margin := reach
	min_x -= margin; max_x += margin
	min_y -= margin; max_y += margin
	var w := int(ceil((max_x - min_x) / g)) + 1
	var h := int(ceil((max_y - min_y) / g)) + 1

	# Stamp the NEAREST road elevation per cell, from the DENSIFIED path (every
	# waypoint plus fill-ins ≤ g/2 apart — sparse synthetic paths otherwise
	# left most of the road hovering over a flat plain). That keeps the ground
	# ~DROP_M under the road along steady grades; _clamp_strip_under_road
	# then fixes the places where interpolation still pokes through.
	var near := PackedFloat32Array()
	near.resize(w * h)
	near.fill(INF)
	var ele := PackedFloat32Array()
	ele.resize(w * h)
	var reach_cells := int(ceil(reach / g)) + 1
	for sample in _path_samples(g * 0.5):
		var cx := (sample.x - min_x) / g
		var cy := (-sample.z - min_y) / g
		var target := sample.y - DROP_M
		var ix0 := maxi(int(floor(cx)) - reach_cells, 0)
		var ix1 := mini(int(floor(cx)) + reach_cells, w - 1)
		var iy0 := maxi(int(floor(cy)) - reach_cells, 0)
		var iy1 := mini(int(floor(cy)) + reach_cells, h - 1)
		for iy in range(iy0, iy1 + 1):
			for ix in range(ix0, ix1 + 1):
				var dx := (float(ix) - cx) * g
				var dy := (float(iy) - cy) * g
				var dist := sqrt(dx * dx + dy * dy)
				if dist >= reach - 0.01:  # (the border ring stays exactly 0)
					continue
				var idx := iy * w + ix
				if dist < near[idx]:
					near[idx] = dist
					ele[idx] = target

	# Mesh it exactly like the terrain heightfield (clockwise fronts).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_strip_heights = PackedFloat32Array()
	_strip_heights.resize(w * h)
	for idx in w * h:
		if near[idx] < INF:
			# fades to the y = 0 skirt beyond the inner zone
			_strip_heights[idx] = ele[idx] * (1.0 - smoothstep(inner_m, reach, near[idx]))
	_strip_min_x = min_x
	_strip_min_y = min_y
	_strip_g = g
	_strip_w = w
	_strip_h = h
	_clamp_strip_under_road(DROP_M)
	var verts: Array = []
	verts.resize(w * h)
	for iy in h:
		for ix in w:
			var idx := iy * w + ix
			verts[idx] = Vector3(
				min_x + float(ix) * g, _strip_heights[idx], -(min_y + float(iy) * g)
			)
	for iy in range(h - 1):
		for ix in range(w - 1):
			var v00: Vector3 = verts[iy * w + ix]
			var v10: Vector3 = verts[iy * w + (ix + 1)]
			var v01: Vector3 = verts[(iy + 1) * w + ix]
			var v11: Vector3 = verts[(iy + 1) * w + (ix + 1)]
			st.add_vertex(v00); st.add_vertex(v01); st.add_vertex(v10)
			st.add_vertex(v10); st.add_vertex(v01); st.add_vertex(v11)
	_add_ground_skirt(st, min_x, min_y, g, w, h)
	st.generate_normals()
	var inst := MeshInstance3D.new()
	inst.mesh = st.commit()
	inst.material_override = _ground_material()
	add_child(inst)
	_ground_strip_inst = inst
	# The strip + skirt now cover the whole backdrop area, so the flat plane
	# is redundant. It has to go: the strip's outer cells sit at exactly
	# y = 0 — coplanar with the plane — and the browser renderer's classic
	# depth buffer turned that overlap into distant flicker.
	if _ground_inst != null:
		_ground_inst.visible = false


func _strip_triangle(x: float, z: float) -> Array:
	# [i0, i1, i2, w0, w1, w2]: the strip grid vertices and barycentric
	# weights of the drawn triangle under world (x, z) — cells are split
	# along the v01–v10 diagonal, exactly as the mesh is emitted. Empty when
	# (x, z) lies outside the grid.
	var fx := (x - _strip_min_x) / _strip_g
	var fy := (-z - _strip_min_y) / _strip_g
	if fx < 0.0 or fy < 0.0 or fx > float(_strip_w - 1) or fy > float(_strip_h - 1):
		return []
	var ix := mini(int(fx), _strip_w - 2)
	var iy := mini(int(fy), _strip_h - 2)
	var u := fx - float(ix)
	var v := fy - float(iy)
	var i00 := iy * _strip_w + ix
	var i10 := i00 + 1
	var i01 := i00 + _strip_w
	var i11 := i01 + 1
	if u + v <= 1.0:
		return [i00, i10, i01, 1.0 - u - v, u, v]
	return [i11, i01, i10, u + v - 1.0, 1.0 - u, 1.0 - v]


func _clamp_strip_under_road(drop_m: float) -> void:
	# Keep the road visible everywhere. Interpolating nearest-road heights
	# across a cell can lift the ground through the road bed — at the bottom
	# of a dip (Rollers 5K hid ~10 m of road) or where two legs of a route
	# pass close at different heights. Wherever the drawn ground rises above
	# road − drop_m at a check point, the corners of the triangle under it are
	# lowered by exactly that excess (largest excess per corner wins), which
	# puts the check point at or below the target; ground elsewhere is left
	# alone (lowering corners wholesale floated the road over every climb).
	# The checks walk the ASPHALT's own triangles (same corners as
	# _setup_road): road and ground are both piecewise linear, so over each
	# asphalt triangle the gap only changes slope along its edges where they
	# cross grid lines, and inside it at grid vertices — all of which are
	# checked, so every asphalt triangle ends ≥ drop_m (+ lift) above ground.
	const HALF_W := 2.0  # _setup_road's ROAD_WIDTH / 2
	var lower := PackedFloat32Array()
	lower.resize(_strip_heights.size())
	for i in range(_course_path.size() - 1):
		var c := _asphalt_corners(i, HALF_W)
		var l0: Vector3 = c[0]
		var rr0: Vector3 = c[1]
		var l1: Vector3 = c[2]
		var rr1: Vector3 = c[3]
		# The two asphalt triangles: (l0, l1, rr0) and (rr0, l1, rr1).
		_clamp_line(l0, l1, drop_m, lower)
		_clamp_line(rr0, rr1, drop_m, lower)
		_clamp_line(l0, rr0, drop_m, lower)
		_clamp_line(l1, rr1, drop_m, lower)
		_clamp_line(rr0, l1, drop_m, lower)
		_clamp_triangle_vertices(l0, l1, rr0, drop_m, lower)
		_clamp_triangle_vertices(rr0, l1, rr1, drop_m, lower)
	# Apply — never to the border ring, which must stay at y = 0 for the skirt
	# (the margin keeps every check away from it; this is belt and braces).
	for iy in range(1, _strip_h - 1):
		for ix in range(1, _strip_w - 1):
			var idx := iy * _strip_w + ix
			_strip_heights[idx] -= lower[idx]


func _asphalt_corners(seg: int, half_w: float) -> Array:
	# [l0, r0, l1, r1] of segment seg's asphalt quad, exactly as _setup_road
	# builds them (y = path elevation, without the road lift).
	var a := _path_point(seg)
	var b := _path_point(seg + 1)
	var r0: Vector3 = _waypoint_rights[seg] if seg < _waypoint_rights.size() else Vector3.ZERO
	var r1: Vector3 = _waypoint_rights[seg + 1] if seg + 1 < _waypoint_rights.size() else r0
	return [a - r0 * half_w, a + r0 * half_w, b - r1 * half_w, b + r1 * half_w]


func _diagonal_crossing(seg: int, d0: float, d1: float) -> float:
	# Path distance in (d0, d1) where the road centreline crosses segment
	# seg's asphalt diagonal (r0 → l1), or -1 if it doesn't.
	var c := _asphalt_corners(seg, 2.0)
	var p0 := _position_at_distance(d0)
	var p1 := _position_at_distance(d1)
	var a := Vector2(p0.x, p0.z)
	var b := Vector2(p1.x, p1.z)
	var q0 := Vector2((c[1] as Vector3).x, (c[1] as Vector3).z)
	var q1 := Vector2((c[2] as Vector3).x, (c[2] as Vector3).z)
	var hit: Variant = Geometry2D.segment_intersects_segment(a, b, q0, q1)
	if hit == null:
		return -1.0
	var span := b.distance_to(a)
	if span < 1e-6:
		return -1.0
	var f := (hit as Vector2).distance_to(a) / span
	if f <= 1e-3 or f >= 1.0 - 1e-3:
		return -1.0
	return d0 + (d1 - d0) * f


func _dash_station_height(seg: int, p: Vector3, side: Vector3) -> float:
	# One height for both corners of a dash end at centre-line point p: the
	# asphalt under p, nudged up (by at most a few cm, never tilting the dash)
	# if the asphalt under either corner — its own quad's or a nearby
	# segment's overlapping at a tight bend — sits slightly higher.
	const MAX_NUDGE := 0.06
	var h := _centreline_asphalt_height(seg, p)
	var top := h
	for corner in [p - side, p + side]:
		for sg in range(seg - 2, seg + 3):
			if sg < 0 or sg >= _course_path.size() - 1:
				continue
			var c := _asphalt_corners(sg, 2.0)
			for tri in [
				_tri_plane(c[0], c[2], c[1], corner.x, corner.z),
				_tri_plane(c[1], c[2], c[3], corner.x, corner.z),
			]:
				var t: float = tri[1]
				if tri[0] > 0.5 and t > top and t - h <= MAX_NUDGE:
					top = t
	return top


func _centreline_asphalt_height(seg: int, p: Vector3) -> float:
	# Height (without lift) of segment seg's asphalt at the centre-line point
	# p (which lies on the path, so inside the segment's quad for any normal
	# bend). A folded quad at a hairpin can leave p outside both triangles —
	# then the path's own elevation is the honest answer.
	var c := _asphalt_corners(seg, 2.0)
	var t1 := _tri_plane(c[0], c[2], c[1], p.x, p.z)
	if t1[0] > 0.5:
		return t1[1]
	var t2 := _tri_plane(c[1], c[2], c[3], p.x, p.z)
	if t2[0] > 0.5:
		return t2[1]
	return p.y


func _tri_plane(p0: Vector3, p1: Vector3, p2: Vector3, x: float, z: float) -> Array:
	# [inside (1/0), plane height] of triangle p0,p1,p2 at world (x, z).
	var den := (p1.z - p2.z) * (p0.x - p2.x) + (p2.x - p1.x) * (p0.z - p2.z)
	if absf(den) < 1e-12:
		return [0.0, -INF]
	var w0 := ((p1.z - p2.z) * (x - p2.x) + (p2.x - p1.x) * (z - p2.z)) / den
	var w1 := ((p2.z - p0.z) * (x - p2.x) + (p0.x - p2.x) * (z - p2.z)) / den
	var w2 := 1.0 - w0 - w1
	var inside := 1.0 if (w0 >= -1e-6 and w1 >= -1e-6 and w2 >= -1e-6) else 0.0
	return [inside, w0 * p0.y + w1 * p1.y + w2 * p2.y]


func _path_point(i: int) -> Vector3:
	var p: Dictionary = _course_path[i]
	return Vector3(float(p["x_m"]), float(p["elevation_m"]), -float(p["y_m"]))


func _clamp_point(x: float, z: float, target: float, lower: PackedFloat32Array) -> void:
	var tri := _strip_triangle(x, z)
	if tri.is_empty():
		return
	var y: float = (
		_strip_heights[tri[0]] * tri[3]
		+ _strip_heights[tri[1]] * tri[4]
		+ _strip_heights[tri[2]] * tri[5]
	)
	var excess := y - target
	if excess <= 0.0:
		return
	# Corners with (near-)zero weight don't hold the point up — leave them.
	for k in 3:
		if float(tri[3 + k]) > 1e-4:
			var vi: int = tri[k]
			lower[vi] = maxf(lower[vi], excess)


func _clamp_line(p0: Vector3, p1: Vector3, drop_m: float, lower: PackedFloat32Array) -> void:
	# Check both ends and every crossing with a grid line (x, y and the
	# cell diagonals) along the straight road line p0→p1; y is road height.
	var f0 := Vector2((p0.x - _strip_min_x) / _strip_g, (-p0.z - _strip_min_y) / _strip_g)
	var f1 := Vector2((p1.x - _strip_min_x) / _strip_g, (-p1.z - _strip_min_y) / _strip_g)
	var ts: Array[float] = [0.0, 1.0]
	_line_crossings(f0.x, f1.x, ts)
	_line_crossings(f0.y, f1.y, ts)
	_line_crossings(f0.x + f0.y, f1.x + f1.y, ts)
	for t in ts:
		var q := p0.lerp(p1, t)
		_clamp_point(q.x, q.z, q.y - drop_m, lower)


func _line_crossings(v0: float, v1: float, ts: Array[float]) -> void:
	# Parameters t in (0, 1) where v0 + (v1 - v0)·t hits a whole number.
	if absf(v1 - v0) < 1e-9:
		return
	var lo := minf(v0, v1)
	var hi := maxf(v0, v1)
	for k in range(int(ceil(lo)), int(floor(hi)) + 1):
		var t := (float(k) - v0) / (v1 - v0)
		if t > 0.0 and t < 1.0:
			ts.append(t)


func _clamp_triangle_vertices(
	p0: Vector3, p1: Vector3, p2: Vector3, drop_m: float, lower: PackedFloat32Array,
) -> void:
	# Grid vertices lying inside the road triangle p0,p1,p2 (y = road height):
	# the ground there IS the vertex, so lower it by its own excess.
	var q0 := Vector2(p0.x, -p0.z)
	var q1 := Vector2(p1.x, -p1.z)
	var q2 := Vector2(p2.x, -p2.z)
	var den := (q1.y - q2.y) * (q0.x - q2.x) + (q2.x - q1.x) * (q0.y - q2.y)
	if absf(den) < 1e-9:
		return  # degenerate (zero-area) triangle
	var ix0 := maxi(int(ceil((minf(q0.x, minf(q1.x, q2.x)) - _strip_min_x) / _strip_g)), 0)
	var ix1 := mini(int(floor((maxf(q0.x, maxf(q1.x, q2.x)) - _strip_min_x) / _strip_g)), _strip_w - 1)
	var iy0 := maxi(int(ceil((minf(q0.y, minf(q1.y, q2.y)) - _strip_min_y) / _strip_g)), 0)
	var iy1 := mini(int(floor((maxf(q0.y, maxf(q1.y, q2.y)) - _strip_min_y) / _strip_g)), _strip_h - 1)
	for iy in range(iy0, iy1 + 1):
		for ix in range(ix0, ix1 + 1):
			var vx := _strip_min_x + float(ix) * _strip_g
			var vy := _strip_min_y + float(iy) * _strip_g
			var w0 := ((q1.y - q2.y) * (vx - q2.x) + (q2.x - q1.x) * (vy - q2.y)) / den
			var w1 := ((q2.y - q0.y) * (vx - q2.x) + (q0.x - q2.x) * (vy - q2.y)) / den
			var w2 := 1.0 - w0 - w1
			if w0 < -1e-6 or w1 < -1e-6 or w2 < -1e-6:
				continue
			var idx := iy * _strip_w + ix
			var road_y := w0 * p0.y + w1 * p1.y + w2 * p2.y
			var excess := _strip_heights[idx] - (road_y - drop_m)
			if excess > 0.0:
				lower[idx] = maxf(lower[idx], excess)


func _add_ground_skirt(
	st: SurfaceTool, min_x: float, min_y: float, g: float, w: int, h: int
) -> void:
	# Flat y = 0 skirt from the strip grid's border out to the horizon,
	# replacing the flat backdrop plane. Every grid border vertex is at least
	# the strip's reach from the path, so it's at exactly y = 0; each skirt
	# quad reuses the border's own vertex coordinates (same float expressions
	# as the grid), so the seam is watertight — no T-junction cracks. Winding
	# matches the grid cells (x up the columns, path-y up the rows) → +Y fronts.
	const HORIZON_M := 6000.0  # the old plane's half-size
	const MIN_BEYOND_M := 2000.0  # rider-locked backdrop needs ground past the course
	var gx1 := min_x + float(w - 1) * g
	var gy1 := min_y + float(h - 1) * g
	var ox0 := minf(-HORIZON_M, min_x - MIN_BEYOND_M)
	var ox1 := maxf(HORIZON_M, gx1 + MIN_BEYOND_M)
	var oy0 := minf(-HORIZON_M, min_y - MIN_BEYOND_M)
	var oy1 := maxf(HORIZON_M, gy1 + MIN_BEYOND_M)
	# West + east skirts: one quad per grid row segment.
	for iy in range(h - 1):
		var ya := min_y + float(iy) * g
		var yb := min_y + float(iy + 1) * g
		_skirt_quad(st, ox0, min_x, ya, yb)
		_skirt_quad(st, gx1, ox1, ya, yb)
	# South + north skirts: one quad per grid column segment.
	for ix in range(w - 1):
		var xa := min_x + float(ix) * g
		var xb := min_x + float(ix + 1) * g
		_skirt_quad(st, xa, xb, oy0, min_y)
		_skirt_quad(st, xa, xb, gy1, oy1)
	# Four corners.
	_skirt_quad(st, ox0, min_x, oy0, min_y)
	_skirt_quad(st, gx1, ox1, oy0, min_y)
	_skirt_quad(st, ox0, min_x, gy1, oy1)
	_skirt_quad(st, gx1, ox1, gy1, oy1)


func _skirt_quad(st: SurfaceTool, xa: float, xb: float, ya: float, yb: float) -> void:
	# Path-frame rectangle [xa,xb]×[ya,yb] at y = 0 (world z = -path y),
	# emitted in the same corner order as a strip grid cell.
	var v00 := Vector3(xa, 0.0, -ya)
	var v10 := Vector3(xb, 0.0, -ya)
	var v01 := Vector3(xa, 0.0, -yb)
	var v11 := Vector3(xb, 0.0, -yb)
	st.add_vertex(v00); st.add_vertex(v01); st.add_vertex(v10)
	st.add_vertex(v10); st.add_vertex(v01); st.add_vertex(v11)


func _ground_material() -> ShaderMaterial:
	# Shared between the ground strip and the heightmap terrain so colors
	# match exactly where they meet (both sample world-space noise).
	if _ground_shader_material == null:
		_ground_shader_material = TerrainMaterial.build()
	return _ground_shader_material


func _compute_course_path() -> void:
	_course_path = []
	_path_dists = PackedFloat64Array()  # rebuilt lazily by _find_path_segment
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
	# Same invariant as GPX paths: the lowest point sits at y = 0 (a profile
	# that descends from its start would otherwise run below the y = 0 skirt).
	var synth_min := INF
	for p in _course_path:
		synth_min = minf(synth_min, float(p["elevation_m"]))
	for p in _course_path:
		p["elevation_m"] = float(p["elevation_m"]) - synth_min


func _find_path_segment(d: float) -> int:
	# Returns index i such that path[i].distance_m <= d <= path[i+1].distance_m
	# (the first such i; clamped to the ends). Binary search over a cached
	# distance array — user GPX routes run to thousands of points.
	var n := _course_path.size()
	if n < 2:
		return 0
	if _path_dists.size() != n:
		_path_dists = PackedFloat64Array()
		_path_dists.resize(n)
		for i in n:
			_path_dists[i] = float(_course_path[i]["distance_m"])
	return clampi(_path_dists.bsearch(d, true) - 1, 0, n - 2)


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
		# Two triangles forming the quad, wound clockwise-from-camera so
		# generate_normals() gives +Y (Godot's front-face convention) and
		# the sun lights the asphalt instead of just ambient.
		asphalt.set_uv(Vector2(0.0, v0)); asphalt.add_vertex(left0)
		asphalt.set_uv(Vector2(0.0, v1)); asphalt.add_vertex(left1)
		asphalt.set_uv(Vector2(1.0, v0)); asphalt.add_vertex(right0)
		asphalt.set_uv(Vector2(1.0, v0)); asphalt.add_vertex(right0)
		asphalt.set_uv(Vector2(0.0, v1)); asphalt.add_vertex(left1)
		asphalt.set_uv(Vector2(1.0, v1)); asphalt.add_vertex(right1)
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
	var dash_lift := Vector3(0, 0.07, 0)
	var total_len: float = float(current_course.get("length_m", 0.0))
	if total_len <= 0.0 and _course_path.size() > 0:
		total_len = float(_course_path[-1]["distance_m"])
	var num_dashes := int(total_len / DASH_PERIOD)
	# Each dash lies ON the road: it's split at every waypoint it spans and
	# where it crosses its segment's asphalt diagonal (so each piece sits on
	# one flat asphalt triangle), and each end takes the height of the asphalt
	# under the centre line there + the dash lift — the same height for both
	# of its corners, since the road has no cross-slope. (A single flat 3 m
	# quad buried its uphill end on anything steeper than ~1.3 %; the
	# asphalt's bend-mitred triangles also bow away from the straight-line
	# profile on steep sharp bends.)
	_find_path_segment(0.0)  # make sure _path_dists is cached
	var dash_above := dash_lift.y - lift.y  # height over the asphalt surface
	for i in num_dashes:
		var d_start: float = float(i) * DASH_PERIOD
		var d_end: float = d_start + DASH_LENGTH
		var stations: Array[float] = [d_start]
		var j := _path_dists.bsearch(d_start, false)  # first waypoint > d_start
		while j < _path_dists.size() and _path_dists[j] < d_end:
			stations.append(_path_dists[j])
			j += 1
		stations.append(d_end)
		# Also split where a piece crosses its segment's asphalt diagonal: a
		# bent segment's two triangles meet there in a slight crease, and a
		# flat piece spanning it would dip under the ridge.
		var creased: Array[float] = []
		for k in stations.size() - 1:
			creased.append(stations[k])
			var dm := (stations[k] + stations[k + 1]) * 0.5
			var sg := _find_path_segment(_wrap_distance(dm))
			var t := _diagonal_crossing(sg, stations[k], stations[k + 1])
			if t > 0.0:
				creased.append(t)
		creased.append(d_end)
		stations = creased
		for k in stations.size() - 1:
			var d0: float = stations[k]
			var d1: float = stations[k + 1]
			if d1 - d0 < 1e-4:
				continue
			var c0 := _position_at_distance(d0)
			var c1 := _position_at_distance(d1)
			var along := Vector2(c1.x - c0.x, c1.z - c0.z)
			if along.length() < 1e-5:
				continue
			along = along.normalized()
			var right := Vector3(-along.y, 0.0, along.x)
			var seg := _find_path_segment(_wrap_distance((d0 + d1) * 0.5))
			var side := right * dash_half_w
			var y0 := _dash_station_height(seg, c0, side) + lift.y + dash_above
			var y1 := _dash_station_height(seg, c1, side) + lift.y + dash_above
			var bl := c0 - right * dash_half_w
			var br := c0 + right * dash_half_w
			var fl := c1 - right * dash_half_w
			var fr := c1 + right * dash_half_w
			bl.y = y0
			br.y = y0
			fl.y = y1
			fr.y = y1
			# Clockwise-from-camera so the dash surface normal points +Y.
			dashes.add_vertex(bl)
			dashes.add_vertex(fl)
			dashes.add_vertex(br)
			dashes.add_vertex(br)
			dashes.add_vertex(fl)
			dashes.add_vertex(fr)
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
			# Stand on the ground drawn under the post (below the road bed)
			# and stretch so the top stays `height` above the road surface.
			var base: Vector3 = center + right * (float(side) * SIDE_OFFSET)
			# Capped: where the ground falls away steeply a post stops 3 m down
			# rather than turning into a long white rod down the embankment.
			var ground_y := clampf(
				_ground_height_at(base.x, base.z), center.y - 3.0, center.y
			)
			var span := height + (center.y - ground_y)
			post.scale = Vector3(1.0, span / height, 1.0)
			post.global_position = Vector3(base.x, ground_y + span * 0.5, base.z)


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

	# Collect placements per variety, then build one MultiMesh per variety
	# (instance_count must be known up front).
	var placements: Array = [[], [], [], []]
	var placed := 0
	var attempts := 0
	while placed < tree_count and attempts < tree_count * 8:
		attempts += 1
		var x := rng.randf_range(min_x, max_x)
		var z := rng.randf_range(min_z, max_z)
		# Off the road — checked against the densified road, not just the
		# waypoints (a sparse path is one long segment between two points).
		if _near_road(x, z, MIN_DIST_TO_ROAD):
			continue
		# Plant on the ground actually drawn here (terrain or strip).
		var ground_y := _ground_height_at(x, z)
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
	# Lean on poplars — the tall roadside rows of the French countryside.
	var roll := rng.randf()
	if roll < 0.50:
		return SceneryFactory.Variety.POPLAR
	if roll < 0.74:
		return SceneryFactory.Variety.OAK
	if roll < 0.88:
		return SceneryFactory.Variety.PINE
	return SceneryFactory.Variety.BUSH


func _tree_scale(rng: RandomNumberGenerator, variety: int) -> float:
	match variety:
		SceneryFactory.Variety.PINE: return rng.randf_range(0.8, 1.6)
		SceneryFactory.Variety.OAK: return rng.randf_range(0.7, 1.3)
		SceneryFactory.Variety.POPLAR: return rng.randf_range(0.9, 1.5)
		_: return rng.randf_range(0.7, 1.1)


func _tree_foliage_color(rng: RandomNumberGenerator, variety: int) -> Color:
	# Dusty olive/sage/bronze foliage, slightly varied per tree, so the forest
	# sits in the muted palette instead of vivid green.
	var base: Color
	match variety:
		SceneryFactory.Variety.PINE:
			base = Belleville.TEAL.lerp(Belleville.OLIVE, 0.5)
		SceneryFactory.Variety.POPLAR:
			base = Belleville.OLIVE.lerp(Belleville.BRONZE, 0.35)
		_:
			base = Belleville.OLIVE
	return base.lerp(Belleville.SAGE, rng.randf_range(0.0, 0.3)).darkened(rng.randf_range(0.0, 0.12))


func _setup_belleville_dressing() -> void:
	# Period set-dressing for the Belleville theme: telegraph poles marching
	# along the right shoulder, and a clump of tall leaning towers hazed into
	# the horizon. Rebuilt wholesale (free + recreate) so terrain arrival can
	# reseat the poles on the real ground height.
	if _belleville_dressing != null:
		_belleville_dressing.queue_free()
		_belleville_dressing = null
	if _course_path.size() < 2:
		return

	var root := Node3D.new()
	root.name = "BellevilleDressing"
	add_child(root)
	_belleville_dressing = root

	const POLE_SPACING_M := 50.0
	const POLE_SIDE_OFFSET_M := 9.0
	const MAX_POLES := 200
	var total: float = float(_course_path[_course_path.size() - 1]["distance_m"])
	# Stretch the spacing on long courses so ~MAX_POLES poles span the WHOLE
	# route rather than truncating after the first 10 km. On short courses the
	# first pole is pulled in to half-length so even a sub-50 m loop gets one.
	var spacing := maxf(POLE_SPACING_M, total / float(MAX_POLES))
	var xforms: Array = []
	var d := minf(spacing, total * 0.5)
	while d < total:
		var center := _position_at_distance(d)
		var tng := _tangent_at_distance(d)
		var right := Vector3(-tng.z, 0.0, tng.x)
		var pos := center + right * POLE_SIDE_OFFSET_M
		# Base sits on the ground actually drawn there (terrain or strip).
		pos.y = _ground_height_at(pos.x, pos.z)
		var yaw := atan2(tng.x, tng.z)
		xforms.append(Transform3D(Basis(Vector3.UP, yaw), pos))
		d += spacing

	if not xforms.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _build_pole_mesh()
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = mm
		root.add_child(inst)


# --- Towns ------------------------------------------------------------------

const TOWN_SEED := 0xBE11E711
const TOWN_MIN_ROAD_CLEAR_M := 7.5  # a building never straddles the road
const TOWN_MIN_SPACING_M := 9.0     # between building origins


func _setup_towns() -> void:
	# Villages along the route: a town around the start/finish line, a hamlet
	# or two mid-course, and lone farmsteads in between. Deterministic seed so
	# every rider sees the same world; one MultiMesh per building variety.
	if _towns != null:
		_towns.queue_free()
		_towns = null
	if _course_path.size() < 2:
		return
	var total: float = float(_course_path[_course_path.size() - 1]["distance_m"])
	if total < 200.0:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = TOWN_SEED
	var density: float = GraphicsSettings.town_building_scale()

	# Plan first, place after: entries {d, side, offset, variety, tint}.
	var plan: Array = []
	_town_centers_d = [0.0]  # the crowd murmur follows these
	_plan_settlement(
		plan, rng, 0.0, minf(140.0, total * 0.2), int(round(14.0 * density)), true
	)
	if total > 1500.0:
		var hamlet1: float = total * rng.randf_range(0.36, 0.5)
		var hamlet2: float = total * rng.randf_range(0.64, 0.8)
		_town_centers_d.append(hamlet1)
		_town_centers_d.append(hamlet2)
		_plan_settlement(plan, rng, hamlet1, 60.0, int(round(6.0 * density)), false)
		_plan_settlement(plan, rng, hamlet2, 60.0, int(round(6.0 * density)), false)
	for _i in int(round(4.0 * density)):
		_plan_farmstead(plan, rng, total * rng.randf_range(0.08, 0.92))

	var by_variety: Array = []
	for _v in BuildingFactory.VARIETY_COUNT:
		by_variety.append([])
	var placed_xz: Array = []
	for entry in plan:
		var d: float = _wrap_distance(entry["d"])
		var center := _position_at_distance(d)
		var tng := _tangent_at_distance(d)
		var right := Vector3(-tng.z, 0.0, tng.x)
		var side: float = entry["side"]
		var pos := center + right * (float(entry["offset"]) * side)
		if not _town_spot_clear(pos, placed_xz):
			continue
		pos.y = _ground_height_at(pos.x, pos.z) - 0.15  # settle into sloped ground
		# The authored front (+X) faces the road, with a hand-drawn wobble:
		# yaw jitter plus the signature Belleville lean.
		var face := (-right * side).normalized()
		var yaw := atan2(-face.z, face.x) + rng.randf_range(-0.09, 0.09)
		var lean := Vector3(
			rng.randf_range(-0.025, 0.025), yaw, rng.randf_range(-0.025, 0.025)
		)
		var basis := Basis.from_euler(lean).scaled(
			Vector3.ONE * rng.randf_range(0.92, 1.12)
		)
		by_variety[entry["variety"]].append([Transform3D(basis, pos), entry["tint"]])
		placed_xz.append(Vector2(pos.x, pos.z))

	var root := Node3D.new()
	root.name = "Towns"
	add_child(root)
	_towns = root
	for v in BuildingFactory.VARIETY_COUNT:
		var entries: Array = by_variety[v]
		if entries.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true  # facade tint; roofs/trim have fixed materials
		mm.mesh = BuildingFactory.variety_mesh(v)
		mm.instance_count = entries.size()
		for i in entries.size():
			mm.set_instance_transform(i, entries[i][0])
			mm.set_instance_color(i, entries[i][1])
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = mm
		root.add_child(inst)


func _plan_settlement(
	plan: Array,
	rng: RandomNumberGenerator,
	center_d: float,
	window_m: float,
	count: int,
	is_town: bool,
) -> void:
	if count <= 0:
		return
	if is_town:
		# Every proper town gets its church, set back from the road.
		plan.append({
			"d": center_d + rng.randf_range(-window_m * 0.4, window_m * 0.4),
			"side": -1.0 if rng.randf() < 0.5 else 1.0,
			"offset": rng.randf_range(12.0, 15.0),
			"variety": BuildingFactory.Variety.CHURCH,
			"tint": Belleville.PAPER_LIGHT.darkened(rng.randf_range(0.0, 0.06)),
		})
	for _i in count:
		var variety := _pick_settlement_variety(rng, is_town)
		plan.append({
			"d": center_d + rng.randf_range(-window_m, window_m),
			"side": -1.0 if rng.randf() < 0.5 else 1.0,
			"offset": rng.randf_range(8.5, 13.0),
			"variety": variety,
			"tint": _building_tint(rng, variety),
		})


func _plan_farmstead(plan: Array, rng: RandomNumberGenerator, d: float) -> void:
	# A farmhouse set well back from the road, usually with its barn.
	var side := -1.0 if rng.randf() < 0.5 else 1.0
	plan.append({
		"d": d,
		"side": side,
		"offset": rng.randf_range(16.0, 26.0),
		"variety": BuildingFactory.Variety.FARMHOUSE,
		"tint": _building_tint(rng, BuildingFactory.Variety.FARMHOUSE),
	})
	if rng.randf() < 0.7:
		plan.append({
			"d": d + rng.randf_range(10.0, 18.0),
			"side": side,
			"offset": rng.randf_range(18.0, 30.0),
			"variety": BuildingFactory.Variety.BARN,
			"tint": _building_tint(rng, BuildingFactory.Variety.BARN),
		})


func _pick_settlement_variety(rng: RandomNumberGenerator, is_town: bool) -> int:
	var roll := rng.randf()
	if is_town:
		if roll < 0.45:
			return BuildingFactory.Variety.TOWNHOUSE
		if roll < 0.85:
			return BuildingFactory.Variety.COTTAGE
		return BuildingFactory.Variety.FARMHOUSE
	if roll < 0.5:
		return BuildingFactory.Variety.COTTAGE
	if roll < 0.8:
		return BuildingFactory.Variety.FARMHOUSE
	return BuildingFactory.Variety.BARN


func _building_tint(rng: RandomNumberGenerator, variety: int) -> Color:
	# Facade colors (walls surface only — roofs/windows have fixed materials).
	if variety == BuildingFactory.Variety.BARN:
		return Belleville.UMBER.lerp(Belleville.TERRACOTTA, 0.3).darkened(
			rng.randf_range(0.0, 0.12)
		)
	var facades: Array = [
		Belleville.PAPER,
		Belleville.PAPER_LIGHT,
		Belleville.OCHRE.lerp(Belleville.PAPER, 0.3),
		Belleville.TERRACOTTA.lerp(Belleville.PAPER, 0.45),
		Belleville.SAGE.lerp(Belleville.PAPER, 0.5),
	]
	var pick: Color = facades[rng.randi_range(0, facades.size() - 1)]
	return pick.darkened(rng.randf_range(0.0, 0.1))


func _town_proximity() -> float:
	# 0 = open country, 1 = village centre; circular distance on loops.
	if _town_centers_d.is_empty() or current_course.is_empty():
		return 0.0
	var total := float(current_course.get("length_m", 0.0))
	if total <= 0.0:
		return 0.0
	var d := fposmod(distance_m, total)
	var best := INF
	for c in _town_centers_d:
		var delta: float = absf(d - float(c))
		best = minf(best, minf(delta, total - delta))
	return 1.0 - clampf(best / 140.0, 0.0, 1.0)


func _town_spot_clear(pos: Vector3, placed_xz: Array) -> bool:
	# Off the road, with a wider margin than trees for building footprints (a
	# switchback can bring another part of the course close behind a plot).
	if _near_road(pos.x, pos.z, TOWN_MIN_ROAD_CLEAR_M):
		return false
	var min_sp_sq := TOWN_MIN_SPACING_M * TOWN_MIN_SPACING_M
	for q in placed_xz:
		var ddx: float = q.x - pos.x
		var ddz: float = q.y - pos.z
		if ddx * ddx + ddz * ddz < min_sp_sq:
			return false
	return true


func _setup_backdrop() -> void:
	# The distant mountains + leaning city are built ONCE around the origin and
	# then tracked to the rider every physics tick (see _physics_process), so
	# the horizon is always populated regardless of where on the course the
	# rider is. Independent of terrain, so it isn't rebuilt on terrain arrival.
	if _backdrop != null:
		return
	_backdrop = Node3D.new()
	_backdrop.name = "BellevilleBackdrop"
	add_child(_backdrop)
	_add_belleville_mountains(_backdrop)
	_add_belleville_skyline(_backdrop)


func _add_belleville_mountains(root: Node3D) -> void:
	# Faceted distant peaks ringing the rider in two depth bands — a far,
	# darker, hazier range and a nearer, lighter one — so the horizon reads
	# with depth (the teal mountains of the mood board). One MultiMesh of a
	# low-poly cone, per-instance scaled/leaned/tinted, placed around the
	# backdrop origin (which tracks the rider). They sit far beyond the shadow
	# range, so they cast nothing and the distance fog dissolves their bases.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xA17175

	# Unit cone with few radial segments → an angular, faceted peak.
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.5
	cone.height = 1.0
	cone.radial_segments = 4  # sharp, faceted triangular peaks
	cone.rings = 1
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.vertex_color_use_as_albedo = true  # per-instance tint for depth banding
	mat.roughness = 1.0
	cone.material = mat

	var xforms: Array = []
	var colors: Array = []
	var col_data: Array = []
	# Two bands (radius/height/width ranges, count, base tint). The far band is
	# only lightly darkened so the distance fog hazes it toward the sky; the
	# near band is darker for crisp, saturated teal in front of it.
	var bands := [
		{
			"r0": 780.0, "r1": 1180.0, "h0": 180.0, "h1": 340.0,
			"w0": 180.0, "w1": 320.0, "n": 18, "tint": Belleville.TEAL.darkened(0.05),
		},
		{
			"r0": 430.0, "r1": 720.0, "h0": 95.0, "h1": 190.0,
			"w0": 120.0, "w1": 220.0, "n": 13, "tint": Belleville.TEAL.darkened(0.22),
		},
	]
	for band in bands:
		var n: int = int(band["n"])
		var tint: Color = band["tint"]
		for i in n:
			# Even angular spread around the course, with jitter so it's not a
			# perfect ring.
			var ang := (float(i) / float(n)) * TAU + rng.randf_range(-0.12, 0.12)
			var r := rng.randf_range(band["r0"], band["r1"])
			var px := sin(ang) * r
			var pz := cos(ang) * r
			var h := rng.randf_range(band["h0"], band["h1"])
			var w := rng.randf_range(band["w0"], band["w1"])
			var yaw := rng.randf_range(0.0, TAU)
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(w, h, w))
			col_data.append([px, pz, yaw, w])
			# Base ~20 m below the rider (the backdrop origin tracks the rider)
			# so peaks rise from the horizon; cone is centre-origin, so lift by
			# half its height.
			xforms.append(Transform3D(basis, Vector3(px, -20.0 + h * 0.5, pz)))
			colors.append(tint.darkened(rng.randf_range(0.0, 0.1)))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = cone
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colors[i])
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	root.add_child(inst)

	# Straight-sided columns under each cone (same footprint and facets),
	# stretched down to the ground by _update_backdrop_depth. Hidden while the
	# rider is at ground level, where the cone bases already sit underground.
	var shaft := CylinderMesh.new()
	shaft.top_radius = 0.5
	shaft.bottom_radius = 0.5
	shaft.height = 1.0
	shaft.radial_segments = 4
	shaft.rings = 1
	shaft.cap_top = false
	shaft.cap_bottom = false
	shaft.material = mat
	var cols := MultiMesh.new()
	cols.transform_format = MultiMesh.TRANSFORM_3D
	cols.use_colors = true
	cols.mesh = shaft
	cols.instance_count = xforms.size()
	cols.visible_instance_count = 0
	for i in xforms.size():
		cols.set_instance_color(i, colors[i])
	var cols_inst := MultiMeshInstance3D.new()
	cols_inst.multimesh = cols
	root.add_child(cols_inst)
	_backdrop_columns = cols
	_backdrop_col_data = col_data


func _build_pole_mesh() -> ArrayMesh:
	# A wooden telegraph pole with two crossarms, base at y = 0.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pole := BoxMesh.new()
	pole.size = Vector3(0.16, 6.0, 0.16)
	st.append_from(pole, 0, Transform3D(Basis(), Vector3(0, 3.0, 0)))
	var arm1 := BoxMesh.new()
	arm1.size = Vector3(1.5, 0.12, 0.12)
	st.append_from(arm1, 0, Transform3D(Basis(), Vector3(0, 5.5, 0)))
	var arm2 := BoxMesh.new()
	arm2.size = Vector3(1.1, 0.12, 0.12)
	st.append_from(arm2, 0, Transform3D(Basis(), Vector3(0, 5.0, 0)))
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	var m := StandardMaterial3D.new()
	m.albedo_color = Belleville.UMBER.darkened(0.1)
	m.roughness = 1.0
	mesh.surface_set_material(0, m)
	return mesh


func _add_belleville_skyline(root: Node3D) -> void:
	# A distant clump of tall, slightly-leaning Art-Deco towers — a silhouette
	# backdrop hazed into the fog, evoking the film's looming Belleville city.
	# Placed in one fixed direction from the backdrop origin (which tracks the
	# rider), so the city sits at a steady bearing on the horizon throughout.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EA51DE
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Belleville.TEAL.darkened(0.12)
	mat.roughness = 1.0

	var clump := Vector3(0.62, 0.0, -0.78).normalized() * 480.0  # off toward the light

	# One MultiMesh (one draw call) of a unit cube, scaled/leaned per instance —
	# matches the pole path and keeps the backdrop to a single batch.
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE
	unit.material = mat
	const TOWERS := 12
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = unit
	mm.instance_count = TOWERS
	for i in TOWERS:
		var off := Vector3(rng.randf_range(-130.0, 130.0), 0.0, rng.randf_range(-130.0, 130.0))
		var h := rng.randf_range(45.0, 115.0)
		var wdt := rng.randf_range(12.0, 26.0)
		var base := clump + off
		var rot := Basis.from_euler(Vector3(
			deg_to_rad(rng.randf_range(-4.0, 4.0)),
			deg_to_rad(rng.randf_range(0.0, 360.0)),
			deg_to_rad(rng.randf_range(-4.0, 4.0)),
		))
		var lean := rot.scaled(Vector3(wdt, h, wdt))
		# Base a touch underground so towers rise straight out of the horizon.
		var center := Vector3(base.x, h * 0.5 - 6.0, base.z)
		mm.set_instance_transform(i, Transform3D(lean, center))
		_backdrop_tower_data.append([lean, center + lean.y * 0.5])
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	root.add_child(inst)
	_backdrop_towers = mm


func _update_backdrop_depth(depth: float) -> void:
	# Stretch the backdrop down by `depth` metres (the rider's height above the
	# y = 0 ground) so nothing hovers: tower shafts lengthen with their tops
	# fixed, and a column fills in under each mountain from its cone base
	# (20 m under the rider) to 20 m under the ground. The silhouette above
	# the old bases is untouched, and nothing widens toward the road.
	if absf(depth - _backdrop_depth) < 0.25:
		return
	_backdrop_depth = depth
	if _backdrop_columns != null:
		if depth < 0.25:
			_backdrop_columns.visible_instance_count = 0
		else:
			for i in _backdrop_col_data.size():
				var c: Array = _backdrop_col_data[i]
				var basis := Basis(Vector3.UP, float(c[2])).scaled(
					Vector3(float(c[3]), depth, float(c[3]))
				)
				_backdrop_columns.set_instance_transform(
					i, Transform3D(basis, Vector3(float(c[0]), -20.0 - depth * 0.5, float(c[1])))
				)
			_backdrop_columns.visible_instance_count = _backdrop_col_data.size()
	if _backdrop_towers != null:
		for i in _backdrop_tower_data.size():
			var t: Array = _backdrop_tower_data[i]
			var rest: Basis = t[0]
			var top: Vector3 = t[1]
			# Lengthen only the shaft axis: the roof, footprint and lean stay
			# exactly as built (a basis-wide rescale is a world-axis scale in
			# Godot 4 and sheared the roofs into morphing wedges).
			var rise := rest.y.y  # vertical extent of the (slightly leaning) shaft
			var stretch := (rise + depth) / rise
			var b := Basis(rest.x, rest.y * stretch, rest.z)
			_backdrop_towers.set_instance_transform(i, Transform3D(b, top - b.y * 0.5))


func _setup_sun() -> void:
	# Mid-morning sun: high enough to throw long-but-not-flat shadows along
	# the road, off-axis enough that climbing turns face into and away from
	# light so the heightmap mesh reads as three-dimensional.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	# A low hazy sun — warm, soft, a little dim — so the scene reads flat and
	# illustrated rather than crisply lit.
	sun.light_energy = 1.1
	sun.light_color = Belleville.OCHRE.lerp(Color.WHITE, 0.4)
	sun.shadow_opacity = 0.7

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
	sun.shadow_blur = 2.0  # soft, hazy shadows to match the illustrated look

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
	# Multi-view rig parented to the rider node, so every preset is defined in
	# the rider's local frame and follows position + heading. Switch with C/V
	# (cycle) or number keys 1–9 (direct), handled in _input. Seed the view the
	# player last used this session (set_initial_view before add_child so the
	# rig's _ready snaps to it without an ease-in from Chase).
	camera_rig = CameraRig.new()
	camera_rig.set_initial_view(GameSession.camera_view_index)
	rider_node.add_child(camera_rig)


func _setup_hud() -> void:
	hud = HUD_SCENE.instantiate()
	add_child(hud)
	# On-screen touch taps (phones): mirror the T / C / Esc keys.
	hud.touch_turn.connect(_on_touch_turn)
	hud.touch_camera.connect(_on_touch_camera)
	hud.touch_finish.connect(_on_touch_finish_tap)
	ride_audio = RideAudio.new()
	add_child(ride_audio)
	# Announce the starting view so the camera feature advertises itself (and
	# confirms a restored preference) instead of staying silent until the
	# player happens to press a camera key.
	if camera_rig != null:
		hud.show_camera(camera_rig.current_name())


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
		_on_start_failed()
		return
	current_ride_id = str(ride["id"])
	_open_local_jsonl()

	_setup_cp_limiter({})  # solo: your own curve, no race limits
	target_power_w = STARTING_POWER_W
	is_riding = true
	is_racing = true  # solo starts racing immediately
	_is_solo_ride = true
	_game_speed = GraphicsSettings.game_speed
	if _game_speed > 1.0 and _speed_allowed():
		hud.show_toast("⏩ Game speed %s" % _speed_label())
	hud.set_status("Go!")
	ride_audio.go()
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
		_on_start_failed()
		return
	current_ride_id = str(ride["id"])
	_open_local_jsonl()
	# Re-open the WS connection so it carries the new ride_id for the
	# server-side finish-on-disconnect path. Lobby opened it without one.
	WorldClient.connect_to_game(GameSession.code, rider_id, current_ride_id)

	_setup_cp_limiter(GameSession.limits)
	target_power_w = STARTING_POWER_W
	is_riding = true
	is_racing = false  # held in the pen until race_started
	if GameSession.state == "RACING":
		# Late entry / rejoin: the gun fired before we connected, so no
		# race_started broadcast is coming — release the pen immediately.
		is_racing = true
	_is_solo_ride = false
	# Host-set race time-scale. Applied to keyboard (virtual) riders only — if
	# this rider is on a power meter / trainer they race at real time (see
	# _speed_allowed), so a measured effort is never distorted. Every client
	# read the same game_speed off the game detail, so all virtual riders stay
	# in sync.
	_game_speed = GameSession.game_speed
	if _game_speed > 1.0:
		if _speed_allowed():
			hud.show_toast("⏩ Virtual race · game speed %s" % _speed_label())
		elif SensorBridge.using_sensor():
			hud.show_toast("%s virtual race — your sensor stays at real time" % _speed_label())
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
	ride_audio.go()
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


func _on_start_failed() -> void:
	if not ApiClient.is_authenticated():
		# The login was ended elsewhere; the menu explains why.
		hud.set_status("Signed out — returning to the menu…")
		await get_tree().create_timer(2.5).timeout
		_back_to_menu()
		return
	_start_failed = true
	hud.set_status("Failed to start ride — press Esc to go back")


func _on_auth_expired() -> void:
	if is_riding:
		hud.show_toast("Signed out — this ride won't be saved to your account")


func _back_to_menu() -> void:
	if not is_inside_tree():
		return
	if not GameSession.is_solo:
		WorldClient.disconnect_now()
		GameSession.reset()
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _input(event: InputEvent) -> void:
	# Camera switching works whenever the rig exists — including the pre-race
	# pen — so a player can frame their shot before the gun.
	if event is InputEventKey and event.pressed and not event.echo:
		if _handle_camera_key(event):
			return
		if event.keycode == KEY_M:
			GraphicsSettings.set_sound_enabled(not GraphicsSettings.sound_enabled)
			hud.show_toast("🔊 Sound on" if GraphicsSettings.sound_enabled else "🔇 Sound off")
			return
	if _start_failed and event is InputEventKey and event.pressed \
			and event.keycode == KEY_ESCAPE:
		_back_to_menu()
		return
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


func _on_touch_turn() -> void:
	if is_riding:
		heading = -heading


func _on_touch_camera() -> void:
	if camera_rig != null:
		_apply_camera_change(camera_rig.cycle_next())


func _on_touch_finish_tap() -> void:
	# The HUD already demanded a confirming second tap.
	if is_riding:
		_finish_ride()
	elif _start_failed:
		_back_to_menu()


func _effective_game_speed() -> float:
	return _game_speed if _speed_allowed() else 1.0


func _speed_allowed() -> bool:
	# Game Speed applies to keyboard (virtual) riders only — never when a real
	# power meter / trainer is the source, so a measured effort is never
	# time-distorted. Solo rides use the player's own setting; multiplayer races
	# use the host's game_speed (>1 marks a virtual race), keeping all virtual
	# riders in sync.
	if SensorBridge.using_sensor():
		return false
	return _is_solo_ride or _game_speed > 1.0


func _speed_label() -> String:
	# 2.0 → "2×", 1.5 → "1.5×".
	return ("%.1f×" % _game_speed).replace(".0×", "×")


func _handle_camera_key(event: InputEventKey) -> bool:
	# C cycles forward, V cycles back, number keys jump straight to a view.
	# Both the top row (KEY_1..KEY_9) and the numpad (KEY_KP_1..KEY_KP_9) work
	# — the numpad sits in a separate keycode region, so it needs its own
	# range. Returns true if the key was a camera key (so _input stops here).
	if camera_rig == null:
		return false
	var kc := event.keycode
	if kc == KEY_C:
		_apply_camera_change(camera_rig.cycle_next())
		return true
	if kc == KEY_V:
		_apply_camera_change(camera_rig.cycle_prev())
		return true
	var idx := -1
	if kc >= KEY_1 and kc <= KEY_9:
		idx = kc - KEY_1
	elif kc >= KEY_KP_1 and kc <= KEY_KP_9:
		idx = kc - KEY_KP_1
	if idx >= 0:
		if idx < camera_rig.view_count():
			_apply_camera_change(camera_rig.select(idx))
		return true
	return false


func _apply_camera_change(view_name: String) -> void:
	if view_name.is_empty():
		return
	# Remember the choice for the rest of the session so the next ride starts
	# on the same view. The rider visual is hidden/shown per-frame in _process
	# from the camera's live position (not here), so the body never flashes
	# mid-transition out of First Person.
	GameSession.camera_view_index = camera_rig.current_index()
	if hud != null:
		hud.show_camera(view_name)


func _process(delta: float) -> void:
	_update_ghost_visuals(delta)
	# Hide the player's own rider (and its bib, which rides on the same node)
	# whenever the camera eye is inside the body — that's First Person and the
	# slice of any transition that sweeps through it. Driven from the rig's
	# live eased position, so the body never flashes during an exit sweep. Runs
	# even before the gun so framing in the pen is correct too.
	if camera_rig != null and rider_visual_node != null:
		rider_visual_node.visible = not camera_rig.eye_inside_rider()
	if not is_riding:
		return
	_update_power_input(delta)


func _setup_cp_limiter(race_limits: Dictionary) -> void:
	# Build this rider's power ceiling: profile curve (W/kg × weight, falling
	# back to their style preset for pre-CP profiles), clamped to fit the
	# race's limits. Mirrors the web's riders/cp.py so every surface agrees.
	var wkg: Array = GameSession.rider_cp_wkg
	if wkg.size() != CPLimiter.DURATIONS_S.size():
		wkg = CPLimiter.preset_wkg(GameSession.rider_cp_style)
	var curve := CPLimiter.curve_from_wkg(wkg, GameSession.rider_weight_kg)
	curve = CPLimiter.clamp_curve_to_limits(
		curve, GameSession.rider_weight_kg, race_limits
	)
	cp_limiter = CPLimiter.new()
	cp_limiter.setup(curve)
	hud.set_cp_curve(cp_limiter)


func _update_power_input(delta: float) -> void:
	# Sensor power takes over only when the player selected SENSOR *and* a
	# live reading is fresh. Otherwise the keyboard ↑/↓ ramp stays in
	# control — so an unplugged bridge or a dropped sensor transparently
	# falls back to the keyboard, continuing from the last value with no
	# jump. The keyboard is always the default and the fallback.
	if SensorBridge.using_sensor() and SensorBridge.has_fresh_power():
		target_power_w = clampf(SensorBridge.latest_power_w, 0.0, MAX_POWER_W)
		return
	var ramp := 0.0
	if Input.is_key_pressed(KEY_UP):
		ramp += 1.0
	if Input.is_key_pressed(KEY_DOWN):
		ramp -= 1.0
	ramp = clampf(ramp + hud.touch_power_dir(), -1.0, 1.0)
	if ramp > 0.0:
		target_power_w = min(target_power_w + POWER_RATE_WPS * delta * ramp, MAX_POWER_W)
	elif ramp < 0.0:
		target_power_w = max(target_power_w + POWER_RATE_WPS * delta * ramp, 0.0)
	# CP curve: keyboard power can never exceed what the rider has left in
	# any rolling window. Only bites while racing (the pen doesn't burn ACP).
	if is_racing and cp_limiter != null and cp_limiter.is_active():
		target_power_w = minf(target_power_w, cp_limiter.allowed_power_w())


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
	# Game Speed: scale the simulation clock so a virtual ride advances faster
	# than real time. Gated to solo + keyboard (see _speed_allowed); networking,
	# telemetry cadence, and steering below stay on the real delta.
	var sim_delta := delta * _effective_game_speed()
	if is_racing:
		# Feed the CP windows in sim time (even for sensor riders — their HUD
		# curve still tracks effort; only keyboard power gets clamped).
		if cp_limiter != null:
			cp_limiter.add_sample(target_power_w, sim_delta)
		velocity_mps = CyclingPhysics.step_velocity(
			target_power_w, velocity_mps, gradient, kit, sim_delta, draft_mult
		)
		if velocity_mps > peak_speed_mps:
			peak_speed_mps = velocity_mps
		distance_m += velocity_mps * sim_delta * float(heading)
		elapsed_s += sim_delta
		# Races end at the line: covering the course length finishes the ride
		# and lands on the results screen. Solo rides keep lapping (Esc ends
		# them) — the loop is the point of a solo spin.
		if not _is_solo_ride and not _finishing:
			var finish_m := float(current_course.get("length_m", 0.0))
			if finish_m > 0.0 and distance_m >= finish_m:
				hud.show_toast("🏁 Finished!")
				_finish_ride()
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
	lateral_input += hud.touch_steer_dir() * LATERAL_SPEED_MPS * delta
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
	# Keep the distant backdrop (mountains + city) centred on the rider so it
	# stays on the horizon for the whole ride. Position only — no rotation —
	# so the peaks hold fixed world bearings as the rider turns.
	if _backdrop != null:
		_backdrop.global_position = rider_node.global_position
		_update_backdrop_depth(maxf(0.0, rider_node.global_position.y))
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
	_player_visual.animate(sim_delta, velocity_mps, _animation_cadence(), target_power_w)

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
	if _minimap_kind == 2 and _terrain_grid_m > 0.0:
		var rp := rider_node.global_position
		var world_w_m: float = float(_terrain_width) * _terrain_grid_m
		var world_h_m: float = float(_terrain_height) * _terrain_grid_m
		if world_w_m > 0.0 and world_h_m > 0.0:
			var max_y_m: float = _terrain_origin_y_m + world_h_m
			var u: float = (rp.x - _terrain_origin_x_m) / world_w_m
			var v: float = (max_y_m - (-rp.z)) / world_h_m
			hud.set_minimap_uv(u, v)
	elif _minimap_kind == 1:
		# Fallback map: rider world (x, z) → path frame (x_m = x, y_m = -z) → UV.
		var rp := rider_node.global_position
		var uv := _path_minimap_uv(rp.x, -rp.z)
		hud.set_minimap_uv(uv.x, uv.y)

	ride_audio.update(velocity_mps, target_power_w, _town_proximity())
	if not is_racing and GameSession.race_starts_at_unix_s > 0.0:
		var remaining_s: float = GameSession.race_starts_at_unix_s - Time.get_unix_time_from_system()
		hud.show_countdown(max(0.0, remaining_s))
		var n := int(ceil(maxf(0.0, remaining_s)))
		if n != _last_countdown_n and n >= 1 and n <= 3:
			ride_audio.countdown_tick()
		_last_countdown_n = n


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
	ride_audio.finish()
	if not _is_solo_ride:
		ride_audio.cheer()  # a race finish gets the crowd
	# Hand trainer resistance back to flat so the rider isn't left pushing
	# against the last climb's grade after the ride ends.
	SensorBridge.release_trainer()
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
		# One retry — every finisher POSTs within seconds of each other.
		hud.set_status("Finish didn't reach the server — retrying…")
		await get_tree().create_timer(1.5).timeout
		result = await ApiClient.finish_ride(current_ride_id, totals, "explicit")

	# Drop the game socket only AFTER the finish (with its real totals) is
	# recorded: the server finalizes the ride the instant the WS closes, and
	# Django's finalize is first-write-wins — disconnecting first turns every
	# line-crosser into a totals-less DNF.
	WorldClient.disconnect_now()

	if result.is_empty():
		# Still unreachable. Don't strand the rider at the line — the server's
		# disconnect/timeout sweep will finalize the ride from the uploaded
		# samples' row; carry on to the results/summary with local numbers.
		hud.show_toast("⚠ Finish not confirmed — showing local results")
		result = totals

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
