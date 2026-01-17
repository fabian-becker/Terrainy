@tool
class_name MountainNode
extends PrimitiveNode

const PrimitiveNode = preload("res://addons/terrainy/nodes/primitives/primitive_node.gd")

## A mountain terrain feature with various peak types and noise detail

@export_enum("Sharp", "Rounded", "Plateau") var peak_type: int = 0:
	set(value):
		peak_type = value
		parameters_changed.emit()

@export var noise: FastNoiseLite:
	set(value):
		noise = value
		if noise and not noise.changed.is_connected(_on_noise_changed):
			noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

@export var noise_strength: float = 0.15:
	set(value):
		noise_strength = clamp(value, 0.0, 1.0)
		parameters_changed.emit()

func _ready() -> void:
	if not noise:
		noise = FastNoiseLite.new()
		noise.seed = randi()
		noise.frequency = 0.02
		noise.noise_type = FastNoiseLite.TYPE_PERLIN

func _on_noise_changed() -> void:
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
	var height_multiplier = 0.0
	
	match peak_type:
		0: # Sharp
			height_multiplier = pow(1.0 - normalized_distance, 1.5)
		1: # Rounded
			height_multiplier = cos(normalized_distance * PI * 0.5)
			height_multiplier = height_multiplier * height_multiplier
		2: # Plateau
			if normalized_distance < 0.3:
				height_multiplier = 1.0
			else:
				var slope_t = (normalized_distance - 0.3) / 0.7
				height_multiplier = 1.0 - smoothstep(0.0, 1.0, slope_t)
	
	var base_height = height * height_multiplier
	
	# Add noise detail
	if noise and noise_strength > 0.0:
		var noise_value = noise.get_noise_3d(world_pos.x, world_pos.y, world_pos.z)
		base_height += noise_value * height * noise_strength * height_multiplier
	
	return base_height
