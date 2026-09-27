@tool
class_name EvaluationContext
extends RefCounted

## Thread-safe immutable snapshot of terrain feature transform and influence data.
## Used for evaluating terrain features in worker threads without scene tree access.

## World position of the feature
var world_position: Vector3 = Vector3.ZERO

## Pre-computed inverse transform for world→local conversion
var inverse_transform: Transform3D = Transform3D.IDENTITY

## Influence radius (max of influence half-extents)
var influence_radius: float = 0.0

## Pre-computed squared radius for fast distance checks
var influence_radius_sq: float = 0.0

## Pre-computed AABB for fast spatial culling
var aabb: AABB = AABB()

## Influence shape type
var influence_shape: int = 0

## Influence size (width, depth)
var influence_size: Vector2 = Vector2.ZERO

## Edge falloff parameter
var edge_falloff: float = 0.0

## Feature strength/weight
var strength: float = 1.0

## Blend mode
var blend_mode: int = 0

## Optional baked mask texture data (for thread-safe sampling in worker threads)
var masktex_data: PackedFloat32Array = PackedFloat32Array()

## Size of the baked mask data (width, height)
var masktex_size: Vector2i = Vector2i.ZERO

## Whether the mask should be inverted
var masktex_invert: bool = false

## Create an EvaluationContext from a TerrainFeatureNode.
## This captures all necessary data for thread-safe evaluation.
static func from_feature(feature: TerrainFeatureNode) -> EvaluationContext:
	var ctx = EvaluationContext.new()
	
	# Capture transform data
	ctx.world_position = feature.global_position
	ctx.inverse_transform = feature.global_transform.affine_inverse()
	
	# Capture influence data
	ctx.influence_shape = feature.influence_shape
	ctx.influence_size = feature.influence_size
	ctx.influence_radius = get_influence_radius(ctx.influence_shape, ctx.influence_size)
	ctx.influence_radius_sq = ctx.influence_radius * ctx.influence_radius
	
	# Capture blend parameters
	ctx.edge_falloff = feature.edge_falloff
	ctx.strength = feature.strength
	ctx.blend_mode = feature.blend_mode
	
	# Pre-compute AABB for spatial culling (rotation-aware)
	ctx.aabb = compute_rotation_aware_aabb(feature.global_transform, ctx.world_position, ctx.influence_shape, ctx.influence_size)
	
	# Capture optional mask texture data for thread-safe sampling
	if feature.has_method("has_mask_texture") and feature.has_mask_texture():
		ctx.masktex_data = feature._get_mask_data().duplicate()
		ctx.masktex_size = feature._masktex_cache_size
		ctx.masktex_invert = feature.mask_invert
	
	return ctx

static func get_influence_half_extents(shape: int, size: Vector2) -> Vector2:
	match shape:
		TerrainFeatureNode.InfluenceShape.CIRCLE:
			var radius = max(max(size.x, size.y) * 0.5, 0.0001)
			return Vector2(radius, radius)
		TerrainFeatureNode.InfluenceShape.ELLIPSE:
			return Vector2(max(size.x * 0.5, 0.0001), max(size.y * 0.5, 0.0001))
		_:
			return Vector2(max(size.x * 0.5, 0.0001), max(size.y * 0.5, 0.0001))

static func get_influence_radius(shape: int, size: Vector2) -> float:
	var half_extents = get_influence_half_extents(shape, size)
	return max(half_extents.x, half_extents.y)

