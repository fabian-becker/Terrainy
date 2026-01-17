@tool
class_name GradientNode
extends TerrainFeatureNode

const TerrainFeatureNode = "res://addons/terrainy/nodes/terrain_feature_node.gd"

## Abstract base class for gradient-based terrain features

@export var start_height: float = 10.0:
	set(value):
		start_height = value
		_commit_parameter_change()

@export var end_height: float = 0.0:
	set(value):
		end_height = value
		_commit_parameter_change()
