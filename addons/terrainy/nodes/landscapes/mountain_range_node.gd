@tool
class_name MountainRangeNode
extends LandscapeNode

const LandscapeNode = preload("res://addons/terrainy/nodes/landscapes/landscape_node.gd")
const LandscapeEvaluationContext = preload("res://addons/terrainy/nodes/landscapes/landscape_evaluation_context.gd")

## A mountain range terrain feature
##
## TIP: Mountains can appear very spiky by default. Try using the Modifiers:
## - Set "Smoothing" to MEDIUM or HEAVY for more natural-looking peaks
## - Adjust "Smoothing Radius" to 2.0-4.0 for best results
## - Enable "Terracing" with 8-12 levels for a layered mountain effect

@export var ridge_sharpness: float = 0.5:
	set(value):
		ridge_sharpness = clamp(value, 0.1, 2.0)
		parameters_changed.emit()

@export var peak_noise: FastNoiseLite:
	set(value):
		peak_noise = value
		if peak_noise and not peak_noise.changed.is_connected(_on_noise_changed):
			peak_noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

@export var detail_noise: FastNoiseLite:
	set(value):
		detail_noise = value
		if detail_noise and not detail_noise.changed.is_connected(_on_noise_changed):
			detail_noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

func _ready() -> void:
	if not peak_noise:
		peak_noise = FastNoiseLite.new()
		peak_noise.seed = randi()
		peak_noise.frequency = 0.008
		peak_noise.fractal_octaves = 2
	
	if not detail_noise:
		detail_noise = FastNoiseLite.new()
		detail_noise.seed = randi() + 1000
		detail_noise.frequency = 0.05
		detail_noise.fractal_octaves = 4

func prepare_evaluation_context() -> LandscapeEvaluationContext:
	var ctx = LandscapeEvaluationContext.from_landscape_feature(self, height, direction)
	ctx.primary_noise = peak_noise
	ctx.detail_noise = detail_noise
	return ctx

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as LandscapeEvaluationContext
	var local_pos = ctx.to_local(world_pos)
	
	var radius = ctx.influence_radius
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	
	if distance_2d >= radius:
		return 0.0
	
	# Distance perpendicular to ridge
	var lateral_distance = abs(ctx.get_lateral_distance(local_pos))
	
	# Along ridge for peak variation
	var along_ridge = ctx.get_distance_along(local_pos)
	
	# Base ridge height profile
	var ridge_falloff = 1.0 - pow(lateral_distance / radius, ctx.ridge_sharpness)
	ridge_falloff = max(0.0, ridge_falloff)
	
	var result_height = ctx.height * ridge_falloff
	
	# Vary height along ridge
	var peak_variation = ctx.get_primary_noise(Vector3(along_ridge, 0, 0))
	result_height *= 0.7 + peak_variation * 0.3
	
	# Add detail using world coordinates
	var detail = ctx.get_detail_noise(world_pos)
	if detail != 0.0:
		result_height += result_height * detail * 0.2
	
	return result_height