## Compute a rotation-aware AABB by transforming influence shape corners through the feature's global transform.
## Used for spatial culling and pixel-bounds clipping in influence map generation.
static func compute_rotation_aware_aabb(global_transform: Transform3D, world_position: Vector3, shape: int, size: Vector2) -> AABB:
	var half_extents = get_influence_half_extents(shape, size)
	var corners = [
		global_transform * Vector3(-half_extents.x, 0, -half_extents.y),
		global_transform * Vector3(half_extents.x, 0, -half_extents.y),
		global_transform * Vector3(half_extents.x, 0, half_extents.y),
		global_transform * Vector3(-half_extents.x, 0, half_extents.y)
	]
	var min_x: float = INF
	var min_z: float = INF
	var max_x: float = -INF
	var max_z: float = -INF
	for corner in corners:
		min_x = min(min_x, corner.x)
		min_z = min(min_z, corner.z)
		max_x = max(max_x, corner.x)
		max_z = max(max_z, corner.z)
	var half_size = Vector3(max_x - min_x, 2000.0, max_z - min_z) * 0.5
	var center = Vector3((min_x + max_x) * 0.5, world_position.y, (min_z + max_z) * 0.5)
	return AABB(center - half_size, half_size * 2.0)

## Conservative XZ radius of a shape that also has a vertical extent (3D holes).
## Any rotation of a box with half extents (hx, hy, hz) projects at most sqrt(hx^2 + hy^2 + hz^2)
## onto any axis in the XZ plane, so a square of that half extent always contains the rotated
## body. Used to bound the 3D hole influence pass, where the 4-corner AABB above is not enough:
## it only transforms corners at y = 0, so tilting the hole about X or Z would let the vertical
## extent stick out of it.
static func conservative_xz_half_extent(shape: int, size: Vector2, half_extent_y: float) -> float:
	var half_extents = get_influence_half_extents(shape, size)
	var hy = max(half_extent_y, 0.0)
	return sqrt(
		half_extents.x * half_extents.x + hy * hy + half_extents.y * half_extents.y
	)

## Pixel rectangle (inclusive bounds) that a world-space AABB covers on the terrain grid.
##
## Returns a Rect2i in pixel coordinates, clamped to [param resolution], with [param padding]
## pixels of slack on every side. The padding covers the rounding of the AABB edges: a pixel
## whose center sits just outside the exact boundary would otherwise be skipped even though the
## weight function can still return a non-zero value there.
##
## Returns an empty Rect2i when the AABB does not overlap the terrain at all, which callers use
## to skip the whole pass.
static func compute_pixel_bounds(
	aabb: AABB,
	terrain_bounds: Rect2,
	resolution: Vector2i,
	padding: int = 1
) -> Rect2i:
	if resolution.x <= 0 or resolution.y <= 0:
		return Rect2i()
	var step_x := terrain_bounds.size.x / float(resolution.x - 1)
	var step_y := terrain_bounds.size.y / float(resolution.y - 1)
	if step_x <= 0.0 or step_y <= 0.0:
		return Rect2i()

	# World extent of the AABB in the terrain's XZ frame.
	var world_min_x := aabb.position.x
	var world_max_x := aabb.position.x + aabb.size.x
	var world_min_z := aabb.position.z
	var world_max_z := aabb.position.z + aabb.size.z

	# Fully outside the terrain: nothing can contribute.
	if world_max_x < terrain_bounds.position.x or world_min_x > terrain_bounds.position.x + terrain_bounds.size.x:
		return Rect2i()
	if world_max_z < terrain_bounds.position.y or world_min_z > terrain_bounds.position.y + terrain_bounds.size.y:
		return Rect2i()

	var x0 := int(floor((world_min_x - terrain_bounds.position.x) / step_x)) - padding
	var x1 := int(ceil((world_max_x - terrain_bounds.position.x) / step_x)) + padding
	var y0 := int(floor((world_min_z - terrain_bounds.position.y) / step_y)) - padding
	var y1 := int(ceil((world_max_z - terrain_bounds.position.y) / step_y)) + padding

	x0 = clampi(x0, 0, resolution.x - 1)
	x1 = clampi(x1, 0, resolution.x - 1)
	y0 = clampi(y0, 0, resolution.y - 1)
	y1 = clampi(y1, 0, resolution.y - 1)
	if x1 < x0 or y1 < y0:
		return Rect2i()
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)

## Convert world-space position to local-space without scene tree access.
## This is the thread-safe replacement for Node3D.to_local()
func to_local(world_pos: Vector3) -> Vector3:
	return inverse_transform * world_pos

