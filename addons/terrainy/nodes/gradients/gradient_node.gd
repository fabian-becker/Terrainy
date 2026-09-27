@tool
@abstract
class_name GradientNode
extends TerrainFeatureNode

const GradientEvaluationContext = preload("res://addons/terrainy/nodes/gradients/gradient_evaluation_context.gd")
const GizmoHandle = preload("res://addons/terrainy/gizmos/gizmo_handle.gd")

## Abstract base class for gradient-based terrain features

@export var start_height: float = 10.0:
	set(value):
		start_height = value
		_commit_parameter_change()

@export var end_height: float = 0.0:
	set(value):
		end_height = value
		_commit_parameter_change()

func prepare_evaluation_context() -> GradientEvaluationContext:
	return GradientEvaluationContext.from_gradient_feature(self, start_height, end_height)


func _validate_subclass() -> bool:
	var changed = false
	if abs(start_height) < 0.001 and abs(end_height) < 0.001:
		push_warning("[%s] Both start and end height are near zero, gradient may not be visible" % name)
		changed = true
	return not changed


func _get_gizmo_handles() -> Array[GizmoHandle]:
	var handles: Array[GizmoHandle] = []
	var half_size = influence_size * 0.5

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

	# Start height handle (center for radial, back for linear)
	var back_pos = Vector3.ZERO
	handles.append(GizmoHandle.new(
		"Start Height",
		back_pos + Vector3(0, start_height, 0),
		GizmoHandle.HandleType.START_HEIGHT
	))

	# End height handle (edge for radial, front for linear)
	var front_pos = Vector3(influence_size.x, 0, 0)
	handles.append(GizmoHandle.new(
		"End Height",
		front_pos + Vector3(0, end_height, 0),
		GizmoHandle.HandleType.END_HEIGHT
	))

	return handles
