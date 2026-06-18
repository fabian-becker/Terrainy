@tool
class_name LinearGradientNode
extends GradientNode

const GradientNode = preload("res://addons/terrainy/nodes/gradients/gradient_node.gd")

## Linear gradient in a specified direction

@export var direction: Vector2 = Vector2(1, 0):
	set(value):
		direction = value.normalized()
		_commit_parameter_change()

@export_enum("Linear", "Smooth", "Ease In", "Ease Out") var interpolation: int = 1:
	set(value):
		interpolation = value
		_commit_parameter_change()

func get_direction() -> Vector2:
	return direction

func _get_gizmo_handles() -> Array[GizmoHandle]:
	var handles: Array[GizmoHandle] = []
	var half_size = influence_size * 0.5
	var dir_3d = Vector3(direction.x, 0, direction.y).normalized()
	var grad_length = influence_size.x

	# Handle 0: Size X (width / radius)
	handles.append(GizmoHandle.new(
		"Radius" if influence_shape == InfluenceShape.CIRCLE else "Width",
		Vector3(half_size.x, 0, 0),
		GizmoHandle.HandleType.SIZE_X
	))

	# Handle 1: Size Y (depth, for rectangle and ellipse)
	if influence_shape != InfluenceShape.CIRCLE:
		handles.append(GizmoHandle.new(
			"Depth",
			Vector3(0, 0, half_size.y),
			GizmoHandle.HandleType.SIZE_Y
		))

	# Handle 2: Falloff (if exists)
	if edge_falloff > 0.0:
		var falloff_size = half_size.x * (1.0 - edge_falloff)
		handles.append(GizmoHandle.new(
			"Falloff",
			Vector3(falloff_size, 0, 0),
			GizmoHandle.HandleType.FALLOFF
		))

	# Start height handle (back along direction)
	var back_pos = -dir_3d * grad_length
	handles.append(GizmoHandle.new(
		"Start Height",
		back_pos + Vector3(0, start_height, 0),
		GizmoHandle.HandleType.START_HEIGHT
	))

	# End height handle (front along direction)
	var front_pos = dir_3d * grad_length
	handles.append(GizmoHandle.new(
		"End Height",
		front_pos + Vector3(0, end_height, 0),
		GizmoHandle.HandleType.END_HEIGHT
	))

	# Direction handle
	var max_sz = max(influence_size.x, influence_size.y)
	var arrow_length = max_sz * 0.7
	handles.append(GizmoHandle.new(
		"Direction",
		dir_3d * arrow_length,
		GizmoHandle.HandleType.DIRECTION
	))

	return handles

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

func prepare_evaluation_context() -> GradientEvaluationContext:
	var ctx = GradientEvaluationContext.from_gradient_feature(self, start_height, end_height)
	ctx.gradient_vector = direction
	ctx.interpolation = interpolation
	return ctx

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as GradientEvaluationContext
	var local_pos = ctx.to_local(world_pos)
	var pos_2d = Vector2(local_pos.x, local_pos.z)
	
	# Project position onto gradient direction
	var projected = pos_2d.dot(ctx.gradient_vector)
	
	# Normalize to influence radius
	var radius = ctx.influence_radius
	var t = (projected + radius) / (radius * 2.0)
	t = clamp(t, 0.0, 1.0)
	
	# Apply interpolation
	match ctx.interpolation:
		0: # Linear
			pass
		1: # Smooth
			t = smoothstep(0.0, 1.0, t)
		2: # Ease In
			t = t * t
		3: # Ease Out
			t = 1.0 - (1.0 - t) * (1.0 - t)
	
	return lerp(ctx.start_height, ctx.end_height, t)

func get_gpu_param_pack() -> Dictionary:
	var dir = direction.normalized()
	var extra_floats := PackedFloat32Array([start_height, end_height, dir.x, dir.y])
	var extra_ints := PackedInt32Array([interpolation])
	return _build_gpu_param_pack(FeatureType.GRADIENT_LINEAR, extra_floats, extra_ints)
