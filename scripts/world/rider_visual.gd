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
	# Belleville look: the racer is caricatured — Champion-style tree-trunk
	# calves and thighs on a shrunken torso — and painted in the muted palette
	# with flat, matte materials so the ink/posterize post-process does the
	# line work. (The team `albedo` tints the jersey, pulled toward ochre.)
	var jersey := StandardMaterial3D.new()
	jersey.albedo_color = albedo.lerp(Belleville.OCHRE, 0.30)
	jersey.roughness = 1.0
	var bibs := StandardMaterial3D.new()
	bibs.albedo_color = Belleville.INK
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.85, 0.72, 0.56)
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Belleville.INK
	rubber.roughness = 0.7
	var accent := StandardMaterial3D.new()
	accent.albedo_color = Belleville.TERRACOTTA
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Belleville.BRONZE
	metal.metallic = 0.0  # flat, illustrated — no chrome specular
	metal.roughness = 1.0

	const LEAN_DEG := -28.0

	# --- upper body: pivots at the saddle so effort sway rocks the torso ---
	_upper = Node3D.new()
	_upper.position = Vector3(0, 0.95, 0.10)
	add_child(_upper)

	var torso := _part(CapsuleMesh.new(), jersey, Vector3(0, 0.10, -0.10))
	(torso.mesh as CapsuleMesh).radius = 0.13  # shrunken torso (caricature)
	(torso.mesh as CapsuleMesh).height = 0.80
	torso.rotation_degrees = Vector3(LEAN_DEG, 0, 0)
	_upper.add_child(torso)

	var stripe := _part(BoxMesh.new(), accent, Vector3(0, 0.33, -0.30))
	(stripe.mesh as BoxMesh).size = Vector3(0.36, 0.10, 0.04)
	stripe.rotation_degrees = Vector3(LEAN_DEG, 0, 0)
	_upper.add_child(stripe)

	# Head thrust forward + low in the aero tuck, bridged to the shoulders by a
	# short neck so it doesn't float.
	var neck := _part(CylinderMesh.new(), skin, Vector3(0, 0.49, -0.34))
	(neck.mesh as CylinderMesh).height = 0.16
	(neck.mesh as CylinderMesh).top_radius = 0.05
	(neck.mesh as CylinderMesh).bottom_radius = 0.058
	neck.rotation_degrees = Vector3(-58, 0, 0)  # lean the neck forward to the head
	_upper.add_child(neck)

	var head := _part(SphereMesh.new(), skin, Vector3(0, 0.55, -0.44))
	(head.mesh as SphereMesh).radius = 0.115
	(head.mesh as SphereMesh).height = 0.25
	_upper.add_child(head)

	# The Champion's signature head: a flat cycling cap (terracotta crown + a
	# forward peak) instead of a helmet, and a long pointy nose poking forward.
	var cap := _part(CylinderMesh.new(), accent, Vector3(0, 0.635, -0.43))
	(cap.mesh as CylinderMesh).height = 0.05
	(cap.mesh as CylinderMesh).top_radius = 0.11
	(cap.mesh as CylinderMesh).bottom_radius = 0.125
	_upper.add_child(cap)

	var peak := _part(BoxMesh.new(), accent, Vector3(0, 0.615, -0.56))
	(peak.mesh as BoxMesh).size = Vector3(0.17, 0.02, 0.14)
	_upper.add_child(peak)

	var nose := _part(CylinderMesh.new(), skin, Vector3(0, 0.545, -0.56))
	(nose.mesh as CylinderMesh).top_radius = 0.0
	(nose.mesh as CylinderMesh).bottom_radius = 0.04
	(nose.mesh as CylinderMesh).height = 0.17
	nose.rotation_degrees = Vector3(-90, 0, 0)  # tip points forward (-Z)
	_upper.add_child(nose)

	var arm_mesh := CapsuleMesh.new()
	arm_mesh.radius = 0.055
	arm_mesh.height = 0.55
	for x_off in [-0.16, 0.16]:
		var arm := _part(arm_mesh, jersey, Vector3(x_off, 0.23, -0.40))
		arm.rotation_degrees = Vector3(-60.0, 0, 0)
		_upper.add_child(arm)

	# --- bike: a clean diamond frame so the side profile reads as a real
	# vintage road bike (open triangles, not one fat tube). Tubes are placed
	# between the joints by _tube(): seat/down/top/head tubes form the main
	# triangle, chain + seat stays the rear, plus the fork.
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Belleville.INK.lerp(Belleville.UMBER, 0.25)  # dark vintage steel
	steel.roughness = 1.0
	var bb := Vector3(0, 0.36, 0.05)            # bottom bracket
	var st_top := Vector3(0, 0.88, 0.14)        # seat tube top
	var ht_top := Vector3(0, 0.86, -0.46)       # head tube top
	var ht_bot := Vector3(0, 0.58, -0.49)       # head tube bottom / fork crown
	var fh := Vector3(0, WHEEL_RADIUS, -0.55)   # front hub
	var rh := Vector3(0, WHEEL_RADIUS, 0.55)    # rear hub
	for seg in [
		[bb, st_top], [bb, ht_bot], [st_top, ht_top], [ht_top, ht_bot],
		[ht_bot, fh], [bb, rh], [st_top, rh],
	]:
		add_child(_tube(seg[0], seg[1], 0.022, steel))

	# Seatpost + saddle.
	add_child(_tube(st_top, Vector3(0, 0.95, 0.155), 0.018, steel))
	var saddle := _part(BoxMesh.new(), bibs, Vector3(0, 0.975, 0.16))
	(saddle.mesh as BoxMesh).size = Vector3(0.10, 0.035, 0.24)
	add_child(saddle)

	# Vintage drop bars: a top grip across, drops hooking down + forward.
	var bar_l := Vector3(-0.17, 0.93, -0.53)
	var bar_r := Vector3(0.17, 0.93, -0.53)
	add_child(_tube(ht_top, Vector3(0, 0.93, -0.53), 0.018, steel))    # stem
	add_child(_tube(bar_l, bar_r, 0.016, bibs))                        # top bar
	add_child(_tube(bar_l, Vector3(-0.17, 0.84, -0.60), 0.016, bibs))  # left drop
	add_child(_tube(bar_r, Vector3(0.17, 0.84, -0.60), 0.016, bibs))   # right drop

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
	thigh_mesh.radius = 0.11  # strong thighs
	thigh_mesh.height = 1.0  # unit length, stretched per frame
	var shin_mesh := CapsuleMesh.new()
	shin_mesh.radius = 0.135  # the Champion's tree-trunk calves — the fattest part
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


