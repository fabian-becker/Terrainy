@tool
class_name NoiseNode
extends TerrainFeatureNode

const TerrainFeatureNode = "res://addons/terrainy/nodes/terrain_feature_node.gd"

## Abstract base class for noise-based terrain features

@export var amplitude: float = 5.0:
	set(value):
		amplitude = value
		parameters_changed.emit()

@export var noise: FastNoiseLite:
	set(value):
		noise = value
		if noise and not noise.changed.is_connected(_on_noise_changed):
			noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

func _on_noise_changed() -> void:
	parameters_changed.emit()