## Fast check if a world position is within the feature's influence area.
## Uses AABB test first, then radius check for early rejection.
func is_in_influence_area(world_pos: Vector3) -> bool:
	# Quick AABB rejection
	if not aabb.has_point(world_pos):
		return false
	
	# Accurate distance check (2D in XZ plane)
	var diff = world_pos - world_position
	var distance_sq = diff.x * diff.x + diff.z * diff.z
	
	return distance_sq <= influence_radius_sq

## Get the 2D distance from the feature center to a world position (XZ plane).
func get_distance_2d(world_pos: Vector3) -> float:
	var diff = world_pos - world_position
	return sqrt(diff.x * diff.x + diff.z * diff.z)

## Get the influence weight at a world position based on distance and falloff.
## Returns 0.0 outside influence area, 1.0 at center, with smooth falloff.
func get_influence_weight(world_pos: Vector3) -> float:
	var local_pos = to_local(world_pos)
	
	var normalized_distance: float
	
	match influence_shape:
		TerrainFeatureNode.InfluenceShape.CIRCLE:
			var distance_2d = Vector2(local_pos.x, local_pos.z).length()
			normalized_distance = distance_2d / max(influence_radius, 0.0001)
		
		TerrainFeatureNode.InfluenceShape.RECTANGLE:
			var dx = abs(local_pos.x) / max(influence_size.x * 0.5, 0.0001)
			var dz = abs(local_pos.z) / max(influence_size.y * 0.5, 0.0001)
			normalized_distance = max(dx, dz)
		
		TerrainFeatureNode.InfluenceShape.ELLIPSE:
			var dx = local_pos.x / max(influence_size.x * 0.5, 0.0001)
			var dz = local_pos.z / max(influence_size.y * 0.5, 0.0001)
			normalized_distance = sqrt(dx * dx + dz * dz)
		
		_:
			normalized_distance = 0.0
	
	if normalized_distance >= 1.0:
		return 0.0
	
	if edge_falloff > 0.0:
		var falloff_start = 1.0 - edge_falloff
		if normalized_distance > falloff_start:
			var t = (normalized_distance - falloff_start) / edge_falloff
			return 1.0 - smoothstep(0.0, 1.0, t)
	
	return 1.0

## Get influence weight for 3D shapes (used by rotated holes).
## Considers all three local axes for proper rotation support.
func get_influence_weight_3d(world_pos: Vector3, shape_size: Vector3) -> float:
	var local_pos = to_local(world_pos)
	
	var normalized_distance: float
	
	match influence_shape:
		TerrainFeatureNode.InfluenceShape.CIRCLE:
			var distance_3d = local_pos.length()
			normalized_distance = distance_3d / max(influence_radius, max(shape_size.x, max(shape_size.y, shape_size.z)) * 0.5)
		
		TerrainFeatureNode.InfluenceShape.RECTANGLE:
			var dx = abs(local_pos.x) / (shape_size.x / 2.0)
			var dy = abs(local_pos.y) / (shape_size.y / 2.0)
			var dz = abs(local_pos.z) / (shape_size.z / 2.0)
			normalized_distance = max(max(dx, dy), dz)
		
		TerrainFeatureNode.InfluenceShape.ELLIPSE:
			var dx = local_pos.x / (shape_size.x / 2.0)
			var dy = local_pos.y / (shape_size.y / 2.0)
			var dz = local_pos.z / (shape_size.z / 2.0)
			normalized_distance = sqrt(dx * dx + dy * dy + dz * dz)
		
		_:
			normalized_distance = 0.0
	
	if normalized_distance >= 1.0:
		return 0.0
	
	if edge_falloff > 0.0:
		var falloff_start = 1.0 - edge_falloff
		if normalized_distance > falloff_start:
			var t = (normalized_distance - falloff_start) / edge_falloff
			return 1.0 - smoothstep(0.0, 1.0, t)
	
	return 1.0
