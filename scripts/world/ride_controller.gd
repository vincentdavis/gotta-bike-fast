extends Node3D

# Phase 1 ride controller — builds the world, fetches a course, drives
# physics-based rider movement, batches samples to the backend, finishes
# the ride on Esc.

const HUD_SCENE := preload("res://scenes/hud.tscn")

const POWER_RATE_WPS := 80.0
const MAX_POWER_W := 1000.0
const STARTING_POWER_W := 100.0
const SAMPLE_HZ := 4.0
const SAMPLE_FLUSH_S := 5.0

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

var _samples_buffer: Array = []
var _sample_accum_s: float = 0.0
var _flush_accum_s: float = 0.0


func _ready() -> void:
	_setup_environment()
	_setup_ground()
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
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.55, 0.28)
	mat.roughness = 1.0
	ground.material_override = mat
	add_child(ground)


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

	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.7
	mesh.mesh = capsule
	mesh.position = Vector3(0.0, 0.85, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.2, 0.15)
	mesh.material_override = mat
	rider_node.add_child(mesh)


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

	rider_node.position.z = -distance_m

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
