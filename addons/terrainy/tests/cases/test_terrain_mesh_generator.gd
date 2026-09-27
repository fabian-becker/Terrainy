extends "res://addons/terrainy/tests/framework/test_case.gd"

## Tests for the analytic tangent frame of TerrainMeshGenerator.
##
## SurfaceTool.create_from() + generate_tangents() + commit() used to supply the tangents and
## dominated the mesh build cost (roughly 80% of it). The tangents are now derived from the
## same slope as the normals, so the analytic value of a plane is known exactly and pinned
## here - including on the outer ring of vertices, where a one-sided difference used to be
## scaled by the central-difference factor by mistake.

const SIZE := Vector2i(33, 33)
const TERRAIN_SIZE := Vector2(128.0, 128.0)
const RAMP_HEIGHT := 100.0
const TOLERANCE := 0.0002

func _generate(hole_mask: Image = null) -> ArrayMesh:
	return TerrainMeshGenerator.generate_from_heightmap(
		make_ramp_image(SIZE, RAMP_HEIGHT), TERRAIN_SIZE, hole_mask
	)

func _arrays(mesh: ArrayMesh) -> Array:
	t.check_eq(mesh.get_surface_count(), 1, "the mesh has exactly one surface")
	return mesh.surface_get_arrays(0)

## The mesh is split in two so that the CPU-bound half can run on a worker thread: the arrays
## are built without touching the renderer, and mesh_from_arrays() turns them into the
## ArrayMesh on the main thread. Both halves must stay equivalent to the one-shot path.
func test_surface_arrays_and_mesh_from_arrays_match_generate_from_heightmap() -> void:
	var heightmap := make_ramp_image(SIZE, RAMP_HEIGHT)
	var single_shot := _arrays(TerrainMeshGenerator.generate_from_heightmap(heightmap, TERRAIN_SIZE))
	var split := TerrainMeshGenerator.generate_surface_arrays(heightmap, TERRAIN_SIZE)
	t.check_eq(
		split[Mesh.ARRAY_VERTEX], single_shot[Mesh.ARRAY_VERTEX],
		"generate_surface_arrays() produces the same vertices"
	)
	t.check_eq(
		split[Mesh.ARRAY_INDEX], single_shot[Mesh.ARRAY_INDEX],
		"generate_surface_arrays() produces the same indices"
	)
	# ArrayMesh stores normals and tangents with octahedral compression, so the round trip is
	# lossy for those two: compare what the renderer would actually see against the analytic
	# value with a tolerance of one compressed step instead of demanding bit equality.
	var split_tangents: PackedFloat32Array = split[Mesh.ARRAY_TANGENT]
	var stored_tangents: PackedFloat32Array = single_shot[Mesh.ARRAY_TANGENT]
	t.check_eq(
		split_tangents.size(), stored_tangents.size(),
		"the mesh keeps one tangent per vertex"
	)
	var worst_tangent: float = 0.0
	for i in split_tangents.size():
		worst_tangent = maxf(worst_tangent, absf(split_tangents[i] - stored_tangents[i]))
	t.check_almost_eq(
		worst_tangent, 0.0,
		"the stored tangents match the generated ones", 0.01
	)
	var rebuilt := TerrainMeshGenerator.mesh_from_arrays(split)
	t.check_eq(rebuilt.get_surface_count(), 1, "mesh_from_arrays() creates exactly one surface")
	t.check_eq(
		rebuilt.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], single_shot[Mesh.ARRAY_VERTEX],
		"mesh_from_arrays() round-trips the arrays unchanged"
	)

## h = RAMP_HEIGHT * 0.5 * (u + v) is a plane, so dh/dx and dh/dz are constant everywhere.
func _plane_slope() -> float:
	return RAMP_HEIGHT * 0.5 / TERRAIN_SIZE.x

func _tangent_at(tangents: PackedFloat32Array, vertex: int) -> Vector3:
	return Vector3(tangents[vertex * 4], tangents[vertex * 4 + 1], tangents[vertex * 4 + 2])

func test_tangents_match_the_analytic_slope_of_a_plane() -> void:
	var arrays := _arrays(_generate())
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var expected := Vector3(1.0, _plane_slope(), 0.0).normalized()
	var worst: float = 0.0
	for i in vertices.size():
		worst = maxf(worst, _tangent_at(tangents, i).distance_to(expected))
	t.check_almost_eq(worst, 0.0, "every vertex tangent is normalize(1, dh/dx, 0)", TOLERANCE)

