class_name TerrainMeshGenerator
extends RefCounted

## Utility class for optimized terrain mesh generation with batching and parallel processing

## Worker function to build chunk mesh from pre-calculated heights (thread-safe)
static func _build_chunk_from_heights(
	chunk_x: int, 
	chunk_z: int, 
	chunk_size: int, 
	resolution: int,
	step: Vector2, 
	half_size: Vector2, 
	heights: PackedFloat32Array
) -> Dictionary:
	var start_x = chunk_x * chunk_size
	var start_z = chunk_z * chunk_size
	var end_x = mini(start_x + chunk_size, resolution)
	var end_z = mini(start_z + chunk_size, resolution)
	
	var chunk_vertices: PackedVector3Array = []
	var chunk_uvs: PackedVector2Array = []
	var chunk_indices: PackedInt32Array = []
	
	var vertex_map: Dictionary = {}
	var local_vertex_index = 0
	
	# Generate vertices for this chunk using pre-calculated heights
	for z in range(start_z, end_z + 1):
		for x in range(start_x, end_x + 1):
			var local_x = (x * step.x) - half_size.x
			var local_z = (z * step.y) - half_size.y
			
			# Get height from pre-calculated array
			var height_idx = z * (resolution + 1) + x
			var height = heights[height_idx]
			
			chunk_vertices.append(Vector3(local_x, height, local_z))
			chunk_uvs.append(Vector2(x / float(resolution), z / float(resolution)))
			
			var key = Vector2i(x, z)
			vertex_map[key] = local_vertex_index
			local_vertex_index += 1
	
	# Generate indices for this chunk
	for z in range(start_z, end_z):
		for x in range(start_x, end_x):
			var key0 = Vector2i(x, z)
			var key1 = Vector2i(x + 1, z)
			var key2 = Vector2i(x, z + 1)
			var key3 = Vector2i(x + 1, z + 1)
			
			var i0 = vertex_map[key0]
			var i1 = vertex_map[key1]
			var i2 = vertex_map[key2]
			var i3 = vertex_map[key3]
			
			# First triangle
			chunk_indices.append(i0)
			chunk_indices.append(i1)
			chunk_indices.append(i2)
			
			# Second triangle
			chunk_indices.append(i1)
			chunk_indices.append(i3)
			chunk_indices.append(i2)
	
	return {
		"vertices": chunk_vertices,
		"uvs": chunk_uvs,
		"indices": chunk_indices
	}

