class_name TerrainMeshGenerator
extends RefCounted

## Helper class for generating terrain meshes from heightmaps
## Generates ArrayMesh from heightmap images

## Threshold for detecting hole pixels (0.5 = 50% hole influence)
const HOLE_THRESHOLD = 0.5
const LOG_THRESHOLD_MS = 100

## Generate terrain mesh from heightmap with optional hole mask
static func generate_from_heightmap(
	heightmap: Image,
	terrain_size: Vector2,
	hole_mask: Image = null,
	bevel_config: Dictionary = {}
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
	
	# Pre-extract all height values from heightmap
	var heights := heightmap.get_data().to_float32_array()
	
	# Extract hole values if hole mask provided
	var hole_values: PackedFloat32Array
	var has_holes := hole_mask != null
	if has_holes:
		hole_values = hole_mask.get_data().to_float32_array()
	
	# Build hole status for each vertex
	var is_hole_vertex: PackedByteArray
	if has_holes:
		is_hole_vertex = PackedByteArray()
		is_hole_vertex.resize(total_vertices)
		for i in range(total_vertices):
			is_hole_vertex[i] = 1 if hole_values[i] >= HOLE_THRESHOLD else 0
	
	# Pre-allocate vertex arrays
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	
	vertices.resize(total_vertices)
	normals.resize(total_vertices)
	uvs.resize(total_vertices)
	
	# Precompute scale factors
	var uv_scale_x := 1.0 / float(res_x)
	var uv_scale_z := 1.0 / float(res_y)
	var norm_scale_x := 0.5 / step_x
	var norm_scale_z := 0.5 / step_y
	
	# Generate vertices and UVs
	var vi := 0
	
	# First row (z = 0)
	var uv_z := 0.0
	var local_z := -half_y
	for x in width:
		var h := heights[vi]
		vertices[vi] = Vector3(x * step_x - half_x, h, local_z)
		uvs[vi] = Vector2(x * uv_scale_x, uv_z)
		normals[vi] = _compute_normal(heights, vi, x, 0, width, height, step_x, step_y)
		vi += 1
	
	# Interior rows (z = 1 to res_y - 1)
	for z in range(1, res_y):
		local_z = z * step_y - half_y
		uv_z = z * uv_scale_z
		
		# Left edge (x = 0)
		var h := heights[vi]
		vertices[vi] = Vector3(-half_x, h, local_z)
		uvs[vi] = Vector2(0.0, uv_z)
		normals[vi] = _compute_normal(heights, vi, 0, z, width, height, step_x, step_y)
		vi += 1
		
		# Interior (x = 1 to res_x - 1)
		for x in range(1, res_x):
			h = heights[vi]
			vertices[vi] = Vector3(x * step_x - half_x, h, local_z)
			uvs[vi] = Vector2(x * uv_scale_x, uv_z)
			var idx := z * width + x
			var dx := (heights[idx + 1] - heights[idx - 1]) * norm_scale_x
			var dz := (heights[idx + width] - heights[idx - width]) * norm_scale_z
			normals[vi] = Vector3(-dx, 1.0, -dz).normalized()
			vi += 1
		
		# Right edge (x = res_x)
		h = heights[vi]
		vertices[vi] = Vector3(res_x * step_x - half_x, h, local_z)
		uvs[vi] = Vector2(1.0, uv_z)
		normals[vi] = _compute_normal(heights, vi, res_x, z, width, height, step_x, step_y)
		vi += 1
	
	# Last row (z = res_y)
	local_z = res_y * step_y - half_y
	uv_z = 1.0
	for x in width:
		var h := heights[vi]
		vertices[vi] = Vector3(x * step_x - half_x, h, local_z)
		uvs[vi] = Vector2(x * uv_scale_x, uv_z)
		normals[vi] = _compute_normal(heights, vi, x, res_y, width, height, step_x, step_y)
		vi += 1
	
	# Generate indices, skipping quads inside holes
	var indices := PackedInt32Array()
	indices.resize(res_x * res_y * 6)  # Max possible size
	var idx := 0
	
	for z in res_y:
		var row_base := z * width
		for x in res_x:
			var i := row_base + x
			var i_next_row := i + width
			
			# Check if this quad is inside a hole
			if has_holes and _quad_is_hole(is_hole_vertex, i, width):
				continue
			
			# Check for hole edge for potential bevel (simplified: skip bevel for now)
			# TODO: Add bevel edge handling when edge_type == BEVELED
			
			indices[idx] = i
			indices[idx + 1] = i + 1
			indices[idx + 2] = i_next_row
			indices[idx + 3] = i + 1
			indices[idx + 4] = i_next_row + 1
			indices[idx + 5] = i_next_row
			
			idx += 6
	
	# Shrink indices array to actual size
	indices.resize(idx)
	
	# Create mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	# Generate tangents for proper normal map rendering
	var surface_tool := SurfaceTool.new()
	surface_tool.create_from(array_mesh, 0)
	surface_tool.generate_tangents()
	array_mesh = surface_tool.commit()
	
	var elapsed := Time.get_ticks_msec() - start_time
	if elapsed >= LOG_THRESHOLD_MS:
		push_warning("[TerrainMeshGenerator] Slow mesh build: %dx%d (%d verts, %d tris) in %d ms" % [
			width, height, vertices.size(), indices.size() / 3, elapsed
		])
	
	return array_mesh


## Compute normal for a vertex considering edge cases
static func _compute_normal(
	heights: PackedFloat32Array,
	idx: int,
	x: int,
	z: int,
	width: int,
	height: int,
	step_x: float,
	step_y: float
) -> Vector3:
	var norm_scale_x := 0.5 / step_x
	var norm_scale_z := 0.5 / step_y
	
	var h := heights[idx]
	var h_left := heights[idx - 1] if x > 0 else h
	var h_right := heights[idx + 1] if x < width - 1 else h
	var h_up := heights[idx - width] if z > 0 else h
	var h_down := heights[idx + width] if z < height - 1 else h
	
	var dx: float
	var dz: float
	
	if x == 0:
		dx = (h_right - h) * norm_scale_x
	elif x == width - 1:
		dx = (h - h_left) * norm_scale_x
	else:
		dx = (h_right - h_left) * norm_scale_x
	
	if z == 0:
		dz = (h_down - h) * norm_scale_z
	elif z == height - 1:
		dz = (h - h_up) * norm_scale_z
	else:
		dz = (h_down - h_up) * norm_scale_z
	
	return Vector3(-dx, 1.0, -dz).normalized()


## Check if a quad (2 triangles) is entirely inside a hole
static func _quad_is_hole(is_hole_vertex: PackedByteArray, top_left_idx: int, width: int) -> bool:
	var top_right := top_left_idx + 1
	var bottom_left := top_left_idx + width
	var bottom_right := top_left_idx + width + 1
	
	var max_idx := is_hole_vertex.size() - 1
	if bottom_right > max_idx:
		return false
	
	# Quad is inside hole if all 4 corners are in hole
	return is_hole_vertex[top_left_idx] == 1 \
		and is_hole_vertex[top_right] == 1 \
		and is_hole_vertex[bottom_left] == 1 \
		and is_hole_vertex[bottom_right] == 1


## Check if a vertex is on a hole boundary (for bevel handling)
static func _is_hole_boundary_vertex(
	is_hole_vertex: PackedByteArray,
	idx: int,
	x: int,
	z: int,
	width: int,
	height: int
) -> bool:
	var is_inside := is_hole_vertex[idx] == 1
	if is_inside:
		return false
	
	# Check neighbors - if any neighbor is in hole, this is a boundary vertex
	var neighbors := [
		Vector2i(x - 1, z), Vector2i(x + 1, z),  # left, right
		Vector2i(x, z - 1), Vector2i(x, z + 1),  # up, down
		Vector2i(x - 1, z - 1), Vector2i(x + 1, z - 1),  # diagonals
		Vector2i(x - 1, z + 1), Vector2i(x + 1, z + 1)
	]
	
	for n in neighbors:
		if n.x >= 0 and n.x < width and n.y >= 0 and n.y < height:
			var neighbor_idx = n.y * width + n.x
			if is_hole_vertex[neighbor_idx] == 1:
				return true
	
	return false