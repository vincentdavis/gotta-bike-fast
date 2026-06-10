class_name CameraRig
extends Node3D

# Owns the ride camera and a set of switchable view presets.
#
# The rig is added as a child of the rider node, so every view is defined in
# the rider's local frame and naturally follows the rider's position and
# heading (the rider node is yawed each physics tick; the visual sub-node, not
# this rig, takes the road-grade pitch — so the camera never pitches up on a
# climb unless a preset asks it to).
#
# Switching views just changes the target; the camera eases to the new
# position / orientation / FOV over a few frames instead of snapping, so a
# cycle through the presets reads as a smooth broadcast cut. The Drone Orbit
# preset additionally circles the rider over time.

# Look-at target in the rider's local frame — roughly torso height, so the
# "aim at the rider" presets frame the body rather than the wheels.
const PIVOT := Vector3(0.0, 1.05, 0.0)

# Easing responsiveness (higher = snappier). Frame-rate independent: the
# per-frame weight is rate * delta, clamped to 1.
const MOVE_RATE := 6.0
const ROT_RATE := 8.0
const FOV_RATE := 7.0

# Name of the first-person preset — ride_controller hides the player's own
# visual while it's active so the rider's body doesn't fill the head-cam.
const FIRST_PERSON_NAME := "First Person"


# A single camera preset. When `look_at` is true (or `orbit_deg_s` is
# non-zero) the orientation is computed by aiming at PIVOT from `pos` using
# `up` as the up hint; otherwise the explicit `euler_deg` orientation is used.
class View:
	var name: String
	var pos: Vector3
	var fov: float
	var euler_deg: Vector3
	var look_at: bool
	var up: Vector3
	var orbit_deg_s: float

	func _init(
		p_name: String,
		p_pos: Vector3,
		p_fov: float,
		p_euler_deg := Vector3.ZERO,
		p_look_at := false,
		p_up := Vector3.UP,
		p_orbit_deg_s := 0.0,
	) -> void:
		name = p_name
		pos = p_pos
		fov = p_fov
		euler_deg = p_euler_deg
		look_at = p_look_at
		up = p_up
		orbit_deg_s = p_orbit_deg_s


var camera: Camera3D
var _views: Array = []
var _index: int = 0
var _orbit_angle: float = 0.0


func _init() -> void:
	name = "CameraRig"
	# Rider faces local -Z, so "behind" is +Z and "right" is +X.
	#
	# FOV values are VERTICAL degrees — Godot's Camera3D defaults to
	# keep_aspect = KEEP_HEIGHT, so `fov` is the vertical angle and the
	# horizontal angle widens with the window's aspect (at 16:9 a 50° vertical
	# FOV is ~80° horizontal). Tuned as verticals on purpose: feeding
	# horizontal-style numbers (90°+) here would fisheye-bow the road and, in
	# first person, invite motion sickness.
	_views = [
		# 1 — Chase: the default broadcast follow. Rider in the lower third,
		# road ahead filling the frame (~83° horizontal at 16:9).
		View.new("Chase", Vector3(0.0, 2.0, 5.0), 52.0, Vector3(-12.0, 0.0, 0.0)),
		# 2 — Chase Wide: same seat, wider FOV. More landscape and a stronger
		# sense of speed without bowing the road (~97° horizontal).
		View.new("Chase Wide", Vector3(0.0, 2.2, 5.4), 64.0, Vector3(-12.0, 0.0, 0.0)),
		# 3 — Chase Close: pulled in and narrowed — a telephoto look that
		# compresses the scene and keeps the rider large (~63° horizontal).
		View.new("Chase Close", Vector3(0.0, 1.85, 3.4), 38.0, Vector3(-9.0, 0.0, 0.0)),
		# 4 — First Person: eye at head height just ahead of the torso, looking
		# down the road. The rider's own body is hidden while the eye is inside
		# it (see eye_inside_rider). ~91° horizontal — wide but comfortable.
		View.new(FIRST_PERSON_NAME, Vector3(0.0, 1.45, -0.30), 58.0, Vector3(-5.0, 0.0, 0.0)),
		# 5 — Side: the rider's right profile. Reads the road grade clearly.
		View.new("Side", Vector3(6.0, 1.6, 0.0), 50.0, Vector3.ZERO, true),
		# 6 — Top-Down: map-like overhead. Up vector is the rider's forward
		# (-Z) so "forward" stays at the top of the screen.
		View.new("Top-Down", Vector3(0.0, 24.0, 0.0), 55.0, Vector3.ZERO, true, Vector3(0.0, 0.0, -1.0)),
		# 7 — Hero: ahead of the rider looking back — the classic moto/drone
		# shot that frames the rider's front against the road behind. (A beauty
		# angle: the way you're heading is off-screen, so it's not for steering.)
		View.new("Hero", Vector3(0.0, 1.9, -6.5), 48.0, Vector3.ZERO, true),
		# 8 — Cinematic: high, far, off-axis, slightly long lens. Shows off
		# terrain and elevation (~70° horizontal).
		View.new("Cinematic", Vector3(3.5, 5.5, 10.0), 42.0, Vector3.ZERO, true),
		# 9 — Drone Orbit: a slow circle around the rider, always aimed in.
		View.new("Drone Orbit", Vector3(0.0, 3.5, 7.0), 50.0, Vector3.ZERO, true, Vector3.UP, 16.0),
	]


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "RideCamera"
	add_child(camera)
	camera.current = true
	# Place the camera exactly on the first preset for frame one — no ease-in
	# from the origin.
	_apply_immediate(_views[_index])


