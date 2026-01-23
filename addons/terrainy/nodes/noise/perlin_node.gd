@tool
class_name PerlinNoiseNode
extends NoiseNode

const NoiseNode = preload("res://addons/terrainy/nodes/noise/noise_node.gd")
const NoiseEvaluationContext = preload("res://addons/terrainy/nodes/noise/noise_evaluation_context.gd")

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

func prepare_evaluation_context() -> NoiseEvaluationContext:
	return NoiseEvaluationContext.from_noise_feature(self, noise, amplitude)

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

## Thread-safe version using context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as NoiseEvaluationContext
	return ctx.get_noise_normalized(world_pos) * ctx.amplitude
