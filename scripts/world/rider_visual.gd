class_name RiderVisual
extends Node3D

# Procedural cyclist + bike with a cadence-driven animation rig. Replaces
# the old static _build_rider_visual: wheels have spokes and spin with road
# speed, the cranks turn with cadence, the legs follow the pedals with a
# two-bone IK solve, and the upper body rocks subtly with effort.
#
# Used for the player and for ghosts. Call animate() every physics tick:
#   speed_mps    drives wheel rotation
#   cadence_rpm  drives crank + leg motion (real BLE cadence for the player
#                when a sensor is fresh; speed/power estimate otherwise)
#   power_w      drives the torso sway amplitude (0 for ghosts)
#
# The rig faces -Z like the old visual; the ride controller still pitches
# the whole node with road grade.

const WHEEL_RADIUS := 0.34
const CRANK_LEN := 0.17
const BB := Vector3(0, 0.36, 0.05)  # bottom bracket (crank axle)
const PEDAL_X := 0.13               # pedal lateral offset from centerline
const HIP_Y := 0.97
const HIP_X := 0.10
const HIP_Z := 0.15                 # hips sit slightly behind the BB (saddle)
const THIGH_LEN := 0.42
const SHIN_LEN := 0.42

var _front_spinner: Node3D
var _rear_spinner: Node3D
var _upper: Node3D
var _pedal_l: MeshInstance3D
var _pedal_r: MeshInstance3D
var _crank_l: MeshInstance3D
var _crank_r: MeshInstance3D
var _thigh_l: MeshInstance3D
var _thigh_r: MeshInstance3D
var _shin_l: MeshInstance3D
var _shin_r: MeshInstance3D

var _pedal_phase := 0.0
var _wheel_phase := 0.0


