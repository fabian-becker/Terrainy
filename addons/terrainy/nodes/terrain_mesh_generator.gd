class_name TerrainMeshGenerator
extends RefCounted

## Heightmap-based terrain mesh generator for optimal performance

## Generate terrain mesh from heightmap
static func generate_from_heightmap(
	heightmap: Image,
	terrain_size: Vector2
) -> ArrayMesh:
	var start_time = Time.get_ticks_msec()
	
	var resolution = Vector2i(heightmap.get_width() - 1, heightmap.get_height() - 1)
	var vertices: PackedVector3Array = []
	var normals: PackedVector3Array = []
	var uvs: PackedVector2Array = []
	var indices: PackedInt32Array = []
	
	var step = terrain_size / Vector2(resolution)
	var half_size = terrain_size / 2.0
	var total_vertices = (resolution.x + 1) * (resolution.y + 1)
	
	# Pre-allocate arrays
	vertices.resize(total_vertices)
	uvs.resize(total_vertices)
	
	# Generate vertices from heightmap
	var vertex_index = 0
	for z in range(resolution.y + 1):
		for x in range(resolution.x + 1):
			var local_x = (x * step.x) - half_size.x
			var local_z = (z * step.y) - half_size.y
			
			# Sample heightmap
			var height = heightmap.get_pixel(x, z).r
			
			vertices[vertex_index] = Vector3(local_x, height, local_z)
			uvs[vertex_index] = Vector2(x / float(resolution.x), z / float(resolution.y))
			vertex_index += 1
	
	# Generate indices
	for z in range(resolution.y):
		for x in range(resolution.x):
			var i = z * (resolution.x + 1) + x
			
			# Two triangles per quad
			indices.append(i)
			indices.append(i + 1)
			indices.append(i + resolution.x + 1)
			
			indices.append(i + 1)
			indices.append(i + resolution.x + 2)
			indices.append(i + resolution.x + 1)
	
	# Calculate normals
	normals.resize(vertices.size())
	for i in range(normals.size()):
		normals[i] = Vector3.ZERO
	
	# Accumulate face normals
	for i in range(0, indices.size(), 3):
		var i0 = indices[i]
		var i1 = indices[i + 1]
		var i2 = indices[i + 2]
		
		var edge1 = vertices[i1] - vertices[i0]
		var edge2 = vertices[i2] - vertices[i0]
		var normal = edge1.cross(edge2)
		
		normals[i0] += normal
		normals[i1] += normal
		normals[i2] += normal
	
	# Normalize
	for i in range(normals.size()):
		normals[i] = normals[i].normalized()
	
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
	print("[TerrainMeshGenerator] Generated %dx%d terrain (%d verts, %d tris) from heightmap in %d ms" % [
		resolution.x, resolution.y, vertices.size(), indices.size() / 3, elapsed
	])
	
	return array_mesh

## Legacy: Generate terrain mesh - DEPRECATED, use heightmap approach
static func generate(
	resolution: int,
	terrain_size: Vector2,
	height_callback: Callable
) -> ArrayMesh:
	var start_time = Time.get_ticks_msec()
	
	var vertices: PackedVector3Array = []
	var normals: PackedVector3Array = []
	var uvs: PackedVector2Array = []
	var indices: PackedInt32Array = []
	
	var step = terrain_size / float(resolution)
	var half_size = terrain_size / 2.0
	var total_vertices = (resolution + 1) * (resolution + 1)
	
	# Pre-allocate arrays
	vertices.resize(total_vertices)
	uvs.resize(total_vertices)
	
	# Generate vertices
	var vertex_index = 0
	for z in range(resolution + 1):
		for x in range(resolution + 1):
			var local_x = (x * step.x) - half_size.x
			var local_z = (z * step.y) - half_size.y
			var local_pos = Vector3(local_x, 0, local_z)
			
			var height = height_callback.call(local_pos)
			
			vertices[vertex_index] = Vector3(local_x, height, local_z)
			uvs[vertex_index] = Vector2(x / float(resolution), z / float(resolution))
			vertex_index += 1
	
	# Generate indices
	for z in range(resolution):
		for x in range(resolution):
			var i = z * (resolution + 1) + x
			
			# Two triangles per quad
			indices.append(i)
			indices.append(i + 1)
			indices.append(i + resolution + 1)
			
			indices.append(i + 1)
			indices.append(i + resolution + 2)
			indices.append(i + resolution + 1)
	
	# Calculate normals
	normals.resize(vertices.size())
	for i in range(normals.size()):
		normals[i] = Vector3.ZERO
	
	# Accumulate face normals
	for i in range(0, indices.size(), 3):
		var i0 = indices[i]
		var i1 = indices[i + 1]
		var i2 = indices[i + 2]
		
		var edge1 = vertices[i1] - vertices[i0]
		var edge2 = vertices[i2] - vertices[i0]
		var normal = edge1.cross(edge2)
		
		normals[i0] += normal
		normals[i1] += normal
		normals[i2] += normal
	
	# Normalize
	for i in range(normals.size()):
		normals[i] = normals[i].normalized()
	
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
	print("[TerrainMeshGenerator] Generated %dx%d terrain (%d verts, %d tris) in %d ms" % [
		resolution, resolution, vertices.size(), indices.size() / 3, elapsed
	])
	
	return array_mesh
