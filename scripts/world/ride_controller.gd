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
const SAMPLE_HZ := 4.0
const SAMPLE_FLUSH_S := 5.0
const WORLD_STATE_HZ := 10.0  # outbound multiplayer state rate
const PLAYER_COLOR := Color(0.85, 0.20, 0.15)
const GHOST_COLOR := Color(0.15, 0.40, 0.85)
const DRAFT_MAX_DISTANCE_M := 10.0
const DRAFT_MAX_LATERAL_M := 2.0
const DRAFT_FULL_REDUCTION := 0.35  # max CdA savings at perfect draft

var rider_node: Node3D
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
var heading: int = 1  # +1 = facing -Z, -1 = turned around (facing +Z)
var _start_line_node: Node3D = null

var _samples_buffer: Array = []
var _sample_accum_s: float = 0.0
var _flush_accum_s: float = 0.0

var _ghosts: Dictionary = {}  # rider_id (String) -> Node3D
var _ghost_targets: Dictionary = {}  # rider_id -> {pos, velocity, yaw, t_ms}
var _ghost_names: Dictionary = {}  # rider_id -> display_name
var _ghost_bibs: Dictionary = {}  # rider_id -> bib_number
var _ghost_distances: Dictionary = {}  # rider_id -> latest reported distance_m
var _my_bib: int = 0
var _world_state_accum_s: float = 0.0
var _course_elevations: Array = []  # cumulative elevation at each waypoint

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


# --- World construction ---

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _setup_ground() -> void:
	var ground := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(4000, 4000)
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


func _build_course_visuals() -> void:
	# Course-dependent visuals: road geometry, markers, and trees all use the
	# elevation profile. Called from _start_solo / _start_game after the
	# chosen course has been loaded.
	_compute_course_elevations()
	_setup_ground_strip()
	_setup_road()
	_setup_markers()
	_setup_scenery()


func _setup_ground_strip() -> void:
	# Wide ground bed that follows the road's elevation, so the road and
	# trees don't appear to float above the flat backdrop. Same per-segment
	# tilt as the road, just much wider.
	const STRIP_WIDTH := 240.0
	const STRIP_LENGTH := 20000.0
	const SEGMENT_LENGTH := 5.0
	const NUM_SEGMENTS := int(STRIP_LENGTH / SEGMENT_LENGTH)

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.instance_count = NUM_SEGMENTS
	var seg_mesh := PlaneMesh.new()
	seg_mesh.size = Vector2(STRIP_WIDTH, SEGMENT_LENGTH)
	multi.mesh = seg_mesh
	for i in NUM_SEGMENTS:
		var d_mid: float = float(i) * SEGMENT_LENGTH + SEGMENT_LENGTH * 0.5
		var y_mid := _elevation_at_distance(d_mid)
		var grade := _gradient_at_distance(d_mid)
		var pitch := atan(grade)
		var basis := Basis().rotated(Vector3.RIGHT, pitch)
		var origin := Vector3(0.0, y_mid, -d_mid)
		multi.set_instance_transform(i, Transform3D(basis, origin))

	var inst := MultiMeshInstance3D.new()
	inst.multimesh = multi
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.55, 0.28)
	mat.roughness = 1.0
	inst.material_override = mat
	add_child(inst)


func _compute_course_elevations() -> void:
	_course_elevations = []
	if current_course.is_empty():
		return
	var profile: Array = current_course.get("elevation_profile", [])
	if profile.size() < 2:
		return
	_course_elevations.resize(profile.size())
	_course_elevations[0] = 0.0
	for i in range(1, profile.size()):
		var p0: Dictionary = profile[i - 1]
		var p1: Dictionary = profile[i]
		var d0 := float(p0["distance_m"])
		var d1 := float(p1["distance_m"])
		var g0 := float(p0["gradient"])
		var g1 := float(p1["gradient"])
		var avg_g := (g0 + g1) * 0.5
		_course_elevations[i] = _course_elevations[i - 1] + (d1 - d0) * avg_g


