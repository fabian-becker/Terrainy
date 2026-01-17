@tool
class_name MountainRangeNode
extends LandscapeNode

const LandscapeNode = preload("res://addons/terrainy/nodes/landscapes/landscape_node.gd")

## A mountain range terrain feature
##
## TIP: Mountains can appear very spiky by default. Try using the Modifiers:
## - Set "Smoothing" to MEDIUM or HEAVY for more natural-looking peaks
## - Adjust "Smoothing Radius" to 2.0-4.0 for best results
## - Enable "Terracing" with 8-12 levels for a layered mountain effect

@export var ridge_sharpness: float = 0.5:
	set(value):
		ridge_sharpness = clamp(value, 0.1, 2.0)
		parameters_changed.emit()

@export var peak_noise: FastNoiseLite:
	set(value):
		peak_noise = value
		if peak_noise and not peak_noise.changed.is_connected(_on_noise_changed):
			peak_noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

@export var detail_noise: FastNoiseLite:
	set(value):
		detail_noise = value
		if detail_noise and not detail_noise.changed.is_connected(_on_noise_changed):
			detail_noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

func _ready() -> void:
	if not peak_noise:
		peak_noise = FastNoiseLite.new()
		peak_noise.seed = randi()
		peak_noise.frequency = 0.008
		peak_noise.fractal_octaves = 2
	
	if not detail_noise:
		detail_noise = FastNoiseLite.new()
		detail_noise.seed = randi() + 1000
		detail_noise.frequency = 0.05
		detail_noise.fractal_octaves = 4

func get_height_at(world_pos: Vector3) -> float:
	var local_pos = to_local(world_pos)
	return get_height_at_safe(world_pos, local_pos)

## Thread-safe version using pre-computed local position
func get_height_at_safe(world_pos: Vector3, local_pos: Vector3) -> float:
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	
	var radius = influence_size.x
	
	if distance_2d >= radius:
		return 0.0
	
	# Distance perpendicular to ridge
	var perpendicular = Vector2(-direction.y, direction.x)
	var lateral_distance = abs(Vector2(local_pos.x, local_pos.z).dot(perpendicular))
	
	# Along ridge for peak variation
	var along_ridge = Vector2(local_pos.x, local_pos.z).dot(direction)
	
	# Base ridge height profile
	var ridge_falloff = 1.0 - pow(lateral_distance / radius, ridge_sharpness)
	ridge_falloff = max(0.0, ridge_falloff)
	
	var result_height = height * ridge_falloff
	
	# Vary height along ridge
	if peak_noise:
		var peak_variation = peak_noise.get_noise_1d(along_ridge)
		result_height *= 0.7 + peak_variation * 0.3
	
	# Add detail using world coordinates (FastNoiseLite is thread-safe)
	if detail_noise:
		var detail = detail_noise.get_noise_2d(world_pos.x, world_pos.z)
		result_height += result_height * detail * 0.2
	
	return result_height
