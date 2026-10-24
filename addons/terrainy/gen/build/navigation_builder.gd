@tool
extends RefCounted

## Per-chunk navigation baking.
##
## Each chunk owns a NavigationRegion3D. Its source geometry is the chunk's surface grown by a
## border, and the bake is clipped to the chunk with `filter_baking_aabb` + `border_size`, so
## the tiles meet without being shrunk by the agent radius at their seams (tile-aligned
## baking). The geometry reuses the collision decimation with a small triangle budget: the
## bake rasterizes into cells anyway.
##
## The rasterization is fitted to the chunk, not to the template alone: a chunk of a large terrain
## can be hundreds of meters wide, and the NavigationMesh defaults (0.25 m cells) would need tens of
## millions of voxels for a single tile. [method scaled_cell_size] coarsens the cells just enough to
## stay inside the voxel budget, which keeps per-tile bake time flat as the terrain grows.
##
## Holes only punch the navmesh when at least one TerrainHoleNode has `punches_navigation`; the
## caller passes the filtered hole mask in that case.

const CollisionBuilder = preload("res://addons/terrainy/gen/build/collision_builder.gd")
const HMap = preload("res://addons/terrainy/gen/eval/hmap.gd")

const DEFAULT_BUDGET: int = 16384

## Rasterization cells one chunk bake may use. Godot aborts above 30 M cells
## (`navigation/baking/use_crash_prevention_checks`, nav_mesh_generator_3d.cpp:413); one million
## keeps a tile bake around a second at any terrain scale and is far clear of that guard.
const NAV_MAX_VOXELS: int = 1_000_000
## Ceiling the guard falls back to if the geometry is still too big for the budget (defense only).
const NAV_ABORT_VOXELS: int = 25_000_000

## Copy every stored setting of [param source] onto [param target].
static func copy_settings(source: NavigationMesh, target: NavigationMesh) -> void:
	if source == null:
		return
	for property in source.get_property_list():
		var pname: String = property["name"]
		if pname.begins_with("resource_") or not (int(property["usage"]) & PROPERTY_USAGE_STORAGE):
			continue
		target.set(pname, source.get(pname))

## Rasterization cell size to use for a bake spanning [param extent] meters on its longest axis.
## Honors the template cell size when it is already coarse enough; otherwise returns the cell size
## that keeps the voxel grid at [constant NAV_MAX_VOXELS]. Scale invariant: doubling the terrain (and
## with it the chunk size) doubles the cells, it never multiplies the voxel count.
static func scaled_cell_size(mesh: NavigationMesh, extent: float) -> float:
	# 1.1 covers the border the tile is grown by, so the budget holds for the baked AABB too.
	return maxf(mesh.cell_size, maxf(extent, 1.0) * 1.1 / sqrt(float(NAV_MAX_VOXELS)))

## Rasterization border of one tile. The baked area has to reach `agent_radius` past the chunk edge
## (otherwise the agent-radius erosion clips the walkable area at the seam), but a wider border makes
## neighbouring tiles overlap by more than the two edges the navigation map can merge, which is what
## prints "more than 2 edges tried to occupy the same rasterization space". One agent radius plus one
## cell is enough, and it is an exact multiple of the cell size (Godot ceils and warns otherwise).
static func border_size_for(mesh: NavigationMesh) -> float:
	return ceilf((mesh.agent_radius + mesh.cell_size) / mesh.cell_size) * mesh.cell_size

## Build the bake job of one chunk: {"mesh": NavigationMesh, "geometry": SourceGeometryData}.
## [param final_map] / [param nav_holes] are full-grid HMaps (nav_holes may be null).
static func make_job(chunk, grid, final_map, nav_holes, template: NavigationMesh, budget: int) -> Dictionary:
	var mesh := NavigationMesh.new()
	copy_settings(template, mesh)
	# Fit the rasterization to the chunk before anything is derived from the cell size.
	var extent := maxf(chunk.world_bounds.size.x, chunk.world_bounds.size.y)
	mesh.cell_size = scaled_cell_size(mesh, extent)
	# The rasterizer can only represent whole cells: snap the agent radius up to one. Godot applies
	# the same ceiling internally (it warned about the precision loss on every coarsened bake).
	mesh.agent_radius = ceilf(maxf(mesh.agent_radius, mesh.cell_size) / mesh.cell_size) * mesh.cell_size
	var border := border_size_for(mesh)
	var border_cells := maxi(int(ceil(border / grid.cell)), 1)
	var grown: Rect2i = chunk.sample_rect.grow(border_cells).intersection(grid.full_rect())
	var heights = final_map.extract(grown)
	var height_image: Image = heights.to_image()
	var hole_image: Image = nav_holes.extract(grown).to_image() if nav_holes != null else null
	var size := Vector2((grown.size.x - 1) * grid.cell, (grown.size.y - 1) * grid.cell)
	var faces := CollisionBuilder.build_faces(height_image, size, hole_image, budget if budget > 0 else DEFAULT_BUDGET, 0)
	var geometry := NavigationMeshSourceGeometryData3D.new()
	if faces.is_empty():
		return {}
	# Faces are centered on the grown rect; the region lives on the chunk root (chunk center).
	var grown_center: Vector2 = grid.world_of_rect(grown).get_center()
	var chunk_center: Vector2 = chunk.world_bounds.get_center()
	var offset := grown_center - chunk_center
	geometry.add_faces(faces, Transform3D(Basis.IDENTITY, Vector3(offset.x, 0.0, offset.y)))
	var hm = heights.min_max()
	var half: Vector2 = chunk.world_bounds.size * 0.5
	mesh.border_size = border
	# The simplification error is in world units: keep it proportional to the cell size, or a coarse
	# bake emits a dense edge soup ("more than 2 edges tried to occupy the same rasterization space").
	mesh.edge_max_error = clampf(mesh.edge_max_error, mesh.cell_size * 1.3, mesh.cell_size * 6.0)
	mesh.filter_baking_aabb = AABB(
		Vector3(-half.x - border, hm.x - 2.0, -half.y - border),
		Vector3((half.x + border) * 2.0, hm.y - hm.x + 4.0 + mesh.agent_height, (half.y + border) * 2.0))
	var voxels := int(ceil(mesh.filter_baking_aabb.size.x / mesh.cell_size)) \
		* int(ceil(mesh.filter_baking_aabb.size.z / mesh.cell_size))
	if voxels > NAV_ABORT_VOXELS:
		push_error("[Terrainy] chunk %s navigation bake would need %d voxels (%.1f m at %.3f m cells). Raise the NavigationMesh template cell size or lower chunk_size." % [
			chunk.key, voxels, extent, mesh.cell_size])
		return {}
	return {"mesh": mesh, "geometry": geometry}
