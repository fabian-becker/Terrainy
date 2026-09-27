@tool
class_name WaterEvaluationContext
extends EvaluationContext

## Specialized context for water nodes.
## Captures water-specific parameters for thread-safe evaluation.

## Height of the water surface
var water_level: float = 0.0

## How deep to carve below water_level
var carve_depth: float = 10.0

## Shore gradient (0=cliff, 1=gradual slope)
var shore_slope: float = 0.3

## How flat the lake bottom is (0=varying, 1=completely flat)
var bottom_flatness: float = 0.5

## Create a WaterEvaluationContext from a WaterNode.
static func from_water_feature(feature: WaterNode) -> WaterEvaluationContext:
	var ctx = WaterEvaluationContext.new()
	
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
	
	ctx.water_level = feature.water_level
	ctx.carve_depth = feature.carve_depth
	ctx.shore_slope = feature.shore_slope
	ctx.bottom_flatness = feature.bottom_flatness
	
	return ctx