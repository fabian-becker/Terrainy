@tool
extends RefCounted

## Job schema and worker bodies of the asynchronous chunk pipeline.
##
## The split is the point of this file:
##
## - [method build] runs on the **main thread** and only makes a plain dictionary out of a chunk
##   plus the compose snapshot. No pixel is touched, so dispatching N chunks costs N dictionary
##   allocations and nothing else.
## - [method run] runs on a **worker thread** and does all the expensive, pure work: slice the
##   composed images, downsample for the render LOD, build the surface arrays, the collision data
##   and the chunk's height bounds.
##
## Thread rule (hard): [method run] is static, only reads its job dictionary and the
## refcounted data it holds, and never reaches the scene tree, the renderer, the physics server or
## the generator. Creating the [ArrayMesh] and handing shapes to [PhysicsServer3D] stays on the
## main thread in `chunk_applier.gd`.
##
## The job/result dictionaries are the interface the LOD/streaming track writes against
## (DESIGN.md §10.1); the extra keys here are additive and optional.

const MeshGen = preload("res://addons/terrainy/gen/build/mesh_generator.gd")
const CollisionBuilder = preload("res://addons/terrainy/gen/build/collision_builder.gd")

enum JobKind { MESH, NAVIGATION, SCATTER }

## Sampling border the normals of a chunk are computed from: one extra sample on every side, so
## neighbouring chunks agree on the normal at their shared samples (no shading seam).
const NORMAL_BORDER: int = 1


## Snapshot of one compose, built once per rebuild and shared by every job of that rebuild.
## Every [Image] in here is read-only until `has_pending_work()` is false (DESIGN.md §4.6).
##   "final": Image, "holes": HMap or Image or null, "grid_rect": Rect2i,
##   "rebuild_id": int, "collision_budget": int
static func make_snapshot(final_image: Image, hole_map, grid_rect: Rect2i, rebuild_id: int,
		collision_budget: int) -> Dictionary:
	return {
		"final": final_image, "holes": hole_map, "grid_rect": grid_rect,
		"rebuild_id": rebuild_id, "collision_budget": collision_budget,
	}


## Main-thread half: one MESH job for [param chunk]. [param step] is the fitted render LOD step
## (>= 1). [param skirt] is accepted for the LOD track and currently ignored (`edges = 0`).
static func build(snapshot: Dictionary, chunk, step: int = 1, skirt: Dictionary = {}) -> Dictionary:
	return {
		"kind": JobKind.MESH,
		"key": chunk.key,
		"revision": chunk.edit_revision,
		"rect": chunk.sample_rect,
		"final_image": snapshot.get("final"),
		"hole_map": snapshot.get("holes"),
		"grid_rect": snapshot.get("grid_rect", chunk.sample_rect),
		"normal_border": NORMAL_BORDER,
		"step": maxi(step, 1),
		"skirt": skirt,
		"size": chunk.world_bounds.size,
		"lod_level": chunk.lod_level,
		"collision": true,
		"collision_budget": int(snapshot.get("collision_budget", 0)),
	}


