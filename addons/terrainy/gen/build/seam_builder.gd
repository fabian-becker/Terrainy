@tool
extends RefCounted

## LOD seam handling: skirts (track B).
##
## Two neighbouring chunks that sit at different LOD levels sample the edge they share at
## different resolutions, so the coarse edge is a chord through the fine polyline and the two
## triangle strips no longer meet along that line: a hairline crack opens at every LOD boundary
## and you can see straight through the terrain.
##
## Skirts are the cheap fix used by every terrain system that cannot afford neighbour stitching:
## extrude a wall straight down from each chunk border, so any gap along the border is spanned by
## geometry that belongs to this chunk. No neighbour lookups, no LOD-matched edge vertices, no
## rebuild cascade when a neighbour changes level, and a chunk can switch LOD without touching
## anything else on the map.
##
## The wall is a *second surface* of the chunk mesh on purpose:
##
##   - surface 0 keeps exactly the arrays the mesh generator produced, so bake output, collision
##     helpers and the seam/normal tests keep reading the same vertex set they always read;
##   - the wall can be added or dropped without rebuilding the chunk;
##   - `material_override` applies to every surface of a mesh, so the skirt is textured with the
##     chunk's own material (same weight planes as the surface it hides behind).
##
## Which edges get a skirt is decided by [LodController.edges_for] and passed in as a bitmask: this
## class never looks at neighbours (that coupling is exactly what the skirt approach exists to
## avoid).
##
## Each wall quad is emitted in both winding orders. A skirt is only ever visible through a crack
## or from below, and a one-sided wall would be invisible from whichever side happened to be
## back-facing - doubling 4 * n quads is cheaper than adding a second material or a
## `cull_disabled` shader variant.

## Edge bits, identical to [LodController.Edge]: N=1, E=2, S=4, W=8.
const EDGE_NORTH := 1
const EDGE_EAST := 2
const EDGE_SOUTH := 4
const EDGE_WEST := 8


## True when [param mesh] already carries a skirt surface (surface index >= 1).
static func has_skirt(mesh: ArrayMesh) -> bool:
	return mesh != null and mesh.get_surface_count() > 1


## Append the skirt surface to [param mesh].
##
## [param arrays] is surface 0's array set (vertex/normal/uv/tangent/index), [param dims] is that
## surface's vertex grid (samples per side, holes' extra boundary vertices excluded), [param depth]
## the wall depth in metres, [param edges] the [LodController.edges_for] bitmask. Returns the number
## of vertices appended (0 when nothing was added).
static func append_skirt_surface(mesh: ArrayMesh, arrays: Array, dims: Vector2i, depth: float,
		edges: int) -> int:
	if mesh == null or arrays == null or dims.x < 2 or dims.y < 2 or depth <= 0.0 or edges == 0:
		return 0
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if vertices.size() < dims.x * dims.y:
		# The arrays do not hold the grid dims claim (defensive: never build garbage geometry).
		return 0

	var wall := _build_arrays(arrays, dims, depth, edges)
	if wall.is_empty():
		return 0
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wall)
	return (wall[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()


## Raw arrays of the skirt surface: vertices/normals/uvs/tangents/indices.
## Exposed separately so the tests can inspect the wall without going through a mesh.
static func _build_arrays(arrays: Array, dims: Vector2i, depth: float, edges: int) -> Array:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]

	var out_vertices := PackedVector3Array()
	var out_normals := PackedVector3Array()
	var out_uvs := PackedVector2Array()
	var out_tangents := PackedFloat32Array()
	var indices := PackedInt32Array()

	var rows := dims.y
	var cols := dims.x
	# Order of the four borders. Each ring is the strip of grid indices along one border; every
	# consecutive pair becomes one wall quad. Both windings are emitted, so the walk direction of
	# a ring does not matter. Only the requested edges are emitted: a chunk whose neighbour shares
	# its step has no crack to seal, and a wall there would just be hidden geometry.
	var rings: Array = []
	if edges & EDGE_NORTH:
		rings.append(_row_indices(0, cols))                  # z = min border
	if edges & EDGE_EAST:
		rings.append(_col_indices(cols - 1, cols, rows))     # x = max border
	if edges & EDGE_SOUTH:
		rings.append(_row_indices(rows - 1, cols))           # z = max border
	if edges & EDGE_WEST:
		rings.append(_col_indices(0, cols, rows))            # x = min border
	for ring in rings:
		_append_wall(ring, vertices, normals, uvs, tangents, depth,
			out_vertices, out_normals, out_uvs, out_tangents, indices)
	if out_vertices.is_empty():
		return []

	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = out_vertices
	out[Mesh.ARRAY_NORMAL] = out_normals
	out[Mesh.ARRAY_TEX_UV] = out_uvs
	out[Mesh.ARRAY_TANGENT] = out_tangents
	out[Mesh.ARRAY_INDEX] = indices
	return out


## Grid indices of one row, left to right.
static func _row_indices(row: int, cols: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(cols)
	for i in cols:
		out[i] = row * cols + i
	return out


## Grid indices of one column, top to bottom.
static func _col_indices(col: int, cols: int, rows: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(rows)
	for i in rows:
		out[i] = i * cols + col
	return out


## One border strip: for every pair of neighbouring border vertices, a quad from the surface down
## to the skirt bottom, emitted in both windings.
static func _append_wall(
	ring: PackedInt32Array,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	tangents: PackedFloat32Array,
	depth: float,
	out_vertices: PackedVector3Array,
	out_normals: PackedVector3Array,
	out_uvs: PackedVector2Array,
	out_tangents: PackedFloat32Array,
	indices: PackedInt32Array
) -> void:
	for i in range(ring.size() - 1):
		var a: int = ring[i]
		var b: int = ring[i + 1]
		var base := out_vertices.size()
		for corner in [a, b]:
			var v := vertices[corner]
			out_vertices.append(v)
			out_normals.append(normals[corner] if corner < normals.size() else Vector3.UP)
			out_uvs.append(uvs[corner] if corner < uvs.size() else Vector2.ZERO)
			var t := Vector4(1.0, 0.0, 0.0, 1.0)
			if corner * 4 + 3 < tangents.size():
				t = Vector4(tangents[corner * 4], tangents[corner * 4 + 1],
					tangents[corner * 4 + 2], tangents[corner * 4 + 3])
			out_tangents.append(t.x)
			out_tangents.append(t.y)
			out_tangents.append(t.z)
			out_tangents.append(t.w)
		for corner in [a, b]:
			var v := vertices[corner]
			out_vertices.append(Vector3(v.x, v.y - depth, v.z))
			out_normals.append(normals[corner] if corner < normals.size() else Vector3.UP)
			out_uvs.append(uvs[corner] if corner < uvs.size() else Vector2.ZERO)
			var t := Vector4(1.0, 0.0, 0.0, 1.0)
			if corner * 4 + 3 < tangents.size():
				t = Vector4(tangents[corner * 4], tangents[corner * 4 + 1],
					tangents[corner * 4 + 2], tangents[corner * 4 + 3])
			out_tangents.append(t.x)
			out_tangents.append(t.y)
			out_tangents.append(t.z)
			out_tangents.append(t.w)
		# base + 0/1: top a, top b; base + 2/3: bottom a, bottom b.
		indices.append(base + 0); indices.append(base + 2); indices.append(base + 3)
		indices.append(base + 0); indices.append(base + 3); indices.append(base + 1)
		indices.append(base + 0); indices.append(base + 3); indices.append(base + 2)
		indices.append(base + 0); indices.append(base + 1); indices.append(base + 3)
