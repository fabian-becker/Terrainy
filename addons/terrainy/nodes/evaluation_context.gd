@tool
class_name EvaluationContext
extends RefCounted

## Thread-safe immutable snapshot of terrain feature transform and influence data.
## Used for evaluating terrain features in worker threads without scene tree access.

## World position of the feature
var world_position: Vector3

## Pre-computed inverse transform for world→local conversion
var inverse_transform: Transform3D

## Influence radius (max of width/depth)
var influence_radius: float

## Pre-computed squared radius for fast distance checks
var influence_radius_sq: float

## Pre-computed AABB for fast spatial culling
var aabb: AABB

## Influence shape type
var influence_shape: int

## Influence size (width, depth)
var influence_size: Vector2

## Edge falloff parameter
var edge_falloff: float

## Feature strength/weight
var strength: float

## Blend mode
var blend_mode: int

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
	ctx.influence_radius = max(feature.influence_size.x, feature.influence_size.y)
	ctx.influence_radius_sq = ctx.influence_radius * ctx.influence_radius
	
	# Capture blend parameters
	ctx.edge_falloff = feature.edge_falloff
	ctx.strength = feature.strength
	ctx.blend_mode = feature.blend_mode
	
	# Pre-compute AABB for spatial culling
	var half_size = Vector3(ctx.influence_radius, 1000.0, ctx.influence_radius)
	ctx.aabb = AABB(ctx.world_position - half_size, half_size * 2.0)
	
	return ctx

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
	
	# Calculate normalized distance based on shape
	var normalized_distance: float
	
	match influence_shape:
		TerrainFeatureNode.InfluenceShape.CIRCLE:
			var distance_2d = Vector2(local_pos.x, local_pos.z).length()
			normalized_distance = distance_2d / influence_radius
		
		TerrainFeatureNode.InfluenceShape.RECTANGLE:
			var dx = abs(local_pos.x) / (influence_size.x / 2.0)
			var dz = abs(local_pos.z) / (influence_size.y / 2.0)
			normalized_distance = max(dx, dz)
		
		TerrainFeatureNode.InfluenceShape.ELLIPSE:
			var dx = local_pos.x / (influence_size.x / 2.0)
			var dz = local_pos.z / (influence_size.y / 2.0)
			normalized_distance = sqrt(dx * dx + dz * dz)
		
		_:
			normalized_distance = 0.0
	
	# Outside influence area
	if normalized_distance >= 1.0:
		return 0.0
	
	# Apply edge falloff
	if edge_falloff > 0.0:
		var falloff_start = 1.0 - edge_falloff
		if normalized_distance > falloff_start:
			var t = (normalized_distance - falloff_start) / edge_falloff
			return 1.0 - smoothstep(0.0, 1.0, t)
	
	return 1.0
