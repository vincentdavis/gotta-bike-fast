class_name BuildingFactory
extends RefCounted

# Low-poly Belleville buildings for towns along the course. Follows the
# SceneryFactory conventions, extended to a three-surface ArrayMesh:
#   surface 0  walls — white albedo with vertex_color_use_as_albedo, so a
#              MultiMesh instance color tints the facade (per-house paper /
#              ochre / terracotta variation for free)
#   surface 1  roof + chimney/spire — fixed weathered-tile material
#   surface 2  windows + doors — fixed dark ink material
# One MultiMesh per variety = three draw calls per variety in the scene.
# All meshes are authored with the foundation at y = 0, long axis along Z,
# and the "front" (door + most windows) on the +X face — placement yaws the
# instance so +X looks at the road.

const VARIETY_COUNT := 5
enum Variety { COTTAGE, TOWNHOUSE, FARMHOUSE, CHURCH, BARN }

static var _wall_mat: StandardMaterial3D
static var _roof_mat: StandardMaterial3D
static var _trim_mat: StandardMaterial3D


static func variety_mesh(variety: int) -> ArrayMesh:
	match variety:
		Variety.COTTAGE: return cottage()
		Variety.TOWNHOUSE: return townhouse()
		Variety.FARMHOUSE: return farmhouse()
		Variety.CHURCH: return church()
		_: return barn()


static func cottage() -> ArrayMesh:
	# One-story village house: snug box, gable roof, hearth chimney.
	return _build(
		[_at(_box(4.2, 3.0, 5.2), Vector3(0, 1.5, 0))],
		[
			_at(_prism(4.8, 1.5, 5.8), Vector3(0, 3.75, 0)),
			_at(_box(0.5, 1.3, 0.5), Vector3(0.9, 4.3, 1.4)),
		],
		[
			_at(_box(0.06, 2.0, 1.0), Vector3(2.13, 1.0, 1.4)),   # door
			_at(_box(0.06, 0.9, 0.8), Vector3(2.13, 1.9, -1.2)),
			_at(_box(0.06, 0.9, 0.8), Vector3(2.13, 1.9, 0.1)),
			_at(_box(0.06, 0.9, 0.8), Vector3(-2.13, 1.9, 0.0)),
		],
	)


static func townhouse() -> ArrayMesh:
	# Narrow three-story row house — the leaning silhouette of Belleville,
	# up close. The lean itself comes from the placement transform.
	var trim: Array = [_at(_box(0.06, 2.0, 0.95), Vector3(2.03, 1.0, 0.9))]  # door
	for floor_y in [3.1, 5.1]:
		for z in [-1.4, 0.0, 1.4]:
			trim.append(_at(_box(0.06, 1.0, 0.75), Vector3(2.03, floor_y, z)))
	trim.append(_at(_box(0.06, 1.0, 0.75), Vector3(-2.03, 4.1, 0.0)))
	return _build(
		[_at(_box(4.0, 6.5, 4.6), Vector3(0, 3.25, 0))],
		[
			_at(_prism(4.5, 1.6, 5.1), Vector3(0, 7.3, 0)),
			_at(_box(0.5, 1.4, 0.5), Vector3(0, 8.2, 1.8)),
		],
		trim,
	)


static func farmhouse() -> ArrayMesh:
	# Long low farm dwelling with a deep roof.
	return _build(
		[_at(_box(4.6, 3.2, 7.5), Vector3(0, 1.6, 0))],
		[
			_at(_prism(5.2, 1.7, 8.1), Vector3(0, 4.05, 0)),
			_at(_box(0.55, 1.5, 0.55), Vector3(0, 4.9, -2.5)),
		],
		[
			_at(_box(0.06, 2.0, 1.0), Vector3(2.33, 1.0, 1.5)),   # door
			_at(_box(0.06, 0.9, 0.8), Vector3(2.33, 2.0, -2.6)),
			_at(_box(0.06, 0.9, 0.8), Vector3(2.33, 2.0, -0.6)),
			_at(_box(0.06, 0.9, 0.8), Vector3(2.33, 2.0, 3.0)),
		],
	)


