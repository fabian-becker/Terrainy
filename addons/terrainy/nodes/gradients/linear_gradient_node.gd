@tool
class_name LinearGradientNode
extends GradientNode

const GradientNode = preload("res://addons/terrainy/nodes/gradients/gradient_node.gd")

## Linear gradient in a specified direction

@export var direction: Vector2 = Vector2(1, 0):
	set(value):
		direction = value.normalized()
		_commit_parameter_change()

@export_enum("Linear", "Smooth", "Ease In", "Ease Out") var interpolation: int = 1:
	set(value):
		interpolation = value
		_commit_parameter_change()

func get_height_at(world_pos: Vector3) -> float:
	var local_pos = to_local(world_pos)
	var pos_2d = Vector2(local_pos.x, local_pos.z)
	
	# Project position onto gradient direction
	var projected = pos_2d.dot(direction)
	
	# Normalize to influence radius
	var radius = influence_size.x
	var t = (projected + radius) / (radius * 2.0)
	t = clamp(t, 0.0, 1.0)
	
	# Apply interpolation
	match interpolation:
		0: # Linear
			pass
		1: # Smooth
			t = smoothstep(0.0, 1.0, t)
		2: # Ease In
			t = t * t
		3: # Ease Out
			t = 1.0 - (1.0 - t) * (1.0 - t)
	
	return lerp(start_height, end_height, t)
	
	return lerp(start_height, end_height, t)
