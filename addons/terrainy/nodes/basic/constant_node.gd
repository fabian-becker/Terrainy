@tool
class_name ConstantNode
extends TerrainFeatureNode

const TerrainFeatureNode = "res://addons/terrainy/nodes/terrain_feature_node.gd"

## Constant flat height - useful as base layer

@export var height: float = 5.0:
	set(value):
		height = value
		_commit_parameter_change()

@export var infinite: bool = false:
	set(value):
		infinite = value
		_commit_parameter_change()

func get_height_at(world_pos: Vector3) -> float:
	if infinite:
		return height
	
	var local_pos = to_local(world_pos)
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	
	var radius = influence_size.x
	
	if distance_2d >= radius:
		return 0.0
	
	return height