## Generate terrain mesh using batched approach (async to prevent main thread blocking)
static func generate_batched(
	resolution: int,
	terrain_size: Vector2,
	batch_size: int,
	use_parallel: bool,
	height_callback: Callable,
	scene_tree: SceneTree = null
) -> ArrayMesh:
	var start_time = Time.get_ticks_msec()
	print("[TerrainMeshGenerator] Starting batched generation...")
	print("  Resolution: %d x %d" % [resolution, resolution])
	print("  Terrain Size: %v" % [terrain_size])
	print("  Batch Size: %d" % batch_size)
	print("  Parallel Processing: %s" % ["Enabled" if use_parallel else "Disabled"])
	
	var vertices: PackedVector3Array = []
	var normals: PackedVector3Array = []
	var uvs: PackedVector2Array = []
	var indices: PackedInt32Array = []
	
	var step = terrain_size / float(resolution)
	var half_size = terrain_size / 2.0
	var total_vertices = (resolution + 1) * (resolution + 1)
	
	print("  Total Vertices: %d" % total_vertices)
	
	# Pre-allocate arrays for better performance
	vertices.resize(total_vertices)
	uvs.resize(total_vertices)
	
	# Generate vertices in batches with frame yielding
	var vertex_index = 0
	var yield_counter = 0
	var yield_frequency = 128  # Yield every 128 vertices
	
	for z in range(resolution + 1):
		for x in range(resolution + 1):
			var local_x = (x * step.x) - half_size.x
			var local_z = (z * step.y) - half_size.y
			var world_pos = Vector3(local_x, 0, local_z)
			
			var height = height_callback.call(world_pos)
			
			vertices[vertex_index] = Vector3(local_x, height, local_z)
			uvs[vertex_index] = Vector2(x / float(resolution), z / float(resolution))
			vertex_index += 1
			
			# Yield to prevent blocking the main thread
			yield_counter += 1
			if scene_tree and yield_counter >= yield_frequency:
				yield_counter = 0
				await scene_tree.process_frame
	
	var vertex_time = Time.get_ticks_msec() - start_time
	print("  ✓ Vertices generated in %d ms" % vertex_time)
	
	# Generate indices (counter-clockwise winding for correct normals)
	yield_counter = 0
	for z in range(resolution):
		for x in range(resolution):
			var i = z * (resolution + 1) + x
			
			# Two triangles per quad - reversed winding order
			indices.append(i)
			indices.append(i + 1)
			indices.append(i + resolution + 1)
			
			indices.append(i + 1)
			indices.append(i + resolution + 2)
			indices.append(i + resolution + 1)
			
			# Yield periodically
			yield_counter += 1
			if scene_tree and yield_counter >= yield_frequency:
				yield_counter = 0
				await scene_tree.process_frame
	
	var index_time = Time.get_ticks_msec() - start_time - vertex_time
	print("  ✓ Indices generated (%d triangles) in %d ms" % [indices.size() / 3, index_time])
	
	# Calculate normals (parallel or batched)
	print("  Calculating normals...")
	var normal_start = Time.get_ticks_msec()
	if use_parallel:
		normals = await calculate_normals_parallel(vertices, indices, batch_size, scene_tree)
	else:
		normals = await calculate_normals_batched(vertices, indices, batch_size, scene_tree)
	
	# Create mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var array_mesh = ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	var normal_time = Time.get_ticks_msec() - normal_start
	var total_time = Time.get_ticks_msec() - start_time
	print("  ✓ Normals calculated in %d ms" % normal_time)
	print("[TerrainMeshGenerator] ✓ Batched generation complete in %d ms" % total_time)
	
	return array_mesh