func _elevation_at_distance(d: float) -> float:
	if _course_elevations.is_empty() or current_course.is_empty():
		return 0.0
	var profile: Array = current_course.get("elevation_profile", [])
	if profile.size() < 2:
		return 0.0
	var length := float(current_course.get("length_m", 0.0))
	if length > 0.0:
		d = fposmod(d, length)
	for i in range(profile.size() - 1):
		var p0: Dictionary = profile[i]
		var p1: Dictionary = profile[i + 1]
		var d0 := float(p0["distance_m"])
		var d1 := float(p1["distance_m"])
		if d >= d0 and d <= d1:
			if d1 <= d0:
				return float(_course_elevations[i])
			var g0 := float(p0["gradient"])
			var g1 := float(p1["gradient"])
			var t := (d - d0) / (d1 - d0)
			var g_at_d := lerpf(g0, g1, t)
			var avg := (g0 + g_at_d) * 0.5
			return float(_course_elevations[i]) + (d - d0) * avg
	return 0.0


func _setup_road() -> void:
	const ROAD_WIDTH := 4.0
	const ROAD_LENGTH := 20000.0
	const SEGMENT_LENGTH := 5.0
	const NUM_SEGMENTS := int(ROAD_LENGTH / SEGMENT_LENGTH)
	const DASH_LENGTH := 3.0
	const DASH_PERIOD := 8.0
	const DASH_COVERAGE := 10000.0
	const LINE_WIDTH := 0.15

	# Asphalt: short plane segments, each pitched to match the local gradient,
	# stacked from y = elevation_at_distance(midpoint). Single MultiMesh =
	# one draw call.
	var road_multi := MultiMesh.new()
	road_multi.transform_format = MultiMesh.TRANSFORM_3D
	road_multi.instance_count = NUM_SEGMENTS
	var road_mesh := PlaneMesh.new()
	road_mesh.size = Vector2(ROAD_WIDTH, SEGMENT_LENGTH)
	road_multi.mesh = road_mesh
	for i in NUM_SEGMENTS:
		var d_mid: float = float(i) * SEGMENT_LENGTH + SEGMENT_LENGTH * 0.5
		var y_mid := _elevation_at_distance(d_mid)
		var grade := _gradient_at_distance(d_mid)
		var pitch := atan(grade)
		var basis := Basis().rotated(Vector3.RIGHT, pitch)
		var origin := Vector3(0.0, y_mid + 0.01, -d_mid)
		road_multi.set_instance_transform(i, Transform3D(basis, origin))

	var road_inst := MultiMeshInstance3D.new()
	road_inst.multimesh = road_multi
	var road_mat := StandardMaterial3D.new()
	road_mat.albedo_color = Color(0.18, 0.18, 0.20)
	road_mat.roughness = 0.85
	road_inst.material_override = road_mat
	add_child(road_inst)

	# Dashed center line — same treatment, slightly above the asphalt.
	var num_dashes := int(DASH_COVERAGE / DASH_PERIOD)
	var dashes := MultiMesh.new()
	dashes.transform_format = MultiMesh.TRANSFORM_3D
	dashes.instance_count = num_dashes
	var dash_mesh := PlaneMesh.new()
	dash_mesh.size = Vector2(LINE_WIDTH, DASH_LENGTH)
	dashes.mesh = dash_mesh
	for i in num_dashes:
		var d_mid: float = float(i) * DASH_PERIOD + DASH_LENGTH * 0.5
		var y_mid := _elevation_at_distance(d_mid)
		var grade := _gradient_at_distance(d_mid)
		var pitch := atan(grade)
		var basis := Basis().rotated(Vector3.RIGHT, pitch)
		var origin := Vector3(0.0, y_mid + 0.02, -d_mid)
		dashes.set_instance_transform(i, Transform3D(basis, origin))

	var dashes_inst := MultiMeshInstance3D.new()
	dashes_inst.multimesh = dashes
	var dash_mat := StandardMaterial3D.new()
	dash_mat.albedo_color = Color(0.92, 0.92, 0.78)
	dashes_inst.material_override = dash_mat
	add_child(dashes_inst)


func _setup_markers() -> void:
	const MARKER_COUNT := 100  # markers up to 10km
	const SPACING_M := 100.0
	const SIDE_OFFSET := 3.2

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

	for i in range(1, MARKER_COUNT + 1):
		var distance := i * SPACING_M
		var elev := _elevation_at_distance(distance)
		var is_km := (i % 10) == 0
		for side in [-1.0, 1.0]:
			var post := MeshInstance3D.new()
			post.mesh = km_mesh if is_km else post_mesh
			post.material_override = km_mat if is_km else post_mat
			var height := (km_mesh.height if is_km else post_mesh.height) as float
			post.position = Vector3(side * SIDE_OFFSET, elev + height * 0.5, -distance)
			add_child(post)


