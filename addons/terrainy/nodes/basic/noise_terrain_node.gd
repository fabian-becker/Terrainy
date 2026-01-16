@tool
class_name PerlinNoiseNode
extends NoiseNode

const NoiseNode = preload("res://addons/terrainy/nodes/basic/noise_node.gd")

## Terrain feature using Perlin noise for organic variation

func _ready() -> void:
	if not noise:
		noise = FastNoiseLite.new()
		noise.seed = randi()
		noise.frequency = frequency
		noise.noise_type = FastNoiseLite.TYPE_PERLIN

func get_height_at(world_pos: Vector3) -> float:
	if not noise:
		return 0.0
	
	var sample_pos = world_pos * frequency
	var noise_value = noise.get_noise_2d(sample_pos.x, sample_pos.z)
	
	# Noise is in range [-1, 1], normalize to [0, 1] then scale
	return (noise_value + 1.0) * 0.5 * amplitude
