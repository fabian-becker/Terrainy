extends "res://addons/terrainy/tests/framework/test_case.gd"

## Chunk layout, mesh LOD, collision always maintained (raycasts hit the composed surface).

func test_chunk_layout_shares_borders() -> void:
	var gen := build(make_generator(100, 100.0))
	var chunks = gen.get_chunk_manager().chunks
	t.check_eq(chunks.size(), 16, "ceil(100 / 32) = 4 per side")
	var a = chunks[Vector2i(0, 0)]
	var b = chunks[Vector2i(1, 0)]
	t.check_eq(a.sample_rect.end.x - 1, b.sample_rect.position.x, "neighbours share the border sample")
	var last = chunks[Vector2i(3, 3)]
	t.check_eq(last.sample_rect.end.x - 1, 100, "last chunk ends on the last sample")

func test_mesh_vertices_follow_the_heightmap() -> void:
	var f := make_field(6.0, Vector2(30, 30))
	var gen := build(make_generator(), [f])
	var chunk = gen.get_chunk_manager().chunks[Vector2i(1, 1)]
	var mesh: ArrayMesh = chunk.mesh_instance.mesh
	t.check(mesh != null, "chunk mesh built")
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	t.check_eq(verts.size(), 33 * 33, "full resolution chunk mesh")
	var corner: Vector3 = chunk.root.transform * verts[0]
	t.check_almost_eq(corner.y, h_at(gen, corner.x, corner.z), "vertex height = composed height")

func test_chunk_resolution_and_lod_reduce_the_mesh_but_not_collision() -> void:
	var gen := build(make_generator(64, 64.0, func(g: TerrainGenerator): g.chunk_resolution = 8))
	var chunk = gen.get_chunk_manager().chunks[Vector2i(0, 0)]
	var verts: PackedVector3Array = chunk.mesh_instance.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	t.check_eq(verts.size(), 9 * 9, "8 mesh cells per chunk")
	t.check(chunk.collision_shape.shape is HeightMapShape3D, "collision shape present")
	t.check_eq((chunk.collision_shape.shape as HeightMapShape3D).map_width, 33, "collision keeps every cell")

func test_collision_shape_matches_the_composed_surface() -> void:
	var f := make_field(8.0, Vector2(40, 40))
	f.domain_falloff = null
	var gen := build(make_generator(), [f])
	for chunk in gen.get_chunk_manager().chunks.values():
		var shape := chunk.collision_shape.shape as HeightMapShape3D
		t.check(shape != null, "heightmap collision on unholed chunk %s" % chunk.key)
		var w: int = shape.map_width
		var data: PackedFloat32Array = shape.map_data
		# Sample (w-1, w-1) of chunk (0,0) is the terrain center.
		var r: Rect2i = chunk.sample_rect
		var worst := 0.0
		for i in [0, w - 1, data.size() - 1, (w / 2) * w + w / 2]:
			var gx: int = r.position.x + i % w
			var gy: int = r.position.y + i / w
			worst = maxf(worst, absf(data[i] - gen.get_final_map().get_at(gx, gy)))
		t.check(worst < 1e-5, "collision heights equal the composed map")
		t.check(chunk.collision_shape.scale.is_equal_approx(Vector3(1, 1, 1)), "1 m cells -> unit scale")
		t.check(chunk.static_body.is_inside_tree(), "collision body in the tree (also at runtime)")

func test_collision_quality_budget_on_holed_chunks() -> void:
	var hole := TerrainHoleNode.new()
	hole.size = Vector3(6, 50, 6)
	var gen := build(make_generator(64, 64.0, func(g: TerrainGenerator): g.collision_quality = TerrainGenerator.CollisionQuality.FAST), [hole])
	var holed = gen.get_chunk_manager().chunk_at_world(Vector2(0.5, 0.5))
	t.check(holed.collision_shape.shape is ConcavePolygonShape3D, "holed chunk uses a trimesh")
	var faces: PackedVector3Array = holed.collision_shape.shape.get_faces()
	t.check(faces.size() / 3 < 2 * 32 * 32, "FAST budget decimates the trimesh")

func test_collision_layers_apply() -> void:
	var gen := build(make_generator(64, 64.0, func(g: TerrainGenerator):
		g.collision_layer = 4
		g.collision_mask = 2))
	var chunk = gen.get_chunk_manager().chunks[Vector2i(0, 0)]
	t.check_eq(chunk.static_body.collision_layer, 4, "layer")
	gen.collision_layer = 8
	t.check_eq(chunk.static_body.collision_layer, 8, "layer change applied")
