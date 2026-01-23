@tool
class_name ShapeNode
extends TerrainFeatureNode

const TerrainFeatureNode = "res://addons/terrainy/nodes/terrain_feature_node.gd"
const ShapeEvaluationContext = preload("res://addons/terrainy/nodes/basic/shape_evaluation_context.gd")

## Basic geometric shape as height stamp

@export var shape_height: float = 10.0:
	set(value):
		shape_height = value
		_commit_parameter_change()

@export_enum("Circle", "Square", "Diamond", "Star", "Cross") var shape_type: int = 0:
	set(value):
		shape_type = value
		_commit_parameter_change()

@export var smoothness: float = 0.1:
	set(value):
		smoothness = clamp(value, 0.0, 0.5)
		_commit_parameter_change()

@export var shape_rotation: float = 0.0:
	set(value):
		shape_rotation = value
		_commit_parameter_change()

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

func prepare_evaluation_context() -> ShapeEvaluationContext:
	return ShapeEvaluationContext.from_shape_feature(
		self,
		shape_height,
		shape_type,
		smoothness,
		deg_to_rad(shape_rotation)
	)

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as ShapeEvaluationContext
	var local_pos = ctx.to_local(world_pos)
	var pos_2d = Vector2(local_pos.x, local_pos.z)
	
	# Apply rotation
	if abs(ctx.rotation_angle) > 0.001:
		pos_2d = ctx.rotate_point_2d(pos_2d)
	
	var distance = _calculate_shape_distance_safe(pos_2d, ctx)
	var radius = ctx.influence_size.x
	
	if distance >= radius:
		return 0.0
	
	# Smooth falloff at edges
	var edge_start = radius * (1.0 - ctx.smoothness)
	var height_factor = 1.0
	
	if distance > edge_start and radius > edge_start:
		var edge_t = (distance - edge_start) / (radius - edge_start)
		height_factor = 1.0 - smoothstep(0.0, 1.0, edge_t)
	
	return ctx.shape_height * height_factor

func _calculate_shape_distance_safe(pos: Vector2, context: ShapeEvaluationContext) -> float:
	var abs_pos = Vector2(abs(pos.x), abs(pos.y))
	var radius = context.influence_size.x
	
	match context.shape_type:
		0: # Circle
			return pos.length()
		1: # Square
			return max(abs_pos.x, abs_pos.y)
		2: # Diamond
			return abs_pos.x + abs_pos.y
		3: # Star (5-pointed approximation)
			var angle = atan2(pos.y, pos.x)
			var star_radius = radius * (0.6 + 0.4 * abs(sin(angle * 2.5)))
			return pos.length() / star_radius * radius
		4: # Cross
			return min(abs_pos.x, abs_pos.y) * 2.0 + max(abs_pos.x, abs_pos.y) * 0.5
	
	return pos.length()

func _calculate_shape_distance(pos: Vector2) -> float:
	var abs_pos = Vector2(abs(pos.x), abs(pos.y))
	var radius = influence_size.x
	
	match shape_type:
		0: # Circle
			return pos.length()
		1: # Square
			return max(abs_pos.x, abs_pos.y)
		2: # Diamond
			return abs_pos.x + abs_pos.y
		3: # Star (5-pointed approximation)
			var angle = atan2(pos.y, pos.x)
			var star_radius = radius * (0.6 + 0.4 * abs(sin(angle * 2.5)))
			return pos.length() / star_radius * radius
		4: # Cross
			return min(abs_pos.x, abs_pos.y) * 2.0 + max(abs_pos.x, abs_pos.y) * 0.5
	
	return pos.length()
