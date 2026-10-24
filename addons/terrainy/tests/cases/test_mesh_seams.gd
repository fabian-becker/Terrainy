extends "res://addons/terrainy/tests/framework/test_case.gd"

## Chunk-border shading: neighbouring chunks must agree on the normal at their shared samples.
##
## The mesh generator used to take one-sided differences at every chunk edge, so the same world
## position had two different normals depending on which chunk drew it - a shading line along every
## chunk border (and along every LOD border, where the normals came from the reduced heightmap).

## A smooth dome with high-frequency relief: strong curvature everywhere, so a one-sided
## difference at a chunk border differs noticeably from the neighbour's.
func _seam_generator() -> TerrainGenerator:
	var f := make_field(12.0, Vector2(64, 64))
	var relief := TerrainReliefSource.new()
	relief.weight = 6.0
	relief.noise.frequency = 0.12
	relief.noise_seed = 7
	f.relief_layers = [relief] as Array[TerrainReliefSource]
	return build(make_generator(64, 64.0), [f])

## Collect the normals each chunk produced per world XZ sample.
func _normals_by_world_position(gen: TerrainGenerator) -> Dictionary:
	var out := {}
	for chunk in gen.get_chunk_manager().chunks.values():
		var mesh: ArrayMesh = chunk.mesh_instance.mesh
		if mesh == null:
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var origin: Vector3 = chunk.root.position
		for i in vertices.size():
			var world: Vector3 = origin + vertices[i]
			var key := Vector2i(roundi(world.x * 1000.0), roundi(world.z * 1000.0))
			if not out.has(key):
				out[key] = []
			out[key].append(normals[i])
	return out

func test_chunk_border_normals_match() -> void:
	var gen := _seam_generator()
	var by_position := _normals_by_world_position(gen)
	var shared := 0
	var worst := 0.0
	for key in by_position:
		var normals: Array = by_position[key]
		if normals.size() < 2:
			continue
		shared += 1
		for i in range(1, normals.size()):
			worst = maxf(worst, normals[0].angle_to(normals[i]))
	t.check(shared > 0, "chunks share border samples (%d positions)" % shared)
	t.check(worst < 0.01, "neighbouring chunks agree at the seam (max %.4f rad)" % worst)

func test_lod_meshes_keep_the_world_normals() -> void:
	# A chunk that drops to a coarser LOD still shades from the full-resolution heightmap, so its
	# normals are the LOD0 ones - the reduced grid must not make the lighting pop.
	var gen := _seam_generator()
	var fine := _normals_by_world_position(gen)
	var chunk = gen.get_chunk_manager().chunks.values()[0]
	chunk.lod_level = 1
	gen.get_chunk_manager().mark_dirty(chunk)
	gen.rebuild_now()
	var coarse := _normals_by_world_position(gen)
	var compared := 0
	var worst := 0.0
	for key in coarse:
		if not fine.has(key):
			continue
		compared += 1
		worst = maxf(worst, fine[key][0].angle_to(coarse[key][0]))
	t.check(compared > 0, "LOD0 and LOD1 meshes share samples (%d)" % compared)
	t.check(worst < 0.01, "LOD normals match LOD0 at the same world positions (max %.4f rad)" % worst)