func _setup_scenery() -> void:
	# Trees: cone meshes scattered randomly beside the road. Single MultiMesh
	# instance so all trees share one draw call. Per-instance color varies
	# the greens slightly. Seed is fixed so the layout is reproducible.
	# Y matches the road elevation so trees plant on the hillside, not under
	# or above the road as it rises.
	const TREE_COUNT := 250
	const MIN_SIDE_DIST := 6.0
	const MAX_SIDE_DIST := 60.0
	const Z_COVERAGE := 9500.0

	var trees := MultiMesh.new()
	trees.transform_format = MultiMesh.TRANSFORM_3D
	trees.use_colors = true
	trees.instance_count = TREE_COUNT

	var tree_mesh := CylinderMesh.new()
	tree_mesh.top_radius = 0.0
	tree_mesh.bottom_radius = 0.9
	tree_mesh.height = 3.5
	trees.mesh = tree_mesh

	var rng := RandomNumberGenerator.new()
	rng.seed = 0xB1CE_F00D

	for i in TREE_COUNT:
		var side: float = -1.0 if rng.randf() < 0.5 else 1.0
		var x_dist: float = rng.randf_range(MIN_SIDE_DIST, MAX_SIDE_DIST) * side
		var distance: float = rng.randf_range(20.0, Z_COVERAGE)
		var s: float = rng.randf_range(0.7, 1.4)
		var elev := _elevation_at_distance(distance)

		var basis := Basis().scaled(Vector3.ONE * s)
		var origin := Vector3(x_dist, elev + tree_mesh.height * 0.5 * s, -distance)
		trees.set_instance_transform(i, Transform3D(basis, origin))

		var g: float = rng.randf_range(0.30, 0.50)
		trees.set_instance_color(i, Color(0.10, g, 0.12))

	var inst := MultiMeshInstance3D.new()
	inst.multimesh = trees
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	inst.material_override = mat
	add_child(inst)


func _setup_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.2
	add_child(sun)


func _setup_rider() -> void:
	rider_node = Node3D.new()
	rider_node.name = "Rider"
	add_child(rider_node)
	rider_node.add_child(_build_rider_visual(PLAYER_COLOR))


