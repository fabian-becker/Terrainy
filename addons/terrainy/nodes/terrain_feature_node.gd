@tool
class_name TerrainFeatureNode
extends Node3D

## Base class for all terrain feature nodes that can be positioned and blended

signal parameters_changed

enum InfluenceShape {
	CIRCLE,
	RECTANGLE,
	ELLIPSE
}

## Shape of the influence area
@export var influence_shape: InfluenceShape = InfluenceShape.CIRCLE:
	set(value):
		influence_shape = value
		_commit_parameter_change()

## The size of this terrain feature's area of influence (radius for circle, width/depth for others)
@export var influence_size: Vector2 = Vector2(50.0, 50.0):
	set(value):
		influence_size = value
		_commit_parameter_change()

## Falloff distance for blending at edges (0.0 = hard edge, 1.0 = smooth across full radius)
@export_range(0.0, 1.0) var edge_falloff: float = 0.3:
	set(value):
		edge_falloff = value
		_commit_parameter_change()

## Blend mode with other terrain features
@export_enum("Add", "Max", "Min", "Multiply", "Average") var blend_mode: int = 0:
	set(value):
		blend_mode = value
		_commit_parameter_change()

## Weight/strength of this feature (0.0 = invisible, 1.0 = full strength)
@export_range(0.0, 2.0) var strength: float = 1.0:
	set(value):
		strength = value
		_commit_parameter_change()

## Generate height value at a given world position
## Override this in derived classes
func get_height_at(world_pos: Vector3) -> float:
	return 0.0

## Get the influence weight at a given world position (0.0 to 1.0)
## Based on distance from center and falloff settings
func get_influence_weight(world_pos: Vector3) -> float:
	if not is_inside_tree():
		return 0.0
	
	var local_pos = to_local(world_pos)
	var local_pos_2d = Vector2(local_pos.x, local_pos.z)
	
	var distance: float
	var max_distance: float
	
	match influence_shape:
		InfluenceShape.CIRCLE:
			# Use X component as radius for circular shape
			distance = local_pos_2d.length()
			max_distance = influence_size.x
		
		InfluenceShape.RECTANGLE:
			# Check if inside rectangle bounds
			var half_size = influence_size * 0.5
			if abs(local_pos_2d.x) > half_size.x or abs(local_pos_2d.y) > half_size.y:
				return 0.0
			
			# Distance to nearest edge
			var dist_x = half_size.x - abs(local_pos_2d.x)
			var dist_y = half_size.y - abs(local_pos_2d.y)
			distance = min(dist_x, dist_y)
			max_distance = min(half_size.x, half_size.y)
		
		InfluenceShape.ELLIPSE:
			# Ellipse distance formula
			var normalized = Vector2(
				local_pos_2d.x / influence_size.x,
				local_pos_2d.y / influence_size.y
			)
			distance = normalized.length()
			max_distance = 1.0
			
			if distance >= max_distance:
				return 0.0
	
	if influence_shape == InfluenceShape.CIRCLE or influence_shape == InfluenceShape.ELLIPSE:
		if distance >= max_distance:
			return 0.0
	
	if edge_falloff <= 0.0:
		return 1.0
	
	# Calculate falloff
	var falloff_distance: float
	if influence_shape == InfluenceShape.RECTANGLE:
		# For rectangle, distance is already the distance to edge
		falloff_distance = max_distance * edge_falloff
		if distance > falloff_distance:
			return 1.0
		var t = distance / falloff_distance
		return smoothstep(0.0, 1.0, t)
	else:
		# For circle and ellipse
		var falloff_start = max_distance * (1.0 - edge_falloff)
		if distance < falloff_start:
			return 1.0
		var t = (distance - falloff_start) / (max_distance - falloff_start)
		return 1.0 - smoothstep(0.0, 1.0, t)

## Get the final blended height contribution at a position
func get_blended_height_at(world_pos: Vector3) -> float:
	var height = get_height_at(world_pos)
	var weight = get_influence_weight(world_pos)
	return height * weight * strength

## Get axis-aligned bounding box of influence area
func get_influence_aabb() -> AABB:
	var half_size: Vector2
	if influence_shape == InfluenceShape.CIRCLE:
		half_size = Vector2(influence_size.x, influence_size.x)
	else:
		half_size = influence_size * 0.5
	
	return AABB(
		global_position + Vector3(-half_size.x, -100, -half_size.y),
		Vector3(half_size.x * 2.0, 200, half_size.y * 2.0)
	)

## Helper to check if gizmo is currently manipulating this node
func _is_gizmo_manipulating() -> bool:
	var is_manipulating = get_meta("_gizmo_manipulating", false)
	
	# Safety: if gizmo manipulation flag has been set for more than 5 seconds, clear it
	# This prevents stuck metadata from blocking updates
	if is_manipulating:
		var last_gizmo_time = get_meta("_gizmo_manipulation_time", 0.0)
		var current_time = Time.get_ticks_msec() / 1000.0
		if current_time - last_gizmo_time > 5.0:
			set_meta("_gizmo_manipulating", false)
			return false
	
	return is_manipulating

## Helper to emit parameters_changed signal only when not manipulating via gizmo
func _commit_parameter_change() -> void:
	if not _is_gizmo_manipulating():
		parameters_changed.emit()
		if Engine.is_editor_hint():
			print("[%s] parameters_changed emitted" % name)
