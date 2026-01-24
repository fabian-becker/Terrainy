@tool
class_name RadialGradientNode
extends GradientNode

const GradientNode = preload("res://addons/terrainy/nodes/gradients/gradient_node.gd")

## Radial gradient from center outward

@export_enum("Linear", "Smooth", "Spherical", "Inverse") var falloff_type: int = 1:
	set(value):
		falloff_type = value
		_commit_parameter_change()

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

func prepare_evaluation_context() -> GradientEvaluationContext:
	return GradientEvaluationContext.from_gradient_feature(self, start_height, end_height, falloff_type)

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as GradientEvaluationContext
	var radius = ctx.influence_radius
	if radius <= 0.0:
		return ctx.end_height
	var distance_2d = Vector2(
		world_pos.x - ctx.world_position.x,
		world_pos.z - ctx.world_position.z
	).length()
	var normalized_distance = distance_2d / radius
	
	if normalized_distance >= 1.0:
		return ctx.end_height
	var t = 0.0
	
	match ctx.falloff_type:
		0: # Linear
			t = normalized_distance
		1: # Smooth
			t = smoothstep(0.0, 1.0, normalized_distance)
		2: # Spherical
			t = sqrt(normalized_distance)
		3: # Inverse (stronger center)
			t = normalized_distance * normalized_distance
	
	return lerp(ctx.start_height, ctx.end_height, t)
