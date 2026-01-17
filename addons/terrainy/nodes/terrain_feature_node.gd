@tool
class_name TerrainFeatureNode
extends Node3D

## Base class for all terrain feature nodes that can be positioned and blended

signal parameters_changed

## The size of this terrain feature's area of influence
@export var influence_radius: float = 50.0:
	set(value):
		influence_radius = value
		parameters_changed.emit()

## Falloff distance for blending at edges (0.0 = hard edge, 1.0 = smooth across full radius)
@export_range(0.0, 1.0) var edge_falloff: float = 0.3:
	set(value):
		edge_falloff = value
		parameters_changed.emit()

## Blend mode with other terrain features
@export_enum("Add", "Max", "Min", "Multiply", "Average") var blend_mode: int = 0:
	set(value):
		blend_mode = value
		parameters_changed.emit()

## Weight/strength of this feature (0.0 = invisible, 1.0 = full strength)
@export_range(0.0, 2.0) var strength: float = 1.0:
	set(value):
		strength = value
		parameters_changed.emit()

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
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	
	if distance_2d >= influence_radius:
		return 0.0
	
	if edge_falloff <= 0.0:
		return 1.0
	
	# Calculate falloff
	var falloff_start = influence_radius * (1.0 - edge_falloff)
	if distance_2d < falloff_start:
		return 1.0
	
	# Smooth falloff using smoothstep
	var t = (distance_2d - falloff_start) / (influence_radius - falloff_start)
	return 1.0 - smoothstep(0.0, 1.0, t)

## Get the final blended height contribution at a position
func get_blended_height_at(world_pos: Vector3) -> float:
	var height = get_height_at(world_pos)
	var weight = get_influence_weight(world_pos)
	return height * weight * strength

## Get axis-aligned bounding box of influence area
func get_influence_aabb() -> AABB:
	var size = influence_radius * 2.0
	return AABB(
		global_position + Vector3(-influence_radius, -100, -influence_radius),
		Vector3(size, 200, size)
	)