static func church() -> ArrayMesh:
	# Village centerpiece: nave, steep roof, square bell tower + spire.
	# The tower fronts the +Z end; its door faces +Z (the square).
	var trim: Array = [_at(_box(0.06, 2.6, 1.4), Vector3(0, 1.3, 6.83))]  # arch door
	for z in [-3.0, -1.0, 1.0, 3.0]:
		trim.append(_at(_box(0.06, 2.2, 0.6), Vector3(2.53, 3.0, z)))
	trim.append(_at(_box(0.06, 1.2, 0.6), Vector3(1.33, 6.8, 5.5)))  # belfry
	return _build(
		[
			_at(_box(5.0, 5.0, 9.0), Vector3(0, 2.5, 0)),
			_at(_box(2.6, 8.5, 2.6), Vector3(0, 4.25, 5.5)),
		],
		[
			_at(_prism(5.6, 2.4, 9.8), Vector3(0, 6.2, 0)),
			_at(_cone4(1.9, 3.0), Vector3(0, 10.0, 5.5)),
		],
		trim,
	)


static func barn() -> ArrayMesh:
	# Big working barn: tall doors, one hayloft window, no frills.
	return _build(
		[_at(_box(6.0, 4.5, 9.0), Vector3(0, 2.25, 0))],
		[_at(_prism(6.8, 2.6, 9.8), Vector3(0, 5.8, 0))],
		[
			_at(_box(0.1, 3.4, 2.6), Vector3(3.05, 1.7, 0.0)),    # cart doors
			_at(_box(0.06, 1.0, 1.0), Vector3(3.05, 4.6, 0.0)),   # hayloft
		],
	)


# --- assembly helpers (SceneryFactory's pattern, three material groups) ---

class _Part:
	var mesh: Mesh
	var xform: Transform3D
	func _init(m: Mesh, x: Transform3D) -> void:
		mesh = m
		xform = x


static func _at(m: Mesh, pos: Vector3) -> _Part:
	return _Part.new(m, Transform3D(Basis(), pos))


static func _build(wall_parts: Array, roof_parts: Array, trim_parts: Array) -> ArrayMesh:
	_ensure_materials()
	var mesh := ArrayMesh.new()
	for group in [
		[wall_parts, _wall_mat], [roof_parts, _roof_mat], [trim_parts, _trim_mat]
	]:
		var parts: Array = group[0]
		if parts.is_empty():
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for p in parts:
			st.append_from(p.mesh, 0, p.xform)
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, group[1])
	return mesh


static func _ensure_materials() -> void:
	if _wall_mat != null:
		return
	_wall_mat = StandardMaterial3D.new()
	_wall_mat.albedo_color = Color.WHITE
	_wall_mat.vertex_color_use_as_albedo = true  # facade tinted per-instance
	_wall_mat.roughness = 1.0
	_roof_mat = StandardMaterial3D.new()
	_roof_mat.albedo_color = Belleville.TERRACOTTA.darkened(0.28)  # weathered tile
	_roof_mat.roughness = 1.0
	_trim_mat = StandardMaterial3D.new()
	_trim_mat.albedo_color = Belleville.INK.lightened(0.08)  # windows/doors
	_trim_mat.roughness = 1.0


static func _box(sx: float, sy: float, sz: float) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = Vector3(sx, sy, sz)
	return m


static func _prism(sx: float, sy: float, sz: float) -> PrismMesh:
	# Gable roof: triangular cross-section in XY, ridge running along Z.
	var m := PrismMesh.new()
	m.size = Vector3(sx, sy, sz)
	m.left_to_right = 0.5
	return m


static func _cone4(radius: float, height: float) -> CylinderMesh:
	# Four-sided spire, same trick as the backdrop mountains.
	var m := CylinderMesh.new()
	m.top_radius = 0.0
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = 4
	return m
