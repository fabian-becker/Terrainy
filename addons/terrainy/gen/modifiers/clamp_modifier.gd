@tool
@icon("res://addons/terrainy/icons/modifier.svg")
class_name TerrainClampModifier
extends TerrainModifier

## Clamps heights (generator-local meters) into [min_height, max_height].

@export var use_min: bool = true:
	set(value):
		use_min = value
		_commit()

@export var min_height: float = 0.0:
	set(value):
		min_height = value
		_commit()

@export var use_max: bool = true:
	set(value):
		use_max = value
		_commit()

@export var max_height: float = 32.0:
	set(value):
		max_height = value
		_commit()

func _fill_snapshot(snap, _context: Dictionary) -> void:
	snap.op = ModifierSnapshot.Op.CLAMP
	snap.use_min = use_min
	snap.use_max = use_max
	snap.clamp_min = min_height
	snap.clamp_max = max_height

func _params_signature() -> String:
	return "%d|%s|%d|%s" % [int(use_min), var_to_str(min_height), int(use_max), var_to_str(max_height)]
