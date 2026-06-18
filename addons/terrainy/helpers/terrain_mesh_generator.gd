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
	
	# Generate indices
	var indices := PackedInt32Array()

	if has_holes:
		# Marching-squares triangulation with interpolated boundary vertices for clean hole edges
		var b_verts := PackedVector3Array()
		var b_normals := PackedVector3Array()
		var b_uvs := PackedVector2Array()
		var edge_verts: Dictionary = {}

		for z in res_y:
			var row_base := z * width
			for x in res_x:
				var i00 := row_base + x
				var i10 := i00 + 1
				var i01 := i00 + width
				var i11 := i00 + width + 1

				var h00 := is_hole_vertex[i00] == 1
				var h10 := is_hole_vertex[i10] == 1
				var h01 := is_hole_vertex[i01] == 1
				var h11 := is_hole_vertex[i11] == 1

				_cell_triangles(
					i00, i10, i01, i11, h00, h10, h01, h11,
					heights, vertices, uvs, normals,
					b_verts, b_normals, b_uvs, indices, edge_verts,
					total_vertices, x, z, width
				)

		if b_verts.size() > 0:
			vertices.append_array(b_verts)
			normals.append_array(b_normals)
			uvs.append_array(b_uvs)
	else:
		indices.resize(res_x * res_y * 6)
		var idx := 0
		for z in res_y:
			var row_base := z * width
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


## Generate triangles for one grid cell using marching-squares on hole mask.
## Boundary vertices are deduplicated across adjacent cells via edge_verts dict.
static func _cell_triangles(
	i00: int, i10: int, i01: int, i11: int,
	h00: bool, h10: bool, h01: bool, h11: bool,
	heights: PackedFloat32Array,
	vertices: PackedVector3Array,
	uvs: PackedVector2Array,
	normals: PackedVector3Array,
	b_verts: PackedVector3Array,
	b_normals: PackedVector3Array,
	b_uvs: PackedVector2Array,
	indices: PackedInt32Array,
	edge_verts: Dictionary,
	base_off: int, gx: int, gz: int, gw: int
) -> void:
	# All solid or all hole
	if (h00 == h10 and h10 == h01 and h01 == h11):
		if not h00:
			indices.append(i00); indices.append(i10); indices.append(i01)
			indices.append(i10); indices.append(i11); indices.append(i01)
		return

	# Get shared boundary vertices for crossing edges
	var bt = _bvert("h_%d_%d" % [gz, gx], edge_verts, i00, i10, h00, h10, heights, vertices, uvs, normals, b_verts, b_normals, b_uvs, base_off)
	var br = _bvert("v_%d_%d" % [gz, gx + 1], edge_verts, i10, i11, h10, h11, heights, vertices, uvs, normals, b_verts, b_normals, b_uvs, base_off)
	var bb = _bvert("h_%d_%d" % [gz + 1, gx], edge_verts, i01, i11, h01, h11, heights, vertices, uvs, normals, b_verts, b_normals, b_uvs, base_off)
	var bl = _bvert("v_%d_%d" % [gz, gx], edge_verts, i00, i01, h00, h01, heights, vertices, uvs, normals, b_verts, b_normals, b_uvs, base_off)

	# Build ordered solid polygon (counter-clockwise around cell center).
	var poly: PackedInt32Array = _build_solid_poly(
		i00, i10, i01, i11, h00, h10, h01, h11, bt, br, bb, bl
	)

	# Fan triangulate the solid polygon
	for i in range(2, poly.size()):
		indices.append(poly[0]); indices.append(poly[i - 1]); indices.append(poly[i])


## Build an ordered polygon of solid vertices (corners + boundary vertices).
## Traverses the cell perimeter CCW and collects vertices in the solid region.
static func _build_solid_poly(
	i00: int, i10: int, i01: int, i11: int,
	h00: bool, h10: bool, h01: bool, h11: bool,
	bt: int, br: int, bb: int, bl: int
) -> PackedInt32Array:
	var poly: PackedInt32Array = []

	# Left edge: i00 → i01
	if not h00: poly.append(i00)
	if h00 != h01 and bl >= 0: poly.append(bl)
	if not h01: poly.append(i01)

	# Bottom edge: i01 → i11
	if h01 != h11 and bb >= 0: poly.append(bb)
	if not h11: poly.append(i11)

	# Right edge: i11 → i10
	if h11 != h10 and br >= 0: poly.append(br)
	if not h10: poly.append(i10)

	# Top edge: i10 → i00
	if h10 != h00 and bt >= 0: poly.append(bt)

	# Remove consecutive duplicates
	var result: PackedInt32Array = []
	for v in poly:
		if result.is_empty() or result[result.size() - 1] != v:
			result.append(v)

	return result


## Get or create a shared boundary vertex for an edge.
## Returns -1 if the edge does not cross (both hole or both solid).
static func _bvert(
	key: String, edge_verts: Dictionary,
	i_a: int, i_b: int,
	ha: bool, hb: bool,
	heights: PackedFloat32Array,
	vertices: PackedVector3Array,
	uvs: PackedVector2Array,
	normals: PackedVector3Array,
	b_verts: PackedVector3Array,
	b_normals: PackedVector3Array,
	b_uvs: PackedVector2Array,
	base_off: int
) -> int:
	if ha == hb:
		return -1
	if edge_verts.has(key):
		return edge_verts[key]

	var idx = base_off + b_verts.size()

	var i_s = i_a if not ha else i_b
	var i_h = i_a if ha else i_b

	var pa = vertices[i_s]
	var pb = vertices[i_h]
	var t = 0.5
	var pos = pa.lerp(pb, t)
	pos.y = heights[i_s] + (heights[i_h] - heights[i_s]) * t

	var ua = uvs[i_s]
	var ub = uvs[i_h]
	var uv = ua.lerp(ub, t)

	var na = normals[i_s]
	var nb = normals[i_h]
	var n = na.lerp(nb, t).normalized()

	b_verts.append(pos)
	b_normals.append(n)
	b_uvs.append(uv)

	edge_verts[key] = idx
	return idx