func _build_rider_visual(albedo: Color) -> Node3D:
	# Stylized cyclist on a bike. Primitive meshes only; for the real
	# jersey graphic we'd need a UV-unwrapped humanoid model. The jersey
	# uses `albedo` as the main colour and an orange chest accent.
	var root := Node3D.new()

	var jersey := StandardMaterial3D.new()
	jersey.albedo_color = albedo
	var bibs := StandardMaterial3D.new()
	bibs.albedo_color = Color(0.07, 0.07, 0.08)
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.93, 0.78, 0.65)
	var helmet_mat := StandardMaterial3D.new()
	helmet_mat.albedo_color = Color(0.92, 0.92, 0.92)
	helmet_mat.roughness = 0.4
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color(0.07, 0.07, 0.07)
	rubber.roughness = 0.7
	var accent_mat := StandardMaterial3D.new()
	accent_mat.albedo_color = Color(0.95, 0.45, 0.15)

	const LEAN_DEG := -28.0

	# Torso (forward aero lean).
	var torso := MeshInstance3D.new()
	var torso_mesh := CapsuleMesh.new()
	torso_mesh.radius = 0.18
	torso_mesh.height = 0.80
	torso.mesh = torso_mesh
	torso.position = Vector3(0.0, 1.05, 0.0)
	torso.rotation_degrees = Vector3(LEAN_DEG, 0.0, 0.0)
	torso.material_override = jersey
	root.add_child(torso)

	# Orange chest stripe.
	var stripe := MeshInstance3D.new()
	var stripe_mesh := BoxMesh.new()
	stripe_mesh.size = Vector3(0.36, 0.10, 0.04)
	stripe.mesh = stripe_mesh
	# Front-of-torso, upper, leaning with the rider.
	stripe.position = Vector3(0.0, 1.28, -0.20)
	stripe.rotation_degrees = Vector3(LEAN_DEG, 0.0, 0.0)
	stripe.material_override = accent_mat
	root.add_child(stripe)

	# Head + helmet (also tilted with the lean).
	var head := MeshInstance3D.new()
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.12
	head_mesh.height = 0.26
	head.mesh = head_mesh
	head.position = Vector3(0.0, 1.62, -0.30)
	head.material_override = skin
	root.add_child(head)

	var helmet := MeshInstance3D.new()
	var helmet_mesh := SphereMesh.new()
	helmet_mesh.radius = 0.14
	helmet_mesh.height = 0.20
	helmet.mesh = helmet_mesh
	helmet.position = Vector3(0.0, 1.70, -0.32)
	helmet.material_override = helmet_mat
	root.add_child(helmet)

	# Arms reaching for the handlebars.
	var arm_mesh := CapsuleMesh.new()
	arm_mesh.radius = 0.055
	arm_mesh.height = 0.55
	for x_off in [-0.16, 0.16]:
		var arm := MeshInstance3D.new()
		arm.mesh = arm_mesh
		arm.material_override = jersey
		arm.position = Vector3(x_off, 1.18, -0.30)
		arm.rotation_degrees = Vector3(-60.0, 0.0, 0.0)
		root.add_child(arm)

	# Legs (bib shorts) — vertical, atop the bottom bracket.
	var leg_mesh := CapsuleMesh.new()
	leg_mesh.radius = 0.075
	leg_mesh.height = 0.75
	for x_off in [-0.09, 0.09]:
		var leg := MeshInstance3D.new()
		leg.mesh = leg_mesh
		leg.material_override = bibs
		leg.position = Vector3(x_off, 0.62, 0.05)
		root.add_child(leg)

	# Wheels.
	var wheel_mesh := CylinderMesh.new()
	wheel_mesh.height = 0.05
	wheel_mesh.top_radius = 0.34
	wheel_mesh.bottom_radius = 0.34
	for z_offset in [-0.55, 0.55]:
		var wheel := MeshInstance3D.new()
		wheel.mesh = wheel_mesh
		wheel.material_override = rubber
		wheel.position = Vector3(0.0, 0.34, z_offset)
		wheel.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		root.add_child(wheel)

	# Bike frame (top tube, painted to match jersey).
	var frame := MeshInstance3D.new()
	var frame_mesh := CylinderMesh.new()
	frame_mesh.height = 1.05
	frame_mesh.top_radius = 0.035
	frame_mesh.bottom_radius = 0.035
	frame.mesh = frame_mesh
	frame.material_override = jersey
	frame.position = Vector3(0.0, 0.58, 0.0)
	frame.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	root.add_child(frame)

	# Handlebars: a small horizontal bar at the front, dark.
	var bars := MeshInstance3D.new()
	var bars_mesh := CylinderMesh.new()
	bars_mesh.height = 0.42
	bars_mesh.top_radius = 0.018
	bars_mesh.bottom_radius = 0.018
	bars.mesh = bars_mesh
	bars.material_override = bibs
	bars.position = Vector3(0.0, 0.92, -0.50)
	bars.rotation_degrees = Vector3(0.0, 0.0, 90.0)
	root.add_child(bars)

	return root


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
		get_tree().change_scene_to_file("res://scenes/riders.tscn")
		return

	var detail := await _resolve_course()
	if detail.is_empty():
		return

	current_course = detail
	hud.set_course(detail["name"], float(detail["length_m"]))
	_build_course_visuals()

	hud.set_status("Starting ride…")
	var ride: Dictionary = await ApiClient.start_ride(rider_id, str(detail["id"]))
	if ride.is_empty():
		hud.set_status("Failed to start ride")
		return
	current_ride_id = str(ride["id"])

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
		_add_bib_label(rider_node, _my_bib, PLAYER_COLOR)

	hud.set_status("Starting ride…")
	var ride: Dictionary = await ApiClient.start_ride(rider_id, str(detail["id"]))
	if ride.is_empty():
		hud.set_status("Failed to start ride")
		return
	current_ride_id = str(ride["id"])

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
	# Just in front of the rider's spawn (rider sits at z=0; line at z=-1).
	line.position = Vector3(0.0, _elevation_at_distance(1.0) + 0.03, -1.0)
	add_child(line)
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

