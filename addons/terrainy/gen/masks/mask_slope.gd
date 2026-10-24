@tool
@icon("res://addons/terrainy/icons/mask.svg")
class_name TerrainMaskSlope
extends TerrainMaskResource

## Slope mask: 1 where the slope (degrees) of the heightmap being modified lies in
## [min_degrees, max_degrees], softened by [member softness_degrees].

@export_range(0.0, 90.0, 0.1) var min_degrees: float = 0.0:
	set(value):
		min_degrees = value
		emit_changed()

@export_range(0.0, 90.0, 0.1) var max_degrees: float = 35.0:
	set(value):
		max_degrees = value
		emit_changed()

@export_range(0.0, 45.0, 0.1) var softness_degrees: float = 5.0:
	set(value):
		softness_degrees = value
		emit_changed()

func make_snapshot(context: Dictionary) -> RefCounted:
	var snap := MaskSnapshot.new()
	_fill_common(snap, context)
	snap.kind = MaskSnapshot.Kind.SLOPE
	snap.range_min = min_degrees
	snap.range_max = max_degrees
	snap.softness = softness_degrees
	return snap

func depends_on_heights() -> bool:
	return true
