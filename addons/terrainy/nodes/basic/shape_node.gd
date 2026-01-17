@tool
class_name ShapeNode
extends TerrainFeatureNode

const TerrainFeatureNode = "res://addons/terrainy/nodes/terrain_feature_node.gd"

## Basic geometric shape as height stamp

@export var shape_height: float = 10.0:
	set(value):
		shape_height = value
		parameters_changed.emit()

@export_enum("Circle", "Square", "Diamond", "Star", "Cross") var shape_type: int = 0:
	set(value):
		shape_type = value
		parameters_changed.emit()

@export var smoothness: float = 0.1:
	set(value):
		smoothness = clamp(value, 0.0, 0.5)
		parameters_changed.emit()

@export var shape_rotation: float = 0.0:
	set(value):
		shape_rotation = value
		parameters_changed.emit()

func get_height_at(world_pos: Vector3) -> float:
	var local_pos = to_local(world_pos)
	var pos_2d = Vector2(local_pos.x, local_pos.z)
	
	# Apply rotation
	if shape_rotation != 0.0:
		var angle = deg_to_rad(shape_rotation)
		var cos_a = cos(angle)
		var sin_a = sin(angle)
		pos_2d = Vector2(
			pos_2d.x * cos_a - pos_2d.y * sin_a,
			pos_2d.x * sin_a + pos_2d.y * cos_a
		)
	
	var distance = _calculate_shape_distance(pos_2d)
	var radius = influence_size.x
	
	if distance >= radius:
		return 0.0
	
	# Smooth falloff at edges
	var edge_start = radius * (1.0 - smoothness)
	var height_factor = 1.0
	
	if distance > edge_start:
		var edge_t = (distance - edge_start) / (radius - edge_start)
		height_factor = 1.0 - smoothstep(0.0, 1.0, edge_t)
	
	return shape_height * height_factor

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
