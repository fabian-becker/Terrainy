@tool
class_name VolcanoNode
extends PrimitiveNode

const PrimitiveNode = preload("res://addons/terrainy/nodes/primitives/primitive_node.gd")

## A volcano terrain feature with crater at the peak

@export var crater_radius_ratio: float = 0.2:
	set(value):
		crater_radius_ratio = clamp(value, 0.05, 0.5)
		parameters_changed.emit()

@export var crater_depth: float = 10.0:
	set(value):
		crater_depth = value
		parameters_changed.emit()

@export var slope_concavity: float = 1.2:
	set(value):
		slope_concavity = clamp(value, 0.5, 3.0)
		parameters_changed.emit()

func get_height_at(world_pos: Vector3) -> float:
	var local_pos = to_local(world_pos)
	return get_height_at_safe(world_pos, local_pos)

## Thread-safe version using pre-computed local position
func get_height_at_safe(world_pos: Vector3, local_pos: Vector3) -> float:
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	
	var radius = influence_size.x
	
	if distance_2d >= radius:
		return 0.0
	
	var normalized_distance = distance_2d / radius
	var crater_radius = radius * crater_radius_ratio
	
	var result_height = 0.0
	
	if distance_2d < crater_radius:
		# Inside crater - depression from rim
		var crater_t = distance_2d / crater_radius
		result_height = height - (crater_depth * (1.0 - crater_t * crater_t))
	else:
		# Outer slopes
		var slope_distance = (distance_2d - crater_radius) / (radius - crater_radius)
		result_height = height * pow(1.0 - slope_distance, slope_concavity)
	
	return result_height
