@tool
class_name VoronoiNode
extends NoiseNode

const NoiseNode = preload("res://addons/terrainy/nodes/noise/noise_node.gd")
const NoiseEvaluationContext = preload("res://addons/terrainy/nodes/noise/noise_evaluation_context.gd")

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
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

func prepare_evaluation_context() -> NoiseEvaluationContext:
	return NoiseEvaluationContext.from_noise_feature(self, noise, amplitude)

## Thread-safe version using context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as NoiseEvaluationContext
	return ctx.get_noise_normalized(world_pos) * ctx.amplitude

func get_gpu_param_pack() -> Dictionary:
	var freq = noise.frequency if noise else 0.0
	var seed = noise.seed if noise else 0
	var distance_function = noise.cellular_distance_function if noise else 0
	var return_type = noise.cellular_return_type if noise else 0
	var extra_floats := PackedFloat32Array([amplitude, freq])
	var extra_ints := PackedInt32Array([distance_mode, distance_function, return_type, seed])
	return _build_gpu_param_pack(FeatureType.NOISE_VORONOI, extra_floats, extra_ints)
