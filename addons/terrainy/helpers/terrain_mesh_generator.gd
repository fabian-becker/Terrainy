class_name TerrainMeshGenerator
extends RefCounted

## Helper class for generating terrain meshes from heightmaps
## Generates ArrayMesh from heightmap images

const LOG_THRESHOLD_MS = 10

## Generate terrain mesh from heightmap
static func generate_from_heightmap(
	heightmap: Image,
	terrain_size: Vector2
) -> ArrayMesh:
	var start_time := Time.get_ticks_msec()
	
	var width := heightmap.get_width()
	var height := heightmap.get_height()
	var res_x := width - 1
	var res_y := height - 1
	
	var step_x := terrain_size.x / float(res_x)
	var step_y := terrain_size.y / float(res_y)
	var half_x := terrain_size.x * 0.5
	var half_y := terrain_size.y * 0.5
	var total_vertices := width * height
	
	# Pre-allocate all arrays upfront
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	
	vertices.resize(total_vertices)
	normals.resize(total_vertices)
	uvs.resize(total_vertices)
	
	# Pre-allocate indices: 2 triangles * 3 indices per quad
	indices.resize(res_x * res_y * 6)
	
	# Pre-extract all height values from heightmap using to_float32_array (native, fast)
	var heights := heightmap.get_data().to_float32_array()
	
	# Precompute scale factors
	var uv_scale_x := 1.0 / float(res_x)
	var uv_scale_z := 1.0 / float(res_y)
	var norm_scale_x := 0.5 / step_x
	var norm_scale_z := 0.5 / step_y
	
	# Generate vertices and UVs for interior (bulk of data, no edge checks)
	# Process row by row, handle edges separately
	var vi := 0
	
	# First row (z = 0)
	var uv_z := 0.0
	var local_z := -half_y
	for x in width:
		var h := heights[vi]
		vertices[vi] = Vector3(x * step_x - half_x, h, local_z)
		uvs[vi] = Vector2(x * uv_scale_x, uv_z)
		
		var h_left := heights[vi - 1] if x > 0 else h
		var h_right := heights[vi + 1] if x < res_x else h
		var h_down := heights[vi + width]
		var dx := (h_right - h_left) * norm_scale_x
		var dz := (h_down - h) * norm_scale_z
		normals[vi] = Vector3(-dx, 1.0, -dz).normalized()
		vi += 1
	
	# Interior rows (z = 1 to res_y - 1) - no vertical edge checks needed
	for z in range(1, res_y):
		local_z = z * step_y - half_y
		uv_z = z * uv_scale_z
		
		# Left edge (x = 0)
		var h := heights[vi]
		vertices[vi] = Vector3(-half_x, h, local_z)
		uvs[vi] = Vector2(0.0, uv_z)
		var h_right := heights[vi + 1]
		var h_up := heights[vi - width]
		var h_down := heights[vi + width]
		var dx := (h_right - h) * norm_scale_x
		var dz := (h_down - h_up) * norm_scale_z
		normals[vi] = Vector3(-dx, 1.0, -dz).normalized()
		vi += 1
		
		# Interior (x = 1 to res_x - 1) - no edge checks
		for x in range(1, res_x):
			h = heights[vi]
			vertices[vi] = Vector3(x * step_x - half_x, h, local_z)
			uvs[vi] = Vector2(x * uv_scale_x, uv_z)
			
			dx = (heights[vi + 1] - heights[vi - 1]) * norm_scale_x
			dz = (heights[vi + width] - heights[vi - width]) * norm_scale_z
			normals[vi] = Vector3(-dx, 1.0, -dz).normalized()
			vi += 1
		
		# Right edge (x = res_x)
		h = heights[vi]
		vertices[vi] = Vector3(res_x * step_x - half_x, h, local_z)
		uvs[vi] = Vector2(1.0, uv_z)
		var h_left := heights[vi - 1]
		h_up = heights[vi - width]
		h_down = heights[vi + width]
		dx = (h - h_left) * norm_scale_x
		dz = (h_down - h_up) * norm_scale_z
		normals[vi] = Vector3(-dx, 1.0, -dz).normalized()
		vi += 1
	
	# Last row (z = res_y)
	local_z = res_y * step_y - half_y
	uv_z = 1.0
	for x in width:
		var h := heights[vi]
		vertices[vi] = Vector3(x * step_x - half_x, h, local_z)
		uvs[vi] = Vector2(x * uv_scale_x, uv_z)
		
		var h_left := heights[vi - 1] if x > 0 else h
		var h_right := heights[vi + 1] if x < res_x else h
		var h_up := heights[vi - width]
		var dx := (h_right - h_left) * norm_scale_x
		var dz := (h - h_up) * norm_scale_z
		normals[vi] = Vector3(-dx, 1.0, -dz).normalized()
		vi += 1
	
	# Generate indices with direct indexing - single loop
	var idx := 0
	for z in res_y:
		var row_base := z * width
		@warning_ignore("integer_division")
		for x in res_x:
			var i := row_base + x
			var i_next_row := i + width
			
			indices[idx] = i
			indices[idx + 1] = i + 1
			indices[idx + 2] = i_next_row
			indices[idx + 3] = i + 1
			indices[idx + 4] = i_next_row + 1
			indices[idx + 5] = i_next_row
			
			idx += 6
	
	# Create mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var array_mesh = ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	var elapsed = Time.get_ticks_msec() - start_time
	if elapsed >= LOG_THRESHOLD_MS:
		push_warning("[TerrainMeshGenerator] Slow mesh build: %dx%d (%d verts, %d tris) in %d ms" % [
			width, height, vertices.size(), indices.size() / 3, elapsed
		])
	
	return array_mesh