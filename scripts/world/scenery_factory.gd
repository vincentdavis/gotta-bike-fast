class_name SceneryFactory
extends RefCounted

# Low-poly tree varieties for roadside scenery, replacing the single green
# cone of the POC. Each variety is a two-surface ArrayMesh:
#   surface 0  trunk  — fixed brown material
#   surface 1  foliage — white albedo with vertex_color_use_as_albedo, so a
#               MultiMesh instance color tints ONLY the leaves (per-tree hue
#               variation for free, one draw call per variety).
# All meshes are authored with the trunk base at y = 0 so the scatter code
# just sets origin.y to the local ground height.

const VARIETY_COUNT := 4
enum Variety { PINE, OAK, POPLAR, BUSH }

static var _trunk_mat: StandardMaterial3D
static var _foliage_mat: StandardMaterial3D
static var _mat_belleville := false  # which theme the cached materials are for


static func variety_mesh(variety: int) -> ArrayMesh:
	match variety:
		Variety.PINE: return pine()
		Variety.OAK: return oak()
		Variety.POPLAR: return poplar()
		_: return bush()


static func pine() -> ArrayMesh:
	# Conifer: thin trunk, three stacked cones.
	return _build(
		[_at(_cyl(0.09, 0.12, 0.95), Vector3(0, 0.47, 0))],
		[
			_at(_cone(1.05, 1.35), Vector3(0, 1.30, 0)),
			_at(_cone(0.80, 1.10), Vector3(0, 2.05, 0)),
			_at(_cone(0.52, 0.90), Vector3(0, 2.70, 0)),
		],
	)


static func oak() -> ArrayMesh:
	# Broadleaf: stout trunk, blobby three-sphere canopy.
	return _build(
		[_at(_cyl(0.13, 0.18, 1.15), Vector3(0, 0.57, 0))],
		[
			_at(_sphere(0.85), Vector3(0, 1.85, 0)),
			_at(_sphere(0.62), Vector3(0.52, 1.55, 0.18)),
			_at(_sphere(0.58), Vector3(-0.46, 1.62, -0.24)),
		],
	)


static func poplar() -> ArrayMesh:
	# Tall and narrow: an ellipsoid column of foliage.
	return _build(
		[_at(_cyl(0.07, 0.10, 1.0), Vector3(0, 0.5, 0))],
		[_Part.new(
			_sphere(0.70),
			Transform3D(Basis.from_scale(Vector3(0.62, 2.1, 0.62)), Vector3(0, 1.95, 0)),
		)],
	)


static func bush() -> ArrayMesh:
	# Low shrub: foliage only, no trunk.
	return _build(
		[],
		[
			_at(_sphere(0.46), Vector3(0, 0.40, 0)),
			_at(_sphere(0.34), Vector3(0.34, 0.30, 0.10)),
			_at(_sphere(0.30), Vector3(-0.30, 0.34, -0.12)),
		],
	)


# --- assembly helpers ---
# Parts are (mesh, transform) pairs merged into one surface per material
# group with SurfaceTool.append_from.

class _Part:
	var mesh: Mesh
	var xform: Transform3D
	func _init(m: Mesh, x: Transform3D) -> void:
		mesh = m
		xform = x


static func _at(m: Mesh, pos: Vector3) -> _Part:
	return _Part.new(m, Transform3D(Basis(), pos))


static func _build(trunk_parts: Array, foliage_parts: Array) -> ArrayMesh:
	_ensure_materials()
	var mesh := ArrayMesh.new()
	for group in [[trunk_parts, _trunk_mat], [foliage_parts, _foliage_mat]]:
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
	# Rebuild when the theme changes so a mid-session theme switch repaints the
	# trunks (the Belleville look uses umber bark + matte foliage).
	var bel := Belleville.is_active()
	if _trunk_mat != null and _mat_belleville == bel:
		return
	_mat_belleville = bel
	_trunk_mat = StandardMaterial3D.new()
	_trunk_mat.albedo_color = Belleville.UMBER if bel else Color(0.36, 0.27, 0.18)
	_trunk_mat.roughness = 1.0
	_foliage_mat = StandardMaterial3D.new()
	_foliage_mat.albedo_color = Color.WHITE
	_foliage_mat.vertex_color_use_as_albedo = true  # tinted per-instance
	_foliage_mat.roughness = 1.0 if bel else 0.95


static func _cone(radius: float, height: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.0
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = 10
	return m


static func _cyl(top_r: float, bottom_r: float, height: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top_r
	m.bottom_radius = bottom_r
	m.height = height
	m.radial_segments = 8
	return m


static func _sphere(radius: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = 12
	m.rings = 7
	return m