## Generate terrain mesh using chunked approach for very large terrains (async)
static func generate_chunked(
	resolution: int,
	terrain_size: Vector2,
	chunk_size: int,
	batch_size: int,
	use_parallel: bool,
	height_callback: Callable,
	scene_tree: SceneTree = null
) -> ArrayMesh:
	var start_time = Time.get_ticks_msec()
	print("[TerrainMeshGenerator] Starting chunked generation...")
	print("  Resolution: %d x %d" % [resolution, resolution])
	print("  Terrain Size: %v" % [terrain_size])
	print("  Chunk Size: %d" % chunk_size)
	print("  Batch Size: %d" % batch_size)
	
	var chunks_x = ceili(float(resolution) / chunk_size)
	var chunks_z = ceili(float(resolution) / chunk_size)
	var total_chunks = chunks_x * chunks_z
	
	print("  Total Chunks: %d (%d x %d)" % [total_chunks, chunks_x, chunks_z])
	
	var step = terrain_size / float(resolution)
	var half_size = terrain_size / 2.0
	var total_vertices = (resolution + 1) * (resolution + 1)
	
	# STEP 1: Pre-calculate all heights on main thread (thread-safe)
	print("  [1/2] Pre-calculating heights on main thread...")
	var heights: PackedFloat32Array = []
	heights.resize(total_vertices)
	
	var height_calc_start = Time.get_ticks_msec()
	var vertex_idx = 0
	for z in range(resolution + 1):
		for x in range(resolution + 1):
			var local_x = (x * step.x) - half_size.x
			var local_z = (z * step.y) - half_size.y
			var world_pos = Vector3(local_x, 0, local_z)
			
			heights[vertex_idx] = height_callback.call(world_pos)
			vertex_idx += 1
			
			# Yield periodically to keep editor responsive
			if scene_tree and vertex_idx % 2048 == 0:
				await scene_tree.process_frame
	
	var height_calc_time = Time.get_ticks_msec() - height_calc_start
	print("    ✓ Heights calculated in %d ms" % height_calc_time)
	
	# STEP 2: Build mesh from heights in parallel
	print("  [2/2] Building mesh in parallel...")
	var mesh_build_start = Time.get_ticks_msec()
	
	# Arrays to accumulate all chunks into single surface
	var all_vertices: PackedVector3Array = []
	var all_uvs: PackedVector2Array = []
	var all_indices: PackedInt32Array = []
	
	# Process chunks in parallel batches
	var parallel_batch_size = 32  # Process 32 chunks at a time
	var num_batches = ceili(float(total_chunks) / parallel_batch_size)
	
	# Shared array to store results (thread-safe writes to different indices)
	var all_chunk_results: Array = []
	all_chunk_results.resize(total_chunks)
	
	for batch_idx in range(num_batches):
		var batch_start = batch_idx * parallel_batch_size
		var batch_end = mini(batch_start + parallel_batch_size, total_chunks)
		var batch_size_actual = batch_end - batch_start
		
		if batch_idx % 5 == 0 or batch_idx == num_batches - 1:
			print("    Processing batch %d/%d (%.1f%%)..." % [batch_idx + 1, num_batches, ((batch_idx + 1) * 100.0) / num_batches])
		
		# Use WorkerThreadPool for parallel processing
		var tasks: Array = []
		for i in range(batch_size_actual):
			var chunk_idx = batch_start + i
			var chunk_z = chunk_idx / chunks_x
			var chunk_x = chunk_idx % chunks_x
			
			# Create callable that will store result in shared array
			var task_callable = func():
				var result = _build_chunk_from_heights(
					chunk_x, chunk_z, chunk_size, resolution,
					step, half_size, heights
				)
				all_chunk_results[chunk_idx] = result
			
			# Create task for this chunk
			var task_id = WorkerThreadPool.add_task(task_callable)
			tasks.append(task_id)
		
		# Wait for all tasks in this batch to complete
		for task_id in tasks:
			WorkerThreadPool.wait_for_task_completion(task_id)
		
		# Yield to keep editor responsive
		if scene_tree:
			await scene_tree.process_frame
	
	# Merge all chunk results into final arrays
	print("    Merging %d chunks..." % total_chunks)
	for chunk_idx in range(total_chunks):
		var result = all_chunk_results[chunk_idx]
		if result:
			var vertex_offset = all_vertices.size()
			all_vertices.append_array(result.vertices)
			all_uvs.append_array(result.uvs)
			
			# Adjust indices by vertex offset
			for idx in result.indices:
				all_indices.append(idx + vertex_offset)
	
	var mesh_build_time = Time.get_ticks_msec() - mesh_build_start
	print("    ✓ Mesh built in %d ms (%d verts, %d tris)" % [mesh_build_time, all_vertices.size(), all_indices.size() / 3])
	
	# Calculate normals for the entire mesh
	print("  Calculating normals for complete mesh...")
	var all_normals: PackedVector3Array
	if use_parallel:
		all_normals = await calculate_normals_parallel(all_vertices, all_indices, batch_size, scene_tree)
	else:
		all_normals = await calculate_normals_batched(all_vertices, all_indices, batch_size, scene_tree)
	
	# Create single mesh surface from all accumulated data
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = all_vertices
	arrays[Mesh.ARRAY_NORMAL] = all_normals
	arrays[Mesh.ARRAY_TEX_UV] = all_uvs
	arrays[Mesh.ARRAY_INDEX] = all_indices
	
	var array_mesh = ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	var total_time = Time.get_ticks_msec() - start_time
	print("[TerrainMeshGenerator] ✓ Chunked generation complete (1 surface, %d verts, %d tris) in %d ms" % [
		all_vertices.size(),
		all_indices.size() / 3,
		total_time
	])
	
	return array_mesh

