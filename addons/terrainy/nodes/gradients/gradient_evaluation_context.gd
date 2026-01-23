@tool
class_name GradientEvaluationContext
extends EvaluationContext

## Specialized context for gradient-based terrain features.
## Captures gradient parameters for thread-safe evaluation.

## Starting height value
var start_height: float

## Ending height value
var end_height: float

## Gradient vector for linear gradients (world space, normalized)
var gradient_vector: Vector2

## Falloff type (0=linear, 1=smooth, 2=spherical, etc.)
var falloff_type: int

## Additional gradient parameters
var gradient_center: Vector3  # For radial gradients
var gradient_radius: float = 100.0  # For radial gradients
var cone_angle: float = 45.0  # For cone gradients (in degrees)
var cone_height: float = 100.0  # For cone gradients
var interpolation: int = 0  # For linear gradients
var sharpness: float = 1.0  # For cone gradients
var flatness: float = 0.0  # For hemisphere gradients

## Create a GradientEvaluationContext from a terrain feature node.
static func from_gradient_feature(feature: TerrainFeatureNode, start_h: float, end_h: float, falloff: int = 0) -> GradientEvaluationContext:
	var ctx = GradientEvaluationContext.new()
	
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
	
	# Add gradient-specific properties
	ctx.start_height = start_h
	ctx.end_height = end_h
	ctx.falloff_type = falloff
	ctx.gradient_center = feature.global_position
	
	# Try to get gradient direction if available
	if "direction" in feature:
		var dir = feature.get("direction")
		if dir is Vector2:
			ctx.gradient_vector = dir.normalized()
		elif dir is Vector3:
			ctx.gradient_vector = Vector2(dir.x, dir.z).normalized()
	else:
		ctx.gradient_vector = Vector2(1, 0)  # Default to X-axis
	
	# Get radius/angle/height if available
	if "gradient_radius" in feature:
		ctx.gradient_radius = feature.get("gradient_radius")
	if "cone_angle" in feature:
		ctx.cone_angle = feature.get("cone_angle")
	if "cone_height" in feature:
		ctx.cone_height = feature.get("cone_height")
	if "interpolation" in feature:
		ctx.interpolation = feature.get("interpolation")
	if "sharpness" in feature:
		ctx.sharpness = feature.get("sharpness")
	if "flatness" in feature:
		ctx.flatness = feature.get("flatness")
	
	return ctx

## Calculate linear gradient value based on position along gradient direction.
## Returns 0.0 to 1.0 representing progress along the gradient.
func get_linear_gradient_t(world_pos: Vector3) -> float:
	var local_pos = to_local(world_pos)
	var pos_2d = Vector2(local_pos.x, local_pos.z)
	
	# Project position onto gradient direction
	var distance_along = pos_2d.dot(gradient_vector)
	
	# Normalize to 0-1 range based on influence size
	var max_distance = influence_radius
	var t = (distance_along + max_distance) / (2.0 * max_distance)
	
	return clamp(t, 0.0, 1.0)

## Calculate radial gradient value based on distance from center.
## Returns 0.0 at center to 1.0 at gradient_radius.
func get_radial_gradient_t(world_pos: Vector3) -> float:
	var distance = world_pos.distance_to(gradient_center)
	var t = distance / gradient_radius
	return clamp(t, 0.0, 1.0)

## Calculate cone gradient value based on height and distance from apex.
## Returns 0.0 at apex to 1.0 at base.
func get_cone_gradient_t(world_pos: Vector3) -> float:
	# Height difference from apex
	var height_diff = gradient_center.y - world_pos.y
	
	if height_diff <= 0.0:
		return 0.0
	if height_diff >= cone_height:
		return 1.0
	
	# Calculate expected radius at this height based on cone angle
	var angle_rad = deg_to_rad(cone_angle)
	var expected_radius = height_diff * tan(angle_rad)
	
	# Distance from cone axis (XZ plane)
	var horizontal_dist = Vector2(
		world_pos.x - gradient_center.x,
		world_pos.z - gradient_center.z
	).length()
	
	# Normalize by expected radius
	if expected_radius < 0.001:
		return 0.0
	
	var t = horizontal_dist / expected_radius
	return clamp(t, 0.0, 1.0)

## Apply falloff curve to a normalized gradient value (0-1).
func apply_falloff(t: float) -> float:
	match falloff_type:
		0: # Linear
			return t
		1: # Smooth (smoothstep)
			return smoothstep(0.0, 1.0, t)
		2: # Spherical (quadratic)
			return t * t
		3: # Inverse spherical
			return sqrt(t)
		_:
			return t

## Get interpolated height value at position t (0-1).
func get_height_at_t(t: float) -> float:
	var adjusted_t = apply_falloff(t)
	return lerp(start_height, end_height, adjusted_t)
