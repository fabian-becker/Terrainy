@tool
class_name PrimitiveEvaluationContext
extends EvaluationContext

## Specialized context for primitive terrain features (hills, craters, volcanoes, etc.).
## Captures shape-specific parameters for thread-safe evaluation.

## Height of the primitive feature
var height: float

## Shape mode (for hills: 0=smooth, 1=cone, 2=dome, etc.)
var shape_mode: int

## Optional noise for surface detail
var noise: FastNoiseLite

## Strength of noise detail (0.0 = no noise, 1.0 = full noise)
var noise_strength: float = 0.0

## Additional parameters for specific primitives
var crater_floor_radius_ratio: float = 0.0
var crater_rim_width: float = 0.0
var volcano_crater_radius_ratio: float = 0.0
var volcano_crater_depth: float = 0.0
var volcano_slope_concavity: float = 1.0
var island_beach_width: float = 0.0
var island_beach_height: float = 0.0
var mountain_peak_type: int = 0

## Create a PrimitiveEvaluationContext from a terrain feature node.
static func from_primitive_feature(feature: TerrainFeatureNode, feature_height: float, shape: int = 0) -> PrimitiveEvaluationContext:
	var ctx = PrimitiveEvaluationContext.new()
	
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
	
	# Add primitive-specific properties
	ctx.height = feature_height
	ctx.shape_mode = shape
	
	# Try to get noise if the feature has it
	if "noise" in feature and feature.get("noise") is FastNoiseLite:
		ctx.noise = feature.get("noise")
		if "noise_strength" in feature:
			ctx.noise_strength = feature.get("noise_strength")
	
	return ctx

## Get noise detail value at a world position (thread-safe).
func get_noise_detail(world_pos: Vector3) -> float:
	if not noise or noise_strength <= 0.0:
		return 0.0
	
	var noise_value = noise.get_noise_2d(world_pos.x, world_pos.z)
	return noise_value * noise_strength

## Calculate height multiplier based on normalized distance and shape mode.
## Returns 0.0 to 1.0 based on the shape profile.
func get_shape_multiplier(normalized_distance: float) -> float:
	if normalized_distance >= 1.0:
		return 0.0
	
	match shape_mode:
		0: # Smooth (cosine curve)
			var multiplier = cos(normalized_distance * PI * 0.5)
			return multiplier * multiplier
		1: # Cone (linear)
			return 1.0 - normalized_distance
		2: # Dome (circular arc)
			return sqrt(1.0 - normalized_distance * normalized_distance)
		_:
			return 1.0 - normalized_distance
