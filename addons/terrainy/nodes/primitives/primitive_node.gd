@tool
@abstract
class_name PrimitiveNode
extends TerrainFeatureNode

const GizmoHandle = preload("res://addons/terrainy/gizmos/gizmo_handle.gd")

## Abstract base class for primitive terrain shapes (hills, mountains, craters, etc.)

@export var height: float = 10.0:
	set(value):
		height = value
		_commit_parameter_change()


func _validate_subclass() -> bool:
	if abs(height) < 0.001:
		push_warning("[%s] Height is near zero, feature may not be visible" % name)
		return false
	return true


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

	# Handle for height
	handles.append(GizmoHandle.new(
		"Height",
		Vector3(0, height, 0),
		GizmoHandle.HandleType.HEIGHT
	))

	return handles
