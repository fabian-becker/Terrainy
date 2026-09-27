extends RefCounted

## Builds the source geometry for a terrain navigation mesh.
##
## The navigation bake rasterises its input into cells (`NavigationMesh.cell_size`, 0.25 by
## default, so about 128x128 cells for a 32 unit chunk), which means the >500k triangles of a
## 513x513 chunk buy no detail at all - they only make the bake slower. The builder therefore
## reuses the collision decimation with its own, much smaller budget.
##
## Chunks with holes contribute the carved surface, not the filled one: their faces come from the
## same hole-aware generator the collision and visual meshes use.

const TerrainCollisionBuilder = preload("res://addons/terrainy/helpers/terrain_collision_builder.gd")

## Triangles per chunk used when the caller does not ask for another budget. A 32 unit chunk is
## 128x128 cells at the default cell size and each cell keeps two triangles, so 16k triangles
## already saturate the rasteriser of a chunk-sized area.
const DEFAULT_BUDGET: int = 16384

## Append the surface of every chunk that has a heightmap to [param geometry].
## Returns the number of chunks that contributed faces.
static func append_chunks(
	geometry: NavigationMeshSourceGeometryData3D, chunks: Array, budget: int = DEFAULT_BUDGET
) -> int:
	var added := 0
	for chunk in chunks:
		if chunk == null or chunk.heightmap == null:
			continue
		var faces := TerrainCollisionBuilder.build_faces(
			chunk.heightmap,
			TerrainCollisionBuilder.chunk_world_size(chunk),
			chunk.hole_mask,
			budget,
			chunk.lod_level
		)
		if faces.is_empty():
			continue
		geometry.add_faces(faces, chunk_transform(chunk))
		added += 1
	return added


## Transform that places a chunk's faces next to the chunk nodes. The faces are built around the
## origin of the chunk (the collision shape relies on that too), while the navigation region lives
## next to the chunk roots - both under the composer - so the chunk root transform (composer local
## space) is the right one, not the world transform.
static func chunk_transform(chunk) -> Transform3D:
	if chunk == null:
		return Transform3D.IDENTITY
	if chunk.root and is_instance_valid(chunk.root):
		return chunk.root.transform
	if chunk.mesh_instance and is_instance_valid(chunk.mesh_instance):
		return chunk.mesh_instance.transform
	return Transform3D.IDENTITY
