@tool
extends RefCounted

## One brush application (internal in 2.0; a public stamp surface is a 3.x candidate).
## The brush tool emits a list of stamps per input frame; the CPU stamper and the GPU
## paint_apply kernel consume the same list.

enum StrokeOp { RAISE, LOWER, FLATTEN, SMOOTH, STAMP_NOISE, SET_VALUE, TEXTURE, MASK }

var op: int = StrokeOp.RAISE
## World position of the brush center.
var position: Vector3 = Vector3.ZERO
## Radius in meters.
var radius: float = 8.0
## Brush falloff LUT over x = 0 (rim) .. 1 (center).
var falloff_lut: PackedFloat32Array = PackedFloat32Array()
## Per-stamp strength. Height ops: meters; weight ops: 0..1.
var strength: float = 0.5
## FLATTEN / SET_VALUE target (generator-local meters for heights, 0..1 for weights).
var value: float = 0.0
## Erase (Ctrl): inverts additive ops.
var erase: bool = false
## STAMP_NOISE source (already seeded).
var noise: FastNoiseLite = null

func _init(p_op: int = StrokeOp.RAISE, p_position: Vector3 = Vector3.ZERO, p_radius: float = 8.0, p_strength: float = 0.5) -> void:
	op = p_op
	position = p_position
	radius = p_radius
	strength = p_strength

func to_dict() -> Dictionary:
	return {"op": op, "position": position, "radius": radius, "strength": strength, "value": value, "erase": erase}
