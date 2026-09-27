class_name GizmoHandle
extends RefCounted

## Metadata for a single gizmo handle on a TerrainFeatureNode.

enum HandleType {
	SIZE_X,       ## Influence width / radius
	SIZE_Y,       ## Influence depth (rectangle/ellipse only)
	FALLOFF,      ## Edge falloff distance
	HEIGHT,       ## Feature height (primitives, landscapes)
	START_HEIGHT, ## Gradient start height
	END_HEIGHT,   ## Gradient end height
	DIRECTION,    ## Gradient / landscape direction arrow
}

var name: String
var local_position: Vector3  ## Where the handle appears in local space
var handle_type: int         ## HandleType value

func _init(p_name: String, p_pos: Vector3, p_type: int) -> void:
	name = p_name
	local_position = p_pos
	handle_type = p_type
