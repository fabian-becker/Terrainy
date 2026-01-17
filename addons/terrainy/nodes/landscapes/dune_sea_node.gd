@tool
class_name DuneSeaNode
extends LandscapeNode

const LandscapeNode = preload("res://addons/terrainy/nodes/landscapes/landscape_node.gd")

## A desert dune field terrain feature

@export var dune_frequency: float = 0.015:
	set(value):
		dune_frequency = value
		parameters_changed.emit()

@export var detail_noise: FastNoiseLite:
	set(value):
		detail_noise = value
		if detail_noise and not detail_noise.changed.is_connected(_on_noise_changed):
			detail_noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

func _ready() -> void:
	if not noise:
		noise = FastNoiseLite.new()
		noise.seed = randi()
		noise.frequency = 0.015
		noise.fractal_octaves = 3
		noise.noise_type = FastNoiseLite.TYPE_PERLIN
	
	if not detail_noise:
		detail_noise = FastNoiseLite.new()
		detail_noise.seed = randi() + 500
		detail_noise.frequency = 0.15
		detail_noise.fractal_octaves = 2

func get_height_at(world_pos: Vector3) -> float:
	var local_pos = to_local(world_pos)
	return get_height_at_safe(world_pos, local_pos)

## Thread-safe version using pre-computed local position
func get_height_at_safe(world_pos: Vector3, local_pos: Vector3) -> float:
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	
	var radius = influence_size.x
	
	if distance_2d >= radius:
		return 0.0
	
	# Directional dune pattern (ridges perpendicular to wind)
	var perpendicular = Vector2(-direction.y, direction.x)
	var pos_2d = Vector2(local_pos.x, local_pos.z)
	
	# Primary dune waves
	var dune_pattern = 0.0
	if noise:
		var along_wind = pos_2d.dot(direction)
		var across_wind = pos_2d.dot(perpendicular)
		
		# Create wavy dune ridges
		dune_pattern = sin(across_wind * dune_frequency * 10.0 + noise.get_noise_2d(world_pos.x, world_pos.z) * 3.0)
		dune_pattern = (dune_pattern + 1.0) * 0.5  # Normalize to 0-1
		
		# Modulate by noise
		var height_variation = noise.get_noise_2d(world_pos.x * 0.5, world_pos.z * 0.5)
		dune_pattern *= (0.5 + height_variation * 0.5)
	
	var result_height = height * dune_pattern
	
	# Add fine ripple detail
	if detail_noise:
		var ripples = detail_noise.get_noise_2d(world_pos.x, world_pos.z)
		result_height += ripples * 0.3
	
	# Fade at edges
	var edge_fade = 1.0 - pow(distance_2d / radius, 2.0)
	result_height *= edge_fade
	
	return result_height
