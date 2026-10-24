@tool
@icon("res://addons/terrainy/icons/modifier.svg")
class_name TerrainSmoothModifier
extends TerrainModifier

## Blurs the target map (separable box blur, repeated passes approximate a gaussian).

## Blur radius in meters.
@export_range(0.1, 64.0, 0.1) var radius: float = 3.0:
	set(value):
		radius = maxf(value, 0.1)
		_commit()

@export_range(1, 8) var iterations: int = 2:
	set(value):
		iterations = clampi(value, 1, 8)
		_commit()

func _fill_snapshot(snap, _context: Dictionary) -> void:
	snap.op = ModifierSnapshot.Op.SMOOTH
	snap.radius = radius
	snap.iterations = iterations

func _params_signature() -> String:
	return "%s|%d" % [var_to_str(radius), iterations]
