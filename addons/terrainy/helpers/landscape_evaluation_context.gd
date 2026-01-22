@tool
class_name LandscapeEvaluationContext
extends EvaluationContext

## Specialized context for landscape terrain features (mountain ranges, canyons, dunes).
## Captures directional and noise parameters for thread-safe evaluation.

## Direction vector (normalized, in local 2D space XZ)
var direction: Vector2

## Perpendicular vector (pre-computed, normalized)
var perpendicular: Vector2

## Height of the landscape feature
var height: float

## Primary noise generator for major terrain features
var primary_noise: FastNoiseLite

## Detail noise generator for finer surface variation (optional)
var detail_noise: FastNoiseLite

## Additional landscape-specific parameters
var ridge_sharpness: float = 2.0
var peak_variation: float = 0.5
var canyon_width: float = 50.0
var canyon_wall_slope: float = 1.0
var canyon_meander_strength: float = 0.3
var dune_frequency: float = 0.1
var dune_asymmetry: float = 0.7

## Create a LandscapeEvaluationContext from a terrain feature node.
static func from_landscape_feature(feature: TerrainFeatureNode, feature_height: float, dir: Vector2) -> LandscapeEvaluationContext:
	var ctx = LandscapeEvaluationContext.new()
	
	# Copy base context properties
	ctx.world_position = feature.global_position
	ctx.inverse_transform = feature.global_transform.affine_inverse()
	ctx.influence_shape = feature.influence_shape
	ctx.influence_size = feature.influence_size
	ctx.influence_radius = max(feature.influence_size.x, feature.influence_size.y)
	ctx.influence_radius_sq = ctx.influence_radius * ctx.influence_radius
	ctx.edge_falloff = feature.edge_falloff
	ctx.strength = feature.strength
	ctx.blend_mode = feature.blend_mode
	
	var half_size = Vector3(ctx.influence_radius, 1000.0, ctx.influence_radius)
	ctx.aabb = AABB(ctx.world_position - half_size, half_size * 2.0)
	
	# Add landscape-specific properties
	ctx.height = feature_height
	ctx.direction = dir.normalized()
	ctx.perpendicular = Vector2(-ctx.direction.y, ctx.direction.x)
	
	# Try to get noise generators
	if "noise" in feature and feature.get("noise") is FastNoiseLite:
		ctx.primary_noise = feature.get("noise")
	
	if "detail_noise" in feature and feature.get("detail_noise") is FastNoiseLite:
		ctx.detail_noise = feature.get("detail_noise")
	
	# Copy additional parameters if they exist
	if "ridge_sharpness" in feature:
		ctx.ridge_sharpness = feature.get("ridge_sharpness")
	if "peak_variation" in feature:
		ctx.peak_variation = feature.get("peak_variation")
	if "canyon_width" in feature:
		ctx.canyon_width = feature.get("canyon_width")
	if "wall_slope" in feature:
		ctx.canyon_wall_slope = feature.get("wall_slope")
	if "meander_strength" in feature:
		ctx.canyon_meander_strength = feature.get("meander_strength")
	if "dune_frequency" in feature:
		ctx.dune_frequency = feature.get("dune_frequency")
	if "asymmetry" in feature:
		ctx.dune_asymmetry = feature.get("asymmetry")
	
	return ctx

## Get the distance along the directional axis (e.g., along a ridge or canyon).
func get_distance_along(local_pos: Vector3) -> float:
	var pos_2d = Vector2(local_pos.x, local_pos.z)
	return pos_2d.dot(direction)

## Get the distance perpendicular to the directional axis (e.g., distance from ridge center).
func get_distance_perpendicular(local_pos: Vector3) -> float:
	var pos_2d = Vector2(local_pos.x, local_pos.z)
	return pos_2d.dot(perpendicular)

## Get the absolute lateral distance from the centerline.
func get_lateral_distance(local_pos: Vector3) -> float:
	return abs(get_distance_perpendicular(local_pos))

## Get primary noise value at a world position (thread-safe).
func get_primary_noise(world_pos: Vector3) -> float:
	if not primary_noise:
		return 0.0
	return primary_noise.get_noise_2d(world_pos.x, world_pos.z)

## Get detail noise value at a world position (thread-safe).
func get_detail_noise(world_pos: Vector3) -> float:
	if not detail_noise:
		return 0.0
	return detail_noise.get_noise_2d(world_pos.x, world_pos.z)
