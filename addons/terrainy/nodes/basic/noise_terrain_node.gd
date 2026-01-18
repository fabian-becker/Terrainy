@tool
class_name PerlinNoiseNode
extends NoiseNode

const NoiseNode = preload("res://addons/terrainy/nodes/basic/noise_node.gd")

## Terrain feature using Perlin noise for organic variation
##
## TIP: Noise terrain can look rough. Use Modifiers to improve appearance:
## - Set "Smoothing" to LIGHT or MEDIUM for smoother rolling hills
## - Enable "Terracing" for stylized, stepped terrain

func _ready() -> void:
	if not noise:
		noise = FastNoiseLite.new()
		noise.seed = randi()
		noise.frequency = 0.01  # Set a reasonable default
		noise.noise_type = FastNoiseLite.TYPE_PERLIN

func get_height_at(world_pos: Vector3) -> float:
	if not noise:
		return 0.0
	
	var noise_value = noise.get_noise_2d(world_pos.x, world_pos.z)
	return (noise_value + 1.0) * 0.5 * amplitude

## Thread-safe version (noise already uses world coords, so it's thread-safe)
func get_height_at_safe(world_pos: Vector3, local_pos: Vector3) -> float:
	return get_height_at(world_pos)
