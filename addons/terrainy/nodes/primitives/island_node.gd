@tool
class_name IslandNode
extends PrimitiveNode

const PrimitiveNode = preload("res://addons/terrainy/nodes/primitives/primitive_node.gd")

## An island terrain feature with beaches and elevation

@export var beach_width: float = 0.2:
	set(value):
		beach_width = clamp(value, 0.0, 0.5)
		parameters_changed.emit()

@export var beach_height: float = 1.0:
	set(value):
		beach_height = value
		parameters_changed.emit()

@export var noise: FastNoiseLite:
	set(value):
		noise = value
		if noise and not noise.changed.is_connected(_on_noise_changed):
			noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

@export var noise_strength: float = 0.3:
	set(value):
		noise_strength = value
		parameters_changed.emit()

func _ready() -> void:
	if not noise:
		noise = FastNoiseLite.new()
		noise.seed = randi()
		noise.frequency = 0.05
		noise.fractal_octaves = 3

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
	var result_height = 0.0
	
	# Beach zone at the outer edge
	if normalized_distance > (1.0 - beach_width):
		result_height = beach_height
	else:
		# Rising from beach toward center - center is highest
		var inland_t = normalized_distance / (1.0 - beach_width)
		result_height = height - (height - beach_height) * inland_t
	
	# Add noise variation
	if noise:
		var noise_value = noise.get_noise_2d(world_pos.x, world_pos.z)
		result_height += result_height * noise_value * noise_strength
	
	return max(0.0, result_height)
