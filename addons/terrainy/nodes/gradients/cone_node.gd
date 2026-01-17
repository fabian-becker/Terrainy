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
	var local_pos = to_local(world_pos)
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	var radius = influence_size.x
	
	if distance_2d >= radius:
		return end_height
	
	var normalized_distance = distance_2d / radius
	var height_factor = pow(1.0 - normalized_distance, sharpness)
	
	return lerp(end_height, start_height, height_factor)
