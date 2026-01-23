@tool
class_name HillNode
extends PrimitiveNode

const PrimitiveNode = preload("res://addons/terrainy/nodes/primitives/primitive_node.gd")
const PrimitiveEvaluationContext = preload("res://addons/terrainy/nodes/primitives/primitive_evaluation_context.gd")

## A simple hill terrain feature with various shape options

@export_enum("Smooth", "Cone", "Dome") var shape: int = 0:
	set(value):
		shape = value
		parameters_changed.emit()

func prepare_evaluation_context() -> PrimitiveEvaluationContext:
	return PrimitiveEvaluationContext.from_primitive_feature(self, height, shape)

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as PrimitiveEvaluationContext
	var local_pos = ctx.to_local(world_pos)
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	var radius = ctx.influence_radius
	
	if distance_2d >= radius:
		return 0.0
	
	var normalized_distance = distance_2d / radius
	return ctx.height * ctx.get_shape_multiplier(normalized_distance)
