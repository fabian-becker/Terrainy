@tool
class_name VoronoiNode
extends NoiseNode

const NoiseNode = preload("res://addons/terrainy/nodes/noise/noise_node.gd")

## Voronoi/cellular pattern for rocky/cracked terrain

@export_enum("F1", "F2", "F2 - F1", "Cells") var distance_mode: int = 0:
	set(value):
		distance_mode = value
		_update_cellular_return_type()
		parameters_changed.emit()

func _ready() -> void:
	if not noise:
		noise = FastNoiseLite.new()
		noise.seed = randi()
		noise.noise_type = FastNoiseLite.TYPE_CELLULAR
		noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	_update_cellular_return_type()

func _update_cellular_return_type() -> void:
	if not noise:
		return
	
	match distance_mode:
		0: # F1 - closest cell
			noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
		1: # F2 - second closest
			noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2
		2: # F2 - F1 - cell borders
			noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_ADD
		3: # Cells - cell values
			noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE

func get_height_at(world_pos: Vector3) -> float:
	var local_pos = to_local(world_pos)
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	
	var radius = influence_size.x
	
	if distance_2d >= radius:
		return 0.0
	
	if not noise:
		return 0.0
	
	var voronoi_value = noise.get_noise_2d(world_pos.x, world_pos.z)
	
	# Normalize from [-1, 1] to [0, 1]
	var height = (voronoi_value + 1.0) * 0.5 * amplitude
	
	return height
