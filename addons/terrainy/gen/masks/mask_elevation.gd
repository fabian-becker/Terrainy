@tool
@icon("res://addons/terrainy/icons/mask.svg")
class_name TerrainMaskElevation
extends TerrainMaskResource

## Elevation mask: 1 where the world height of the heightmap being modified lies in
## [min_height, max_height], softened by [member softness].

@export var min_height: float = 0.0:
	set(value):
		min_height = value
		emit_changed()

@export var max_height: float = 50.0:
	set(value):
		max_height = value
		emit_changed()

@export_range(0.0, 100.0, 0.01) var softness: float = 2.0:
	set(value):
		softness = maxf(value, 0.0)
		emit_changed()

func make_snapshot(context: Dictionary) -> RefCounted:
	var snap := MaskSnapshot.new()
	_fill_common(snap, context)
	snap.kind = MaskSnapshot.Kind.ELEVATION
	snap.range_min = min_height
	snap.range_max = max_height
	snap.softness = softness
	return snap

func depends_on_heights() -> bool:
	return true