func test_tangents_are_unit_length_and_right_handed() -> void:
	var arrays := _arrays(_generate())
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	t.check_eq(
		tangents.size(), vertices.size() * 4,
		"the tangent array holds four floats per vertex"
	)
	var worst_length_error: float = 0.0
	var worst_handedness_error: float = 0.0
	for i in vertices.size():
		worst_length_error = maxf(worst_length_error, absf(_tangent_at(tangents, i).length() - 1.0))
		worst_handedness_error = maxf(worst_handedness_error, absf(tangents[i * 4 + 3] - 1.0))
	t.check_almost_eq(worst_length_error, 0.0, "tangents are unit length", TOLERANCE)
	t.check_almost_eq(worst_handedness_error, 0.0, "handedness (w) is +1 for a heightfield", TOLERANCE)

func test_tangents_are_orthogonal_to_the_normals() -> void:
	var arrays := _arrays(_generate())
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var worst: float = 0.0
	for i in normals.size():
		worst = maxf(worst, absf(_tangent_at(tangents, i).dot(normals[i])))
	t.check_almost_eq(worst, 0.0, "T dot N is zero (the frame is built from the same slope)", TOLERANCE)

func test_normals_match_the_analytic_slope_on_the_outer_ring() -> void:
	var arrays := _arrays(_generate())
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var slope := _plane_slope()
	var expected := Vector3(-slope, 1.0, -slope).normalized()
	var worst: float = 0.0
	for i in normals.size():
		worst = maxf(worst, normals[i].distance_to(expected))
	t.check_almost_eq(
		worst, 0.0,
		"border normals use a full one-sided difference (they used to be halved)",
		TOLERANCE
	)

func test_flat_terrain_has_up_normals_and_flat_tangents() -> void:
	var mesh := TerrainMeshGenerator.generate_from_heightmap(
		make_flat_image(SIZE, 5.0), TERRAIN_SIZE
	)
	var arrays := _arrays(mesh)
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var worst_tangent: float = 0.0
	var worst_normal: float = 0.0
	for i in normals.size():
		worst_tangent = maxf(worst_tangent, _tangent_at(tangents, i).distance_to(Vector3.RIGHT))
		worst_normal = maxf(worst_normal, normals[i].distance_to(Vector3.UP))
	t.check_almost_eq(worst_tangent, 0.0, "a flat terrain tangents along +X", TOLERANCE)
	t.check_almost_eq(worst_normal, 0.0, "a flat terrain points straight up", TOLERANCE)

func test_hole_mesh_keeps_the_tangent_frame_consistent() -> void:
	var hole_mask := make_flat_image(SIZE, 0.0)
	for y in range(12, 21):
		for x in range(12, 21):
			hole_mask.set_pixel(x, y, Color(1.0, 0.0, 0.0, 1.0))
	var arrays := _arrays(_generate(hole_mask))
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	t.check(
		vertices.size() > SIZE.x * SIZE.y,
		"the hole adds interpolated boundary vertices (%d vs %d)" % [
			vertices.size(), SIZE.x * SIZE.y
		]
	)
	t.check_eq(
		tangents.size(), vertices.size() * 4,
		"boundary vertices carry tangents too"
	)
	var expected := Vector3(1.0, _plane_slope(), 0.0).normalized()
	var worst: float = 0.0
	var worst_normal: float = 0.0
	var worst_handedness: float = 0.0
	for i in vertices.size():
		worst = maxf(worst, _tangent_at(tangents, i).distance_to(expected))
		worst_normal = maxf(worst_normal, absf(_tangent_at(tangents, i).dot(normals[i])))
		worst_handedness = maxf(worst_handedness, absf(tangents[i * 4 + 3] - 1.0))
	t.check_almost_eq(worst, 0.0, "grid and boundary tangents equal the analytic tangent", TOLERANCE)
	t.check_almost_eq(worst_normal, 0.0, "boundary tangents stay orthogonal to the normals", TOLERANCE)
	t.check_almost_eq(worst_handedness, 0.0, "boundary handedness stays +1", TOLERANCE)

func test_hole_mesh_omits_the_triangles_inside_the_hole() -> void:
	var hole_mask := make_flat_image(SIZE, 0.0)
	for y in range(12, 21):
		for x in range(12, 21):
			hole_mask.set_pixel(x, y, Color(1.0, 0.0, 0.0, 1.0))
	var solid: PackedInt32Array = _arrays(_generate())[Mesh.ARRAY_INDEX]
	var holed: PackedInt32Array = _arrays(_generate(hole_mask))[Mesh.ARRAY_INDEX]
	t.check(
		holed.size() < solid.size(),
		"the 9x9 hole removes triangles (%d vs %d)" % [holed.size(), solid.size()]
	)
	t.check_eq(holed.size() % 3, 0, "the index buffer stays a multiple of three")
