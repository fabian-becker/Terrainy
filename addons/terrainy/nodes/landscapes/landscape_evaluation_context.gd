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
var ridge_meander: float = 0.0
var peak_prominence: float = 0.0
var foothill_strength: float = 0.0
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
	ctx.influence_radius = EvaluationContext.get_influence_radius(ctx.influence_shape, ctx.influence_size)
	ctx.influence_radius_sq = ctx.influence_radius * ctx.influence_radius
	ctx.edge_falloff = feature.edge_falloff
	ctx.strength = feature.strength
	ctx.blend_mode = feature.blend_mode
	
	ctx.aabb = EvaluationContext.compute_rotation_aware_aabb(feature.global_transform, ctx.world_position, ctx.influence_shape, ctx.influence_size)
	
	# Add landscape-specific properties
	ctx.height = feature_height
	ctx.direction = dir.normalized()
	ctx.perpendicular = Vector2(-ctx.direction.y, ctx.direction.x)
	
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

## Half-extent of the influence shape projected onto a local 2D axis.
## This is the support function of the shape along `axis`, i.e. how far the
## shape reaches in that direction. Used for ridge width / range length that
## stay correct no matter which way `direction` points.
func get_extent_along(axis: Vector2) -> float:
	var half_x = influence_size.x * 0.5
	var half_y = influence_size.y * 0.5
	match influence_shape:
		TerrainFeatureNode.InfluenceShape.CIRCLE:
			return influence_radius
		TerrainFeatureNode.InfluenceShape.ELLIPSE:
			return sqrt((half_x * axis.x) * (half_x * axis.x) + (half_y * axis.y) * (half_y * axis.y))
		_:
			return abs(half_x * axis.x) + abs(half_y * axis.y)

## Get normalized distance from center based on influence shape.
## Returns 0 at center, 1 at edge, >1 outside.
func get_influence_normalized_distance(local_pos: Vector3) -> float:
	match influence_shape:
		TerrainFeatureNode.InfluenceShape.CIRCLE:
			var radius = max(influence_radius, 0.0001)
			return Vector2(local_pos.x, local_pos.z).length() / radius
		TerrainFeatureNode.InfluenceShape.RECTANGLE:
			var half_size = influence_size * 0.5
			if half_size.x <= 0.0 or half_size.y <= 0.0:
				return INF
			return max(abs(local_pos.x) / half_size.x, abs(local_pos.z) / half_size.y)
		TerrainFeatureNode.InfluenceShape.ELLIPSE:
			var half_size = influence_size * 0.5
			if half_size.x <= 0.0 or half_size.y <= 0.0:
				return INF
			var nx = local_pos.x / half_size.x
			var nz = local_pos.z / half_size.y
			return sqrt(nx * nx + nz * nz)
		_:
			return 0.0

## Check if a local position is inside the influence shape.
func is_inside_influence(local_pos: Vector3) -> bool:
	return get_influence_normalized_distance(local_pos) < 1.0

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
