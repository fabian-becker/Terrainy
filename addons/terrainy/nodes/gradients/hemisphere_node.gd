@tool
class_name HemisphereNode
extends GradientNode

const GradientNode = preload("res://addons/terrainy/nodes/gradients/gradient_node.gd")

## Smooth hemisphere/dome shape

@export var flatness: float = 0.0:
	set(value):
		flatness = clamp(value, 0.0, 0.8)
		parameters_changed.emit()

func get_height_at(world_pos: Vector3) -> float:
	var local_pos = to_local(world_pos)
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	var radius = influence_size.x
	
	if distance_2d >= radius:
		return end_height
	
	var normalized_distance = distance_2d / radius
	
	# Spherical dome calculation
	var height_factor = sqrt(1.0 - normalized_distance * normalized_distance)
	
	# Apply flatness (makes top more plateau-like)
	if flatness > 0.0 and normalized_distance < flatness:
		height_factor = sqrt(1.0 - flatness * flatness)
	
	return end_height + start_height * height_factor
