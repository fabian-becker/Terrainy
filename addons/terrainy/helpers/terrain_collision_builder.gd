class_name TerrainCollisionBuilder
extends RefCounted

## Turns chunk heightmaps into the data physics needs.
##
## **Worker safe**: nothing in here touches the renderer or the physics server, so a
## WorkerThreadPool task may build the triangle soup. Creating the shapes themselves must happen
## on the main thread: `ArrayMesh.create_trimesh_shape()` called from a worker deadlocks the
## process, and the renderer's RID table is not thread safe either.
##
## Collision detail is expressed as a **triangle budget** instead of a sample step, because a
## step means different things at different chunk resolutions. `stride_for()` turns a budget
## into the largest step that keeps the budget, and only steps that divide the chunk resolution
## are used so the coarse grid cannot drift against the visual mesh.

const TerrainMeshGenerator = preload("res://addons/terrainy/helpers/terrain_mesh_generator.gd")

## Quality presets exposed by `TerrainComposer.collision_quality`.
enum Quality { EXACT, BALANCED, FAST }

## Largest accepted collision sample step. Beyond this the collision surface stops following the
## visual terrain closely enough to be worth calling collision at all.
const MAX_STRIDE := 8

## Triangle budget per chunk for each preset. EXACT keeps every visual triangle; BALANCED is
## about the point where a walking character stops noticing the decimation; FAST is for distant
## or background terrain.
const QUALITY_BUDGETS := {
	Quality.EXACT: 0,
	Quality.BALANCED: 65536,
	Quality.FAST: 8192,
}

## Never decimate a LOD chunk below this, however small its budget becomes.
const MIN_LOD_BUDGET := 2048

## World size (x/z) of a chunk, shared by the collision and navigation geometry builders.
static func chunk_world_size(chunk) -> Vector2:
	if chunk == null:
		return Vector2.ZERO
	return Vector2(chunk.world_bounds.size.x, chunk.world_bounds.size.y)

static func budget_for_quality(quality: int) -> int:
	return int(QUALITY_BUDGETS.get(quality, 0))

## Sample step that keeps `2 * res_x * res_y / step^2` triangles at or below [param budget].
## `budget <= 0` means "no budget" and keeps the exact geometry (step 1).
static func stride_for_budget(width: int, height: int, budget: int) -> int:
	var res_x := maxi(width - 1, 1)
	var res_y := maxi(height - 1, 1)
	if budget <= 0:
		return 1
	var exact_triangles := 2 * res_x * res_y
	if exact_triangles <= budget:
		return 1
	var step := int(ceil(sqrt(float(exact_triangles) / float(budget))))
	return clampi(step, 2, MAX_STRIDE)

## Effective sample step for a chunk heightmap: the budget is scaled down for LOD chunks (each
## LOD step halves the resolution, so it quarters the triangle count) and the resulting step is
## reduced until it divides the heightmap resolution exactly.
static func stride_for(heightmap: Image, budget: int, lod_level: int = 0) -> int:
	if heightmap == null:
		return 1
	var scaled_budget := _budget_at_lod(budget, lod_level)
	var step := stride_for_budget(heightmap.get_width(), heightmap.get_height(), scaled_budget)
	return fit_stride(heightmap.get_width(), heightmap.get_height(), step)

## Budget for a chunk at `lod_level`: an EXACT budget stays exact at every distance, everything
## else loses three quarters of its triangles per LOD step, with a floor so collision never
## disappears entirely.
static func _budget_at_lod(budget: int, lod_level: int) -> int:
	if budget <= 0 or lod_level <= 0:
		return budget
	var scaled := budget >> (2 * mini(lod_level, 8))
	return maxi(scaled, MIN_LOD_BUDGET)

## Largest step <= [param step] that divides both resolutions, or 1 when none does.
## The collision grid has to land on the fine grid points, otherwise the decimated surface is
## offset against the visual mesh (and holes would no longer line up with the visual hole).
static func fit_stride(width: int, height: int, step: int) -> int:
	var res_x := maxi(width - 1, 1)
	var res_y := maxi(height - 1, 1)
	var fitted := clampi(step, 1, MAX_STRIDE)
	fitted = mini(fitted, mini(res_x, res_y))
	while fitted > 1 and (res_x % fitted != 0 or res_y % fitted != 0):
		fitted -= 1
	return fitted

