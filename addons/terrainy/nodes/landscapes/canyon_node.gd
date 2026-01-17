@tool
class_name CanyonNode
extends LandscapeNode

const LandscapeNode = preload("res://addons/terrainy/nodes/landscapes/landscape_node.gd")

## A canyon/valley terrain feature

@export var canyon_width: float = 20.0:
	set(value):
		canyon_width = value
		parameters_changed.emit()

@export var wall_slope: float = 0.8:
	set(value):
		wall_slope = clamp(value, 0.1, 2.0)
		parameters_changed.emit()

@export var meander_strength: float = 0.1:
	set(value):
		meander_strength = value
		parameters_changed.emit()

func _ready() -> void:
	if not noise:
		noise = FastNoiseLite.new()
		noise.seed = randi()
		noise.frequency = 0.01

func get_height_at(world_pos: Vector3) -> float:
	var local_pos = to_local(world_pos)
	return get_height_at_safe(world_pos, local_pos)

## Thread-safe version using pre-computed local position
func get_height_at_safe(world_pos: Vector3, local_pos: Vector3) -> float:
	# Calculate distance perpendicular to canyon direction
	var perpendicular = Vector2(-direction.y, direction.x)
	var lateral_distance = abs(Vector2(local_pos.x, local_pos.z).dot(perpendicular))
	
	# Add meandering using noise along the canyon
	if noise:
		var along_canyon = Vector2(local_pos.x, local_pos.z).dot(direction)
		var meander = noise.get_noise_1d(along_canyon) * canyon_width * meander_strength
		lateral_distance += meander
	
	var half_width = canyon_width * 0.5
	
	if lateral_distance < half_width:
		# Inside canyon floor
		return -height
	elif lateral_distance < half_width + height / wall_slope:
		# On canyon walls
		var wall_dist = lateral_distance - half_width
		var wall_height = wall_dist * wall_slope
		return -height + wall_height
	else:
		# Outside canyon influence
		return 0.0
