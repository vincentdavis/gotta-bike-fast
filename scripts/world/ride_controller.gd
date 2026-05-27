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

var rider_node: Node3D
var camera: Camera3D
var hud: CanvasLayer

var kit: PhysicsKit = PhysicsKit.new()
var rider_id: String = ""
var current_ride_id: String = ""
var current_course: Dictionary = {}

var is_riding: bool = false
var _finishing: bool = false
var target_power_w: float = STARTING_POWER_W
var velocity_mps: float = 0.0
var distance_m: float = 0.0
var elapsed_s: float = 0.0
var heading: int = 1  # +1 = facing -Z, -1 = turned around (facing +Z)

var _samples_buffer: Array = []
var _sample_accum_s: float = 0.0
var _flush_accum_s: float = 0.0

var _ghosts: Dictionary = {}  # rider_id (String) -> Node3D
var _world_state_accum_s: float = 0.0


func _ready() -> void:
	_setup_environment()
	_setup_ground()
	_setup_road()
	_setup_markers()
	_setup_scenery()
	_setup_sun()
	_setup_rider()
	_setup_camera()
	_setup_hud()
	_start_session()


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


func _setup_road() -> void:
	const ROAD_WIDTH := 4.0
	const ROAD_LENGTH := 20000.0
	const LINE_WIDTH := 0.15

	# Asphalt strip down the middle of the field, slightly raised to avoid
	# z-fighting with the ground. Centered on the rider's path (-Z forward).
	var road := MeshInstance3D.new()
	var road_mesh := PlaneMesh.new()
	road_mesh.size = Vector2(ROAD_WIDTH, ROAD_LENGTH)
	road.mesh = road_mesh
	var road_mat := StandardMaterial3D.new()
	road_mat.albedo_color = Color(0.18, 0.18, 0.20)
	road_mat.roughness = 0.85
	road.material_override = road_mat
	road.position = Vector3(0.0, 0.01, -ROAD_LENGTH * 0.5 + 100.0)
	add_child(road)

	# Dashed center line via MultiMesh — one draw call for all dashes.
	const DASH_LENGTH := 3.0
	const DASH_GAP := 5.0
	const DASH_COVERAGE := 10000.0  # length of road that gets dashes
	var dash_period := DASH_LENGTH + DASH_GAP
	var num_dashes := int(DASH_COVERAGE / dash_period)

	var dashes := MultiMesh.new()
	dashes.transform_format = MultiMesh.TRANSFORM_3D
	dashes.instance_count = num_dashes
	var dash_mesh := PlaneMesh.new()
	dash_mesh.size = Vector2(LINE_WIDTH, DASH_LENGTH)
	dashes.mesh = dash_mesh
	for i in num_dashes:
		var dz := -(i * dash_period + DASH_LENGTH * 0.5)
		var t := Transform3D.IDENTITY
		t.origin = Vector3(0.0, 0.02, dz)
		dashes.set_instance_transform(i, t)

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

	# One shared mesh + material per marker style — Godot will batch instances.
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
		var is_km := (i % 10) == 0
		for side in [-1.0, 1.0]:
			var post := MeshInstance3D.new()
			post.mesh = km_mesh if is_km else post_mesh
			post.material_override = km_mat if is_km else post_mat
			var height := (km_mesh.height if is_km else post_mesh.height) as float
			post.position = Vector3(side * SIDE_OFFSET, height * 0.5, -distance)
			add_child(post)


func _setup_scenery() -> void:
	# Trees: cone meshes scattered randomly beside the road. Single MultiMesh
	# instance so all trees share one draw call. Per-instance color varies the
	# greens slightly. Seed is fixed so the layout is reproducible.
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
		var dz: float = -rng.randf_range(20.0, Z_COVERAGE)
		var s: float = rng.randf_range(0.7, 1.4)

		var basis := Basis().scaled(Vector3.ONE * s)
		var origin := Vector3(x_dist, tree_mesh.height * 0.5 * s, dz)
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
	# Builds a rider-on-bike composite. Used for the local player and for
	# remote ghost riders (with a different colour).
	var root := Node3D.new()

	var body := MeshInstance3D.new()
	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = 0.18
	body_mesh.height = 1.5
	body.mesh = body_mesh
	body.position = Vector3(0.0, 1.05, 0.0)
	body.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = albedo
	body.material_override = body_mat
	root.add_child(body)

	var wheel_mesh := CylinderMesh.new()
	wheel_mesh.height = 0.05
	wheel_mesh.top_radius = 0.34
	wheel_mesh.bottom_radius = 0.34
	var wheel_mat := StandardMaterial3D.new()
	wheel_mat.albedo_color = Color(0.08, 0.08, 0.08)
	wheel_mat.roughness = 0.6

	for z_offset in [-0.55, 0.55]:
		var wheel := MeshInstance3D.new()
		wheel.mesh = wheel_mesh
		wheel.material_override = wheel_mat
		wheel.position = Vector3(0.0, 0.34, z_offset)
		wheel.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		root.add_child(wheel)

	var frame := MeshInstance3D.new()
	var frame_mesh := CylinderMesh.new()
	frame_mesh.height = 1.1
	frame_mesh.top_radius = 0.04
	frame_mesh.bottom_radius = 0.04
	frame.mesh = frame_mesh
	frame.material_override = body_mat
	frame.position = Vector3(0.0, 0.55, 0.0)
	frame.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	root.add_child(frame)

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

