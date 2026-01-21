@tool
@abstract
class_name PrimitiveNode
extends TerrainFeatureNode

const TerrainFeatureNode = "res://addons/terrainy/nodes/terrain_feature_node.gd"

## Abstract base class for primitive terrain shapes (hills, mountains, craters, etc.)

@export var height: float = 10.0:
	set(value):
		height = value
		_commit_parameter_change()