func _init(albedo: Color) -> void:
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
	var accent := StandardMaterial3D.new()
	accent.albedo_color = Color(0.95, 0.45, 0.15)
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.75, 0.76, 0.78)
	metal.metallic = 0.6
	metal.roughness = 0.35

	const LEAN_DEG := -28.0

	# --- upper body: pivots at the saddle so effort sway rocks the torso ---
	_upper = Node3D.new()
	_upper.position = Vector3(0, 0.95, 0.10)
	add_child(_upper)

	var torso := _part(CapsuleMesh.new(), jersey, Vector3(0, 0.10, -0.10))
	(torso.mesh as CapsuleMesh).radius = 0.18
	(torso.mesh as CapsuleMesh).height = 0.80
	torso.rotation_degrees = Vector3(LEAN_DEG, 0, 0)
	_upper.add_child(torso)

	var stripe := _part(BoxMesh.new(), accent, Vector3(0, 0.33, -0.30))
	(stripe.mesh as BoxMesh).size = Vector3(0.36, 0.10, 0.04)
	stripe.rotation_degrees = Vector3(LEAN_DEG, 0, 0)
	_upper.add_child(stripe)

	var head := _part(SphereMesh.new(), skin, Vector3(0, 0.67, -0.40))
	(head.mesh as SphereMesh).radius = 0.12
	(head.mesh as SphereMesh).height = 0.26
	_upper.add_child(head)

	var helmet := _part(SphereMesh.new(), helmet_mat, Vector3(0, 0.75, -0.42))
	(helmet.mesh as SphereMesh).radius = 0.14
	(helmet.mesh as SphereMesh).height = 0.20
	_upper.add_child(helmet)

	var arm_mesh := CapsuleMesh.new()
	arm_mesh.radius = 0.055
	arm_mesh.height = 0.55
	for x_off in [-0.16, 0.16]:
		var arm := _part(arm_mesh, jersey, Vector3(x_off, 0.23, -0.40))
		arm.rotation_degrees = Vector3(-60.0, 0, 0)
		_upper.add_child(arm)

	# --- bike frame (static) ---
	var frame := _part(CylinderMesh.new(), jersey, Vector3(0, 0.58, 0))
	(frame.mesh as CylinderMesh).height = 1.05
	(frame.mesh as CylinderMesh).top_radius = 0.035
	(frame.mesh as CylinderMesh).bottom_radius = 0.035
	frame.rotation_degrees = Vector3(90, 0, 0)
	add_child(frame)

	var post := _part(CylinderMesh.new(), metal, Vector3(0, 0.78, 0.14))
	(post.mesh as CylinderMesh).height = 0.36
	(post.mesh as CylinderMesh).top_radius = 0.02
	(post.mesh as CylinderMesh).bottom_radius = 0.02
	add_child(post)

	var saddle := _part(BoxMesh.new(), bibs, Vector3(0, 0.97, 0.16))
	(saddle.mesh as BoxMesh).size = Vector3(0.12, 0.04, 0.26)
	add_child(saddle)

	var bars := _part(CylinderMesh.new(), bibs, Vector3(0, 0.92, -0.50))
	(bars.mesh as CylinderMesh).height = 0.42
	(bars.mesh as CylinderMesh).top_radius = 0.018
	(bars.mesh as CylinderMesh).bottom_radius = 0.018
	bars.rotation_degrees = Vector3(0, 0, 90)
	add_child(bars)

	# --- wheels: spinner pivots so spokes make the rotation visible ---
	_front_spinner = _build_wheel(rubber, metal, Vector3(0, WHEEL_RADIUS, -0.55))
	_rear_spinner = _build_wheel(rubber, metal, Vector3(0, WHEEL_RADIUS, 0.55))

	# --- drivetrain + legs (positioned every frame by animate()) ---
	var crank_mesh := BoxMesh.new()
	crank_mesh.size = Vector3(0.035, 1.0, 0.05)  # unit length, stretched per frame
	_crank_l = _part(crank_mesh, metal, Vector3.ZERO)
	_crank_r = _part(crank_mesh, metal, Vector3.ZERO)
	add_child(_crank_l)
	add_child(_crank_r)

	var pedal_mesh := BoxMesh.new()
	pedal_mesh.size = Vector3(0.09, 0.035, 0.17)  # doubles as the shoe
	_pedal_l = _part(pedal_mesh, bibs, Vector3.ZERO)
	_pedal_r = _part(pedal_mesh, bibs, Vector3.ZERO)
	add_child(_pedal_l)
	add_child(_pedal_r)

	var thigh_mesh := CapsuleMesh.new()
	thigh_mesh.radius = 0.075
	thigh_mesh.height = 1.0  # unit length, stretched per frame
	var shin_mesh := CapsuleMesh.new()
	shin_mesh.radius = 0.06
	shin_mesh.height = 1.0
	_thigh_l = _part(thigh_mesh, bibs, Vector3.ZERO)
	_thigh_r = _part(thigh_mesh, bibs, Vector3.ZERO)
	_shin_l = _part(shin_mesh, skin, Vector3.ZERO)
	_shin_r = _part(shin_mesh, skin, Vector3.ZERO)
	add_child(_thigh_l)
	add_child(_thigh_r)
	add_child(_shin_l)
	add_child(_shin_r)

	# Settle into a sensible pose even before the first animate() call.
	animate(0.0, 0.0, 0.0, 0.0)


