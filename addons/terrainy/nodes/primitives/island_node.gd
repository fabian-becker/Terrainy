@tool
class_name IslandNode
extends PrimitiveNode

const PrimitiveNode = preload("res://addons/terrainy/nodes/primitives/primitive_node.gd")
const PrimitiveEvaluationContext = preload("res://addons/terrainy/nodes/primitives/primitive_evaluation_context.gd")

## An island terrain feature with beaches and elevation

@export var beach_width: float = 0.2:
	set(value):
		beach_width = clamp(value, 0.0, 0.5)
		_commit_parameter_change()

@export var beach_height: float = 1.0:
	set(value):
		beach_height = value
		_commit_parameter_change()

@export var noise: FastNoiseLite:
	set(value):
		noise = value
		if noise and not noise.changed.is_connected(_on_noise_changed):
			noise.changed.connect(_on_noise_changed)
		_commit_parameter_change()

@export var noise_strength: float = 0.3:
	set(value):
		noise_strength = value
		_commit_parameter_change()

func _ready() -> void:
	if not noise:
		self.noise = FastNoiseLite.new()
		noise.seed = randi()
		noise.frequency = 0.05
		noise.fractal_octaves = 3
	
	if noise and not noise.changed.is_connected(_on_noise_changed):
		noise.changed.connect(_on_noise_changed)

func _on_noise_changed() -> void:
	_commit_parameter_change()

func prepare_evaluation_context() -> PrimitiveEvaluationContext:
	var ctx = PrimitiveEvaluationContext.from_primitive_feature(self, height, 0)
	ctx.island_beach_width = beach_width
	ctx.island_beach_height = beach_height
	ctx.noise = noise
	ctx.noise_strength = noise_strength
	return ctx

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as PrimitiveEvaluationContext
	var local_pos = ctx.to_local(world_pos)
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	
	var radius = ctx.influence_radius
	
	if distance_2d >= radius:
		return 0.0
	
	var normalized_distance = distance_2d / radius
	var result_height = 0.0
	
	# Beach zone at the outer edge
	if normalized_distance > (1.0 - ctx.island_beach_width):
		result_height = ctx.island_beach_height
	else:
		# Rising from beach toward center - center is highest
		var inland_t = normalized_distance / (1.0 - ctx.island_beach_width)
		result_height = ctx.height - (ctx.height - ctx.island_beach_height) * inland_t
	
	# Add noise variation
	var noise_detail = ctx.get_noise_detail(world_pos)
	if noise_detail != 0.0:
		result_height += result_height * noise_detail
	
	return max(0.0, result_height)

func get_gpu_param_pack() -> Dictionary:
	var noise_enabled = 1 if noise != null else 0
	var noise_frequency = noise.frequency if noise else 0.0
	var noise_seed = noise.seed if noise else 0
	var noise_type = noise.noise_type if noise else 0
	var extra_floats := PackedFloat32Array([height, beach_width, beach_height, noise_strength, noise_frequency])
	var extra_ints := PackedInt32Array([noise_type, noise_seed, noise_enabled])
	return _build_gpu_param_pack(FeatureType.PRIMITIVE_ISLAND, extra_floats, extra_ints)