## Worker half. Returns the result dictionary of DESIGN.md §10.1, or an empty dictionary when the
## job carries no heightmap (a superseded job is dropped by the caller, not here).
static func run(job: Dictionary) -> Dictionary:
	# Full-resolution chunk heightmap and hole mask. Prefer the unsliced source images: the copy
	# then happens on this thread instead of in a main-thread loop over every dirty chunk.
	var rect: Rect2i = job.get("rect", Rect2i())
	var heightmap: Image = job.get("heightmap")
	var final_image: Image = job.get("final_image")
	if heightmap == null and final_image != null:
		heightmap = final_image.get_region(rect)
	if heightmap == null:
		return {}
	var hole_image: Image = job.get("hole_mask")
	if hole_image == null:
		# `hole_map` is the generator's hole map (an HMap) or, for tool callers, an Image
		# already cut to the chunk. Both are CPU-side, so the slice is worker safe.
		var hole_map = job.get("hole_map")
		if hole_map is Image:
			hole_image = hole_map.get_region(rect)
		elif hole_map != null and hole_map.has_method("extract"):
			var sub = hole_map.extract(rect)
			hole_image = sub.to_image() if sub != null else null
	# An always-allocated hole mask says nothing; only ask the mask itself whether it carves. That
	# scan is a native pack operation plus a short loop, so it belongs on the worker too.
	var has_holes: bool = false
	if job.has("has_holes"):
		has_holes = job["has_holes"]
	else:
		has_holes = CollisionBuilder.mask_has_holes(hole_image)
	if not has_holes:
		hole_image = null

	# Terrainy 2: the render mesh may use an LOD-reduced copy; collision always uses the full
	# resolution chunk heightmap (collision is maintained independent of render LOD).
	var step: int = maxi(int(job.get("step", 1)), 1)
	var mesh_heightmap: Image = job.get("mesh_heightmap", heightmap)
	var mesh_holes: Image = job.get("mesh_hole_mask", hole_image)
	if step > 1 and not job.has("mesh_heightmap"):
		mesh_heightmap = CollisionBuilder.downsample_exact(heightmap, step)
		if hole_image != null:
			mesh_holes = CollisionBuilder.downsample_exact(hole_image, step)

	# Normals are computed from the chunk grown by one sample, so the central difference at the
	# chunk border reads the neighbour's samples. The grown region is sliced here for the same
	# reason as the chunk itself.
	var normal_source: Image = job.get("normal_source")
	var normal_offset: Vector2i = job.get("normal_offset", Vector2i.ZERO)
	if normal_source == null and final_image != null:
		var border: int = int(job.get("normal_border", 0))
		if border > 0:
			var grid_rect: Rect2i = job.get("grid_rect", rect)
			var grown: Rect2i = rect.grow(border).intersection(grid_rect)
			normal_source = final_image.get_region(grown)
			normal_offset = grown.position - rect.position

	var mesh := MeshGen.generate_surface_arrays(
		mesh_heightmap, job["size"], mesh_holes, true,
		normal_source, step,
		normal_offset
	)

	# Hole chunks need a triangle mesh for collision (a HeightMapShape3D cannot express carved
	# holes), so build that soup here while the heightmap is hot in cache, off the main thread.
	var collision_faces := PackedVector3Array()
	var collision_wanted: bool = job.get("collision", false)
	if collision_wanted and has_holes:
		collision_faces = CollisionBuilder.build_faces(
			heightmap,
			job["size"],
			hole_image,
			job.get("collision_budget", 0),
			0,
			mesh if mesh_heightmap == heightmap else []
		)
	# A heightfield chunk's collision is a HeightMapShape3D, whose `map_data` is exactly these
	# floats. Converting the image on the main thread (per chunk, per rebuild) was pure main-thread
	# copy work; the worker hands the finished array over instead.
	var collision_heights := PackedFloat32Array()
	if collision_wanted and not has_holes:
		collision_heights = heightmap.get_data().to_float32_array()

	# The chunk's own height bounds (DESIGN.md §4.7). The commit path used to call the generator's
	# `final_min()`/`final_max()`, which is a full-grid GDScript scan (58-66 ms at 1024 cells) on
	# the first commit of every rebuild. The worker already has every height here, so the bounds
	# travel with the result and the main thread never scans.
	var bounds: Vector2 = height_bounds(heightmap, collision_heights)

	return {
		"kind": int(job.get("kind", JobKind.MESH)),
		"key": job["key"],
		"revision": job.get("revision", 0),
		"arrays": mesh,
		"collision_faces": collision_faces,
		"collision_heights": collision_heights,
		"heightmap": heightmap,
		"hole_mask": hole_image,
		"has_holes": has_holes,
		"lod_level": job["lod_level"],
		"skirt_edges": int(job.get("skirt", {}).get("edges", 0)),
		"min_y": bounds.x,
		"max_y": bounds.y,
	}


## Minimum and maximum height of [param heightmap] as `Vector2(min, max)`.
## [param floats] is the chunk's heightfield data when the caller already converted it; the pass
## itself is a plain loop over the chunk (16k samples for a 128-cell chunk), which is why it runs
## on the worker and not in the commit.
static func height_bounds(heightmap: Image, floats: PackedFloat32Array = PackedFloat32Array()) -> Vector2:
	var values := floats
	if values.is_empty():
		if heightmap == null:
			return Vector2.ZERO
		values = heightmap.get_data().to_float32_array()
	if values.is_empty():
		return Vector2.ZERO
	var lo: float = values[0]
	var hi: float = values[0]
	for v in values:
		if v < lo:
			lo = v
		elif v > hi:
			hi = v
	return Vector2(lo, hi)
