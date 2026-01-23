@tool
class_name ConeNode
extends GradientNode

const GradientNode = preload("res://addons/terrainy/nodes/gradients/gradient_node.gd")

## Sharp cone shape

@export var sharpness: float = 1.0:
	set(value):
		sharpness = clamp(value, 0.1, 4.0)
		parameters_changed.emit()

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

func prepare_evaluation_context() -> GradientEvaluationContext:
	var ctx = GradientEvaluationContext.from_gradient_feature(self, start_height, end_height)
	ctx.sharpness = sharpness
	return ctx

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as GradientEvaluationContext
	var local_pos = ctx.to_local(world_pos)
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	var radius = ctx.influence_size.x
	
	if distance_2d >= radius:
		return ctx.end_height
	
	var normalized_distance = distance_2d / radius
	var height_factor = pow(1.0 - normalized_distance, ctx.sharpness)
	
	return lerp(ctx.end_height, ctx.start_height, height_factor)
