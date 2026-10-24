@tool
@icon("res://addons/terrainy/icons/modifier.svg")
class_name TerrainTerraceModifier
extends TerrainModifier

## Quantizes heights into steps of [member step_height] meters. [member smoothness] rounds the
## risers (0 = hard steps). Absolute steps keep the op chunk-local (0.7 normalized against the
## map maximum, which made every edit global).

@export var step_height: float = 4.0:
	set(value):
		step_height = maxf(value, 0.01)
		_commit()

@export_range(0.0, 1.0, 0.001) var smoothness: float = 0.25:
	set(value):
		smoothness = clampf(value, 0.0, 1.0)
		_commit()

## Height of the first step edge.
@export var step_offset: float = 0.0:
	set(value):
		step_offset = value
		_commit()

func _fill_snapshot(snap, _context: Dictionary) -> void:
	snap.op = ModifierSnapshot.Op.TERRACE
	snap.step_height = step_height
	snap.smoothness = smoothness
	snap.terrace_offset = step_offset

func _params_signature() -> String:
	return "%s|%s|%s" % [var_to_str(step_height), var_to_str(smoothness), var_to_str(step_offset)]
