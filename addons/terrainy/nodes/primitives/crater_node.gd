@tool
class_name CraterNode
extends PrimitiveNode

const PrimitiveNode = preload("res://addons/terrainy/nodes/primitives/primitive_node.gd")

## A crater terrain feature with rim and depression

@export var rim_height: float = 3.0:
	set(value):
		rim_height = value
		parameters_changed.emit()

@export var rim_width: float = 0.15:
	set(value):
		rim_width = clamp(value, 0.01, 0.5)
		parameters_changed.emit()

@export var floor_radius_ratio: float = 0.6:
	set(value):
		floor_radius_ratio = clamp(value, 0.1, 0.95)
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
	var floor_radius = radius * floor_radius_ratio
	
	var result_height = 0.0
	
	# Flat crater floor
	if distance_2d < floor_radius:
		result_height = -height
	else:
		# Rim and slope
		var slope_distance = (distance_2d - floor_radius) / (radius - floor_radius)
		
		# Create rim peak
		var rim_peak_pos = rim_width
		if slope_distance < rim_peak_pos:
			# Rising to rim
			result_height = lerp(-height, rim_height, slope_distance / rim_peak_pos)
		else:
			# Falling from rim to edge
			var fall_t = (slope_distance - rim_peak_pos) / (1.0 - rim_peak_pos)
			result_height = lerp(rim_height, 0.0, smoothstep(0.0, 1.0, fall_t))
	
	return result_height