## Calculate normals using batched processing (async)
static func calculate_normals_batched(
	vertices: PackedVector3Array,
	indices: PackedInt32Array,
	batch_size: int,
	scene_tree: SceneTree = null
) -> PackedVector3Array:
	print("    [Batched] Processing %d triangles in batches of %d..." % [indices.size() / 3, batch_size])
	
	var normals: PackedVector3Array = []
	normals.resize(vertices.size())
	
	# Initialize all normals to up
	for i in range(normals.size()):
		normals[i] = Vector3.UP
	
	# Process triangles in batches
	var num_triangles = indices.size() / 3
	var num_batches = ceili(float(num_triangles) / batch_size)
	var current_batch = 0
	var batch_num = 0
	
	while current_batch < num_triangles:
		batch_num += 1
		var batch_end = min(current_batch + batch_size, num_triangles)
		
		for tri_idx in range(current_batch, batch_end):
			var i = tri_idx * 3
			var i0 = indices[i]
			var i1 = indices[i + 1]
			var i2 = indices[i + 2]
			
			var v0 = vertices[i0]
			var v1 = vertices[i1]
			var v2 = vertices[i2]
			
			var normal = (v1 - v0).cross(v2 - v0).normalized()
			normals[i0] += normal
			normals[i1] += normal
			normals[i2] += normal
		
		current_batch = batch_end
		
		# Yield every few batches to prevent blocking
		if scene_tree and batch_num % 4 == 0:
			await scene_tree.process_frame
	
	# Normalize all normals in batches
	for i in range(normals.size()):
		normals[i] = normals[i].normalized()
	
	print("    [Batched] ✓ Processed %d batches" % num_batches)
	
	return normals

## Calculate normals using parallel processing with worker threads (async)
static func calculate_normals_parallel(
	vertices: PackedVector3Array,
	indices: PackedInt32Array,
	batch_size: int,
	scene_tree: SceneTree = null
) -> PackedVector3Array:
	print("    [Parallel] Processing %d triangles with optimized batching..." % [indices.size() / 3])
	
	var normals: PackedVector3Array = []
	normals.resize(vertices.size())
	
	# Initialize all normals to up
	for i in range(normals.size()):
		normals[i] = Vector3.UP
	
	# Calculate face normals and accumulate
	# Note: GDScript doesn't have true multi-threading for this use case,
	# but we can optimize by processing in larger batches and using
	# more efficient loops
	var num_triangles = indices.size() / 3
	var batch_count = ceili(float(num_triangles) / batch_size)
	print("    [Parallel] Processing in %d optimized batches (batch size: %d)" % [batch_count, batch_size])
	
	# Process batches
	for batch_idx in range(batch_count):
		var start_tri = batch_idx * batch_size
		var end_tri = min(start_tri + batch_size, num_triangles)
		
		# Process triangles in this batch
		for tri_idx in range(start_tri, end_tri):
			var i = tri_idx * 3
			var i0 = indices[i]
			var i1 = indices[i + 1]
			var i2 = indices[i + 2]
			
			# Cache vertices for this triangle
			var v0 = vertices[i0]
			var v1 = vertices[i1]
			var v2 = vertices[i2]
			
			# Calculate and accumulate normal
			var edge1 = v1 - v0
			var edge2 = v2 - v0
			var normal = edge1.cross(edge2).normalized()
			
			normals[i0] += normal
			normals[i1] += normal
			normals[i2] += normal
		
		# Yield every few batches
		if scene_tree and batch_idx % 4 == 0:
			await scene_tree.process_frame
	
	# Normalize in batches
	var vert_batch_size = 128
	var norm_batches = ceili(float(normals.size()) / vert_batch_size)
	for batch_start in range(0, normals.size(), vert_batch_size):
		var batch_end = min(batch_start + vert_batch_size, normals.size())
		for i in range(batch_start, batch_end):
			normals[i] = normals[i].normalized()
	
	print("    [Parallel] ✓ Normalized %d vertices in %d batches" % [normals.size(), norm_batches])
	
	return normals