## Flatten surface arrays into the triangle soup `ConcavePolygonShape3D.set_faces()` expects.
static func surface_arrays_to_faces(arrays: Array) -> PackedVector3Array:
	var faces := PackedVector3Array()
	if arrays.size() <= Mesh.ARRAY_INDEX:
		return faces
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var indices = arrays[Mesh.ARRAY_INDEX]
	if vertices == null or indices == null or indices.is_empty():
		return faces
	faces.resize(indices.size())
	for i in indices.size():
		faces[i] = vertices[indices[i]]
	return faces


## True when a hole mask actually carves at least one pixel: the mask image is allocated for
## every terrain, so its presence alone says nothing. Worker safe (pure CPU).
## The comparison matches the mesh generator's own hole test (>= HOLE_THRESHOLD), otherwise a
## mask pixel exactly on the threshold would carve the visual mesh and still get a heightmap
## collision shape, which would fill the hole back in.
static func mask_has_holes(mask: Image) -> bool:
	if mask == null:
		return false
	return mask_has_holes_in_rect(mask, Rect2i(0, 0, mask.get_width(), mask.get_height()))


## True when [param rect] of [param mask] contains a hole pixel. Used to answer "does this chunk
## have holes" once per chunk, when its mask slice is extracted, instead of rescanning the whole
## mask on every collision update.
static func mask_has_holes_in_rect(mask: Image, rect: Rect2i) -> bool:
	if mask == null or rect.size.x <= 0 or rect.size.y <= 0:
		return false
	var clamped := Rect2i(Vector2i.ZERO, mask.get_size()).intersection(rect)
	if clamped.size.x <= 0 or clamped.size.y <= 0:
		return false
	var float_data := mask.get_data().to_float32_array()
	var width := mask.get_width()
	for y in range(clamped.position.y, clamped.end.y):
		var row := y * width
		for x in range(clamped.position.x, clamped.end.x):
			if float_data[row + x] >= TerrainMeshGenerator.HOLE_THRESHOLD:
				return true
	return false


## Exact strided copy of a single channel (FORMAT_RF) image: sample (x * stride, y * stride).
## `Image.resize()` cannot be used for this: INTERPOLATE_NEAREST does not reliably pick the
## nearest source texel (measured ~90% wrong samples on a 4x downscale) and the interpolating
## modes would smooth the terrain. Returns the source unchanged when it cannot decimate.
static func downsample_exact(src: Image, stride: int) -> Image:
	if src == null or stride <= 1 or src.get_format() != Image.FORMAT_RF:
		return src
	var width := src.get_width()
	var res_x := width - 1
	var res_y := src.get_height() - 1
	if res_x <= 0 or res_y <= 0 or res_x % stride != 0 or res_y % stride != 0:
		return src
	var out_width := res_x / stride + 1
	var out_height := res_y / stride + 1
	var src_data := src.get_data().to_float32_array()
	var out_data := PackedFloat32Array()
	out_data.resize(out_width * out_height)
	for y in out_height:
		var src_row := y * stride * width
		var out_row := y * out_width
		for x in out_width:
			out_data[out_row + x] = src_data[src_row + x * stride]
	return Image.create_from_data(
		out_width, out_height, false, Image.FORMAT_RF, out_data.to_byte_array()
	)


## Triangle soup for a chunk that needs trimesh collision (the ones whose hole carving removed
## triangles; a HeightMapShape3D cannot express a hole).
##
## Worker safe: it only reads CPU data and allocates no renderer/physics resource.
##
## [param budget] is the triangle budget (0 = keep the visual triangles exactly),
## [param lod_level] scales that budget down for distant chunks, and [param visual_arrays] lets a
## caller that already generated the full resolution surface arrays (the chunk mesh worker) reuse
## them instead of rebuilding identical geometry.
static func build_faces(
	heightmap: Image,
	terrain_size: Vector2,
	hole_mask: Image,
	budget: int,
	lod_level: int = 0,
	visual_arrays: Array = []
) -> PackedVector3Array:
	if heightmap == null:
		return PackedVector3Array()
	var stride := stride_for(heightmap, budget, lod_level)
	if stride <= 1:
		var arrays := visual_arrays
		if arrays.is_empty():
			arrays = TerrainMeshGenerator.generate_surface_arrays(heightmap, terrain_size, hole_mask, false)
		return surface_arrays_to_faces(arrays)
	# The coarse collision grid spans the same world extent, so the same terrain_size is used.
	var coarse_mask: Image = null
	if hole_mask != null:
		coarse_mask = downsample_exact(hole_mask, stride)
	return surface_arrays_to_faces(TerrainMeshGenerator.generate_surface_arrays(
		downsample_exact(heightmap, stride), terrain_size, coarse_mask, false
	))