func _input(event: InputEvent) -> void:
	if not is_riding:
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_SPACE:
			target_power_w = 0.0
		elif event.keycode == KEY_ESCAPE:
			_finish_ride()
		elif event.keycode == KEY_T:
			heading = -heading
			rider_node.rotation.y = 0.0 if heading == 1 else PI


func _process(delta: float) -> void:
	_update_ghost_visuals(delta)
	if not is_riding:
		return
	if Input.is_key_pressed(KEY_UP):
		target_power_w = min(target_power_w + POWER_RATE_WPS * delta, MAX_POWER_W)
	if Input.is_key_pressed(KEY_DOWN):
		target_power_w = max(target_power_w - POWER_RATE_WPS * delta, 0.0)


# --- Physics tick ---

func _physics_process(delta: float) -> void:
	if not is_riding:
		return

	# Course position is derived from the rider's world Z (start = 0, forward
	# travel makes Z negative). The raw gradient is signed by course
	# direction; flip when the rider has turned around so going "backwards
	# up the hill" reads as a descent.
	var course_pos := -rider_node.global_position.z
	var raw_grade := _gradient_at_distance(course_pos)
	var gradient := raw_grade * float(heading) if is_racing else 0.0
	var draft_mult := _compute_draft_multiplier()
	if is_racing:
		velocity_mps = CyclingPhysics.step_velocity(
			target_power_w, velocity_mps, gradient, kit, delta, draft_mult
		)
		if velocity_mps > peak_speed_mps:
			peak_speed_mps = velocity_mps
		distance_m += velocity_mps * delta
		elapsed_s += delta
	else:
		# Pen: bike is held, so even with power applied no actual speed.
		velocity_mps = 0.0

	# Lateral steering input (rider's local frame: +X is rider's right).
	var local_dx := 0.0
	if Input.is_key_pressed(KEY_LEFT):
		local_dx -= LATERAL_SPEED_MPS * delta
	if Input.is_key_pressed(KEY_RIGHT):
		local_dx += LATERAL_SPEED_MPS * delta

	if is_racing:
		# Forward = local -Z; rider_node's rotation handles turn-around.
		rider_node.translate(Vector3(local_dx, 0.0, -velocity_mps * delta))
	else:
		# Pen mode: lateral allowed, forward motion locked to z=0.
		rider_node.translate(Vector3(local_dx, 0.0, 0.0))
		rider_node.global_position.z = 0.0

	# Soft clamp: keep the rider on the road (road runs along world Z).
	var world_x := rider_node.global_position.x
	if world_x > ROAD_HALF_WIDTH_M:
		rider_node.global_position.x = ROAD_HALF_WIDTH_M
	elif world_x < -ROAD_HALF_WIDTH_M:
		rider_node.global_position.x = -ROAD_HALF_WIDTH_M

	# Plant the rider on the road surface.
	rider_node.global_position.y = _elevation_at_distance(-rider_node.global_position.z)

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

	hud.set_power(target_power_w)
	hud.set_speed(velocity_mps)
	hud.set_distance(distance_m)
	var course_length := float(current_course.get("length_m", 0.0))
	if course_length > 0.0:
		hud.set_lap(int(distance_m / course_length) + 1)
	hud.set_grade(gradient * 100.0)
	hud.set_elapsed(elapsed_s)
	hud.set_draft(int(round((1.0 - draft_mult) * 100.0)))
	hud.set_leaderboard(_build_leaderboard())

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


# --- Course profile lookup (gradient at distance, looping) ---

func _gradient_at_distance(d: float) -> float:
	if current_course.is_empty():
		return 0.0
	var profile: Array = current_course["elevation_profile"]
	if profile.size() < 2:
		return 0.0

	var length := float(current_course["length_m"])
	if length > 0.0:
		d = fposmod(d, length)

	for i in range(profile.size() - 1):
		var p0: Dictionary = profile[i]
		var p1: Dictionary = profile[i + 1]
		var d0 := float(p0["distance_m"])
		var d1 := float(p1["distance_m"])
		if d >= d0 and d <= d1:
			if d1 <= d0:
				return float(p0["gradient"])
			var t := (d - d0) / (d1 - d0)
			return lerpf(float(p0["gradient"]), float(p1["gradient"]), t)
	return 0.0


# --- Sample flush + finish ---

