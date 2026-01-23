@tool
class_name CanyonNode
extends LandscapeNode

const LandscapeNode = preload("res://addons/terrainy/nodes/landscapes/landscape_node.gd")
const LandscapeEvaluationContext = preload("res://addons/terrainy/nodes/landscapes/landscape_evaluation_context.gd")

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

func prepare_evaluation_context() -> LandscapeEvaluationContext:
	return LandscapeEvaluationContext.from_landscape_feature(self, height, direction)

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as LandscapeEvaluationContext
	var local_pos = ctx.to_local(world_pos)
	# Calculate distance perpendicular to canyon direction
	var lateral_distance = abs(ctx.get_lateral_distance(local_pos))
	
	# Add meandering using noise along the canyon
	var meander = ctx.get_primary_noise(world_pos) * ctx.canyon_width * ctx.canyon_meander_strength
	lateral_distance += meander
	
	var half_width = ctx.canyon_width * 0.5
	
	if lateral_distance < half_width:
		# Inside canyon floor
		return -ctx.height
	elif lateral_distance < half_width + ctx.height / ctx.canyon_wall_slope:
		# On canyon walls
		var wall_dist = lateral_distance - half_width
		var wall_height = wall_dist * ctx.canyon_wall_slope
		return -ctx.height + wall_height
	else:
		# Outside canyon influence
		return 0.0
