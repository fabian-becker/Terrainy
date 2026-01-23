@tool
class_name DuneSeaNode
extends LandscapeNode

const LandscapeNode = preload("res://addons/terrainy/nodes/landscapes/landscape_node.gd")
const LandscapeEvaluationContext = preload("res://addons/terrainy/nodes/landscapes/landscape_evaluation_context.gd")

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

func prepare_evaluation_context() -> LandscapeEvaluationContext:
	var ctx = LandscapeEvaluationContext.from_landscape_feature(self, height, direction)
	ctx.primary_noise = noise
	ctx.detail_noise = detail_noise
	ctx.dune_frequency = dune_frequency
	return ctx

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as LandscapeEvaluationContext
	var local_pos = ctx.to_local(world_pos)
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	
	var radius = ctx.influence_radius
	
	if distance_2d >= radius:
		return 0.0
	
	# Directional dune pattern (ridges perpendicular to wind)
	var pos_2d = Vector2(local_pos.x, local_pos.z)
	
	# Primary dune waves
	var dune_pattern = 0.0
	var across_wind = pos_2d.dot(ctx.perpendicular)
	
	# Create wavy dune ridges
	dune_pattern = sin(across_wind * ctx.dune_frequency * 10.0 + ctx.get_primary_noise(world_pos) * 3.0)
	dune_pattern = (dune_pattern + 1.0) * 0.5  # Normalize to 0-1
	
	# Modulate by noise
	var height_variation = ctx.get_primary_noise(Vector3(world_pos.x * 0.5, 0, world_pos.z * 0.5))
	dune_pattern *= (0.5 + height_variation * 0.5)
	
	var result_height = ctx.height * dune_pattern
	
	# Add fine ripple detail
	var ripples = ctx.get_detail_noise(world_pos)
	if ripples != 0.0:
		result_height += ripples * 0.3
	
	# Fade at edges
	var edge_fade = 1.0 - pow(distance_2d / radius, 2.0)
	result_height *= edge_fade
	
	return result_height