func _flush_samples() -> void:
	if _samples_buffer.is_empty():
		return
	var to_send := _samples_buffer.duplicate()
	_samples_buffer.clear()
	var ok: bool = await ApiClient.post_samples(current_ride_id, to_send)
	if not ok:
		_samples_buffer = to_send + _samples_buffer
		push_warning("Sample flush failed, re-buffering %d samples" % to_send.size())


func _finish_ride() -> void:
	if _finishing:
		return
	_finishing = true
	is_riding = false
	WorldClient.disconnect_now()
	hud.set_status("Finishing ride…")

	if not _samples_buffer.is_empty():
		var ok: bool = await ApiClient.post_samples(current_ride_id, _samples_buffer)
		if not ok:
			push_warning("Failed to post final samples")
		_samples_buffer.clear()

	var result: Dictionary = await ApiClient.finish_ride(current_ride_id)
	if result.is_empty():
		hud.set_status("Finish failed")
		return

	var dist_km := float(result.get("total_distance_m", 0.0)) / 1000.0
	var time_s := float(result.get("total_duration_s", 0.0))
	var avg_w := int(round(float(result.get("avg_power_w", 0.0))))
	var max_w := int(round(float(result.get("max_power_w", 0.0))))
	hud.set_status("")
	hud.hide_countdown()
	# Game mode: jump to the shared race-results screen (live standings).
	# Solo: show the inline ride-complete panel.
	if not GameSession.is_solo:
		get_tree().change_scene_to_file("res://scenes/results.tscn")
		return
	_show_summary(dist_km, time_s, avg_w, max_w)


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
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
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


func _on_rider_joined(rider_id: String, display_name: String, bib_number: int) -> void:
	if rider_id.is_empty():
		return
	_spawn_ghost(rider_id, display_name, bib_number)


func _on_rider_left(rider_id: String) -> void:
	if _ghosts.has(rider_id):
		_ghosts[rider_id].queue_free()
		_ghosts.erase(rider_id)
	_ghost_targets.erase(rider_id)
	_ghost_names.erase(rider_id)
	_ghost_bibs.erase(rider_id)
	_ghost_distances.erase(rider_id)


func _on_rider_state(rider_id: String, state: Dictionary) -> void:
	if not _ghosts.has(rider_id):
		_spawn_ghost(rider_id, "", 0)
	# First state for this ghost: snap into place (avoids a visible slide
	# from world origin). Subsequent states only update the target; _process
	# lerps the visual node toward it.
	var snap := not _ghost_targets.has(rider_id)
	_record_ghost_state(rider_id, state, snap)


func _spawn_ghost(rider_id: String, display_name: String = "", bib: int = 0) -> void:
	if _ghosts.has(rider_id):
		# Already spawned — just update name/bib if newly provided.
		if not display_name.is_empty():
			_ghost_names[rider_id] = display_name
		if bib > 0 and int(_ghost_bibs.get(rider_id, 0)) == 0:
			_ghost_bibs[rider_id] = bib
			_add_bib_label(_ghosts[rider_id], bib, GHOST_COLOR)
		return
	var ghost := Node3D.new()
	ghost.name = "Ghost_%s" % rider_id
	ghost.add_child(_build_rider_visual(GHOST_COLOR))
	add_child(ghost)
	_ghosts[rider_id] = ghost
	if not display_name.is_empty():
		_ghost_names[rider_id] = display_name
	if bib > 0:
		_ghost_bibs[rider_id] = bib
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


func _record_ghost_state(rider_id: String, state: Dictionary, snap: bool) -> void:
	if not _ghosts.has(rider_id):
		return
	var pos := Vector3(float(state.get("x", 0.0)), 0.0, float(state.get("z", 0.0)))
	var h: int = int(state.get("heading", 1))
	var speed: float = float(state.get("speed_mps", 0.0))
	var velocity := Vector3(0.0, 0.0, speed * (-1.0 if h == 1 else 1.0))
	var yaw: float = 0.0 if h == 1 else PI
	_ghost_targets[rider_id] = {
		"pos": pos,
		"velocity": velocity,
		"yaw": yaw,
		"t_ms": Time.get_ticks_msec(),
	}
	if state.has("distance_m"):
		_ghost_distances[rider_id] = float(state["distance_m"])
	if snap:
		var ghost: Node3D = _ghosts[rider_id]
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