func _tube(a: Vector3, b: Vector3, r: float, mat: Material) -> MeshInstance3D:
	# A thin cylinder spanning a→b — for building the bike frame's tubes
	# between joints (same unit-mesh basis trick _stretch uses for the legs).
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = 1.0
	var inst := MeshInstance3D.new()
	inst.mesh = m
	inst.material_override = mat
	var d := b - a
	var l := maxf(d.length(), 0.0001)
	var y := d / l
	var ref_v := Vector3.RIGHT if absf(y.dot(Vector3.RIGHT)) < 0.95 else Vector3.FORWARD
	var x := y.cross(ref_v).normalized()
	var z := x.cross(y)
	inst.basis = Basis(x, y * l, z)
	inst.position = (a + b) * 0.5
	return inst


func _build_wheel(rubber: Material, metal: Material, at: Vector3) -> Node3D:
	var spinner := Node3D.new()
	spinner.position = at
	add_child(spinner)

	# Open ring (torus) not a solid disc — from the side you see through to the
	# spokes (like the 2D wheels), and from behind it's still a thin tyre edge.
	var tire := _part(TorusMesh.new(), rubber, Vector3.ZERO)
	(tire.mesh as TorusMesh).inner_radius = WHEEL_RADIUS - 0.035
	(tire.mesh as TorusMesh).outer_radius = WHEEL_RADIUS
	(tire.mesh as TorusMesh).rings = 24
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
