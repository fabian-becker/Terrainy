@tool
@abstract
class_name LandscapeNode
extends TerrainFeatureNode

const TerrainFeatureNode = "res://addons/terrainy/nodes/terrain_feature_node.gd"

## Abstract base class for directional landscape features (canyons, mountain ranges, dunes)

@export var height: float = 30.0:
	set(value):
		height = value
		_commit_parameter_change()

@export var direction: Vector2 = Vector2(1, 0):
	set(value):
		direction = value.normalized()
		_commit_parameter_change()

@export var noise: FastNoiseLite:
	set(value):
		noise = value
		if noise and not noise.changed.is_connected(_on_noise_changed):
			noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

func _on_noise_changed() -> void:
	parameters_changed.emit()