func _part(mesh: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	inst.position = pos
	return inst


func _build_wheel(rubber: Material, metal: Material, at: Vector3) -> Node3D:
	var spinner := Node3D.new()
	spinner.position = at
	add_child(spinner)

	var tire := _part(CylinderMesh.new(), rubber, Vector3.ZERO)
	(tire.mesh as CylinderMesh).height = 0.05
	(tire.mesh as CylinderMesh).top_radius = WHEEL_RADIUS
	(tire.mesh as CylinderMesh).bottom_radius = WHEEL_RADIUS
	tire.rotation_degrees = Vector3(0, 0, 90)
	spinner.add_child(tire)

	var hub := _part(CylinderMesh.new(), metal, Vector3.ZERO)
	(hub.mesh as CylinderMesh).height = 0.09
	(hub.mesh as CylinderMesh).top_radius = 0.035
	(hub.mesh as CylinderMesh).bottom_radius = 0.035
	hub.rotation_degrees = Vector3(0, 0, 90)
	spinner.add_child(hub)

	var spoke_mesh := BoxMesh.new()
	spoke_mesh.size = Vector3(0.016, WHEEL_RADIUS * 1.86, 0.016)
	for deg in [0.0, 60.0, 120.0]:
		var spoke := _part(spoke_mesh, metal, Vector3.ZERO)
		spoke.rotation_degrees = Vector3(deg, 0, 0)
		spinner.add_child(spoke)
	return spinner


# --- per-frame animation ---

func animate(delta: float, speed_mps: float, cadence_rpm: float, power_w: float) -> void:
	# Wheels roll with ground speed (forward = -Z → top of wheel moves -Z).
	_wheel_phase = wrapf(_wheel_phase - (speed_mps / WHEEL_RADIUS) * delta, -TAU, TAU)
	_front_spinner.rotation.x = _wheel_phase
	_rear_spinner.rotation.x = _wheel_phase

	# Cranks turn with cadence; θ=0 is the left pedal at top-dead-center.
	_pedal_phase = wrapf(_pedal_phase + (cadence_rpm / 60.0) * TAU * delta, 0.0, TAU)
	var foot_l := _pedal_pos(_pedal_phase) + Vector3(-PEDAL_X, 0, 0)
	var foot_r := _pedal_pos(_pedal_phase + PI) + Vector3(PEDAL_X, 0, 0)
	_pedal_l.position = foot_l
	_pedal_r.position = foot_r
	_stretch(_crank_l, BB + Vector3(-0.06, 0, 0), foot_l)
	_stretch(_crank_r, BB + Vector3(0.06, 0, 0), foot_r)

	_solve_leg(Vector3(-HIP_X, HIP_Y, HIP_Z), foot_l + Vector3(0, 0.05, 0), _thigh_l, _shin_l)
	_solve_leg(Vector3(HIP_X, HIP_Y, HIP_Z), foot_r + Vector3(0, 0.05, 0), _thigh_r, _shin_r)

	# Effort sway: hips rock once per crank revolution, harder with power.
	var amp: float = clampf(power_w / 12000.0, 0.0, 0.05)
	_upper.rotation.z = sin(_pedal_phase) * amp


func _pedal_pos(theta: float) -> Vector3:
	# Crank circle in the bike's sagittal (YZ) plane; forward stroke over
	# the top toward -Z.
	return BB + Vector3(0, cos(theta) * CRANK_LEN, -sin(theta) * CRANK_LEN)


func _solve_leg(hip: Vector3, foot: Vector3, thigh: MeshInstance3D, shin: MeshInstance3D) -> void:
	# Two-bone IK via the law of cosines, knee bending forward (-Z).
	var d := foot - hip
	var l := clampf(d.length(), absf(THIGH_LEN - SHIN_LEN) + 0.01, THIGH_LEN + SHIN_LEN - 0.01)
	var n := d.normalized()
	var cos_a := (THIGH_LEN * THIGH_LEN + l * l - SHIN_LEN * SHIN_LEN) / (2.0 * THIGH_LEN * l)
	cos_a = clampf(cos_a, -1.0, 1.0)
	var sin_a := sqrt(maxf(0.0, 1.0 - cos_a * cos_a))
	var bend := Vector3.FORWARD - n * Vector3.FORWARD.dot(n)
	bend = bend.normalized() if bend.length() > 0.01 else Vector3.FORWARD
	var knee := hip + n * (THIGH_LEN * cos_a) + bend * (THIGH_LEN * sin_a)
	_stretch(thigh, hip, knee)
	_stretch(shin, knee, foot)


func _stretch(node: Node3D, from: Vector3, to: Vector3) -> void:
	# Place a unit-height (Y) mesh between two points by scaling its Y axis.
	var d := to - from
	var l := d.length()
	if l < 0.001:
		return
	var y := d / l
	var ref_v := Vector3.RIGHT if absf(y.dot(Vector3.RIGHT)) < 0.95 else Vector3.FORWARD
	var x := y.cross(ref_v).normalized()
	var z := x.cross(y)
	node.basis = Basis(x, y * l, z)
	node.position = (from + to) * 0.5