func _process(delta: float) -> void:
	if camera == null:
		return
	var v: View = _views[_index]

	var target_pos := v.pos
	var target_basis: Basis
	if v.orbit_deg_s != 0.0:
		_orbit_angle += deg_to_rad(v.orbit_deg_s) * delta
		var radius := Vector2(v.pos.x, v.pos.z).length()
		if radius < 0.001:
			radius = 7.0
		target_pos = Vector3(sin(_orbit_angle) * radius, v.pos.y, cos(_orbit_angle) * radius)
		target_basis = _aim_basis(target_pos, v.up)
	elif v.look_at:
		target_basis = _aim_basis(target_pos, v.up)
	else:
		target_basis = Basis.from_euler(_euler_rad(v.euler_deg))

	# Frame-rate-independent easing toward the target pose + FOV.
	camera.position = camera.position.lerp(target_pos, clampf(MOVE_RATE * delta, 0.0, 1.0))
	var cur := camera.quaternion
	camera.quaternion = cur.slerp(
		Quaternion(target_basis).normalized(), clampf(ROT_RATE * delta, 0.0, 1.0)
	)
	camera.fov = lerpf(camera.fov, v.fov, clampf(FOV_RATE * delta, 0.0, 1.0))


# --- Public API (driven by ride_controller input) ---

func select(i: int) -> String:
	if i < 0 or i >= _views.size():
		return ""
	_index = i
	# Reset the orbit so it always starts directly behind the rider rather
	# than wherever the angle happened to be left from a prior visit.
	if (_views[_index] as View).orbit_deg_s != 0.0:
		_orbit_angle = 0.0
	return (_views[_index] as View).name


func cycle_next() -> String:
	return select((_index + 1) % _views.size())


func cycle_prev() -> String:
	return select((_index - 1 + _views.size()) % _views.size())


func current_name() -> String:
	return (_views[_index] as View).name


func current_index() -> int:
	return _index


func view_count() -> int:
	return _views.size()


func set_initial_view(i: int) -> void:
	# Seed the starting view BEFORE the rig enters the tree, so _ready applies
	# it immediately (no ease-in from a different default). Call between
	# CameraRig.new() and add_child().
	if i >= 0 and i < _views.size():
		_index = i
		if (_views[_index] as View).orbit_deg_s != 0.0:
			_orbit_angle = 0.0


func eye_inside_rider() -> bool:
	# True when the camera sits within the rider's body envelope — i.e. the
	# First Person eye (and the brief slice of any transition that passes
	# through the body). The caller hides the rider visual while this holds so
	# the body never fills the head-cam, and — because it tracks the live eased
	# position rather than the target preset — it stays hidden through the
	# whole sweep out of First Person, not just at the endpoints.
	if camera == null:
		return false
	var p := camera.position
	return p.y < 1.9 and absf(p.x) < 0.7 and p.z > -0.7 and p.z < 0.9


# --- Internals ---

func _apply_immediate(v: View) -> void:
	camera.position = v.pos
	if v.look_at or v.orbit_deg_s != 0.0:
		camera.quaternion = Quaternion(_aim_basis(v.pos, v.up)).normalized()
	else:
		camera.quaternion = Quaternion(Basis.from_euler(_euler_rad(v.euler_deg))).normalized()
	camera.fov = v.fov


func _aim_basis(from: Vector3, up: Vector3) -> Basis:
	# Orientation that looks from `from` toward PIVOT (both in the rig's local
	# frame). Guard the degenerate zero-length direction.
	var dir := PIVOT - from
	if dir.length_squared() < 1e-8:
		return Basis.IDENTITY
	return Basis.looking_at(dir, up)


func _euler_rad(deg: Vector3) -> Vector3:
	return Vector3(deg_to_rad(deg.x), deg_to_rad(deg.y), deg_to_rad(deg.z))