func _start_session() -> void:
	hud.set_status("Creating rider…")
	var rider: Dictionary = await ApiClient.create_rider(
		"Anonymous", kit.rider.mass_kg, kit.rider.height_m, 200
	)
	if rider.is_empty():
		hud.set_status("Failed to create rider")
		return
	rider_id = str(rider["id"])

	hud.set_status("Loading courses…")
	var courses: Array = await ApiClient.list_courses()
	if courses.is_empty():
		hud.set_status("No courses available")
		return

	var first: Dictionary = courses[0]
	hud.set_status("Loading %s…" % first["name"])
	var detail: Dictionary = await ApiClient.get_course(str(first["id"]))
	if detail.is_empty():
		hud.set_status("Failed to load course")
		return

	current_course = detail
	hud.set_course(detail["name"], float(detail["length_m"]))

	hud.set_status("Starting ride…")
	var ride: Dictionary = await ApiClient.start_ride(rider_id, str(detail["id"]))
	if ride.is_empty():
		hud.set_status("Failed to start ride")
		return

	current_ride_id = str(ride["id"])
	target_power_w = STARTING_POWER_W
	is_riding = true
	hud.set_status("Go!")

	# Multiplayer: connect to the course's world session. The ride still
	# works locally if the WS connect fails — ghosts simply won't appear.
	WorldClient.welcome.connect(_on_welcome)
	WorldClient.rider_joined.connect(_on_rider_joined)
	WorldClient.rider_left.connect(_on_rider_left)
	WorldClient.rider_state.connect(_on_rider_state)
	WorldClient.connect_to_course(str(detail["id"]), rider_id)

	await get_tree().create_timer(1.5).timeout
	if is_riding:
		hud.set_status("")


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

	var gradient := _gradient_at_distance(distance_m)
	velocity_mps = CyclingPhysics.step_velocity(
		target_power_w, velocity_mps, gradient, kit, delta
	)
	distance_m += velocity_mps * delta
	elapsed_s += delta

	# Lateral steering input (rider's local frame: +X is rider's right).
	var local_dx := 0.0
	if Input.is_key_pressed(KEY_LEFT):
		local_dx -= LATERAL_SPEED_MPS * delta
	if Input.is_key_pressed(KEY_RIGHT):
		local_dx += LATERAL_SPEED_MPS * delta

	# Forward = local -Z; rider_node's rotation handles turn-around.
	rider_node.translate(Vector3(local_dx, 0.0, -velocity_mps * delta))

	# Soft clamp: keep the rider on the road (road runs along world Z).
	var world_x := rider_node.global_position.x
	if world_x > ROAD_HALF_WIDTH_M:
		rider_node.global_position.x = ROAD_HALF_WIDTH_M
	elif world_x < -ROAD_HALF_WIDTH_M:
		rider_node.global_position.x = -ROAD_HALF_WIDTH_M

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
			}
		)

	hud.set_power(target_power_w)
	hud.set_speed(velocity_mps)
	hud.set_distance(distance_m)
	hud.set_elapsed(elapsed_s)


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
			return lerp(float(p0["gradient"]), float(p1["gradient"]), t)
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
	hud.set_status(
		(
			"Done · %.2f km · %d:%02d · avg %d W · max %d W"
			% [dist_km, int(time_s) / 60, int(time_s) % 60, avg_w, max_w]
		)
	)


# --- Multiplayer ghosts ---

func _on_welcome(riders: Array) -> void:
	for r in riders:
		var rid: String = str(r.get("rider_id", ""))
		if rid.is_empty():
			continue
		_spawn_ghost(rid)
		var state = r.get("state", {})
		if state is Dictionary and not state.is_empty():
			_apply_ghost_state(rid, state)


func _on_rider_joined(rider_id: String, _display_name: String) -> void:
	if rider_id.is_empty():
		return
	_spawn_ghost(rider_id)


func _on_rider_left(rider_id: String) -> void:
	if not _ghosts.has(rider_id):
		return
	var node: Node3D = _ghosts[rider_id]
	node.queue_free()
	_ghosts.erase(rider_id)


func _on_rider_state(rider_id: String, state: Dictionary) -> void:
	if not _ghosts.has(rider_id):
		_spawn_ghost(rider_id)
	_apply_ghost_state(rider_id, state)


func _spawn_ghost(rider_id: String) -> void:
	if _ghosts.has(rider_id):
		return
	var ghost := Node3D.new()
	ghost.name = "Ghost_%s" % rider_id
	ghost.add_child(_build_rider_visual(GHOST_COLOR))
	add_child(ghost)
	_ghosts[rider_id] = ghost


func _apply_ghost_state(rider_id: String, state: Dictionary) -> void:
	if not _ghosts.has(rider_id):
		return
	var ghost: Node3D = _ghosts[rider_id]
	ghost.global_position = Vector3(
		float(state.get("x", 0.0)),
		0.0,
		float(state.get("z", 0.0)),
	)
	var ghost_heading := int(state.get("heading", 1))
	ghost.rotation.y = 0.0 if ghost_heading == 1 else PI
