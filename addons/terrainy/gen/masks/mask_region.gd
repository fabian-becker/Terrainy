@tool
@icon("res://addons/terrainy/icons/mask.svg")
class_name TerrainMaskRegion
extends TerrainMaskResource

## Shape mask: circle / ellipse / rectangle footprint with a falloff curve.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")

@export_enum("Circle", "Ellipse", "Rectangle") var shape: int = 0:
	set(value):
		shape = value
		emit_changed()

## Full footprint size in meters (X, Z).
@export var size: Vector2 = Vector2(32, 32):
	set(value):
		size = value.max(Vector2(0.01, 0.01))
		emit_changed()

## Offset and rotation relative to the owner (or generator).
@export var offset: Vector2 = Vector2.ZERO:
	set(value):
		offset = value
		emit_changed()

@export_range(-360, 360, 0.1, "radians_as_degrees") var rotation: float = 0.0:
	set(value):
		rotation = value
		emit_changed()

## Weight from the edge (x = 0) to the center (x = 1). Null = hard edge.
@export var falloff: Curve = CurveLut.default_falloff():
	set(value):
		if falloff and falloff.changed.is_connected(emit_changed):
			falloff.changed.disconnect(emit_changed)
		falloff = value
		_falloff_cleared = value == null
		if falloff:
			falloff.changed.connect(emit_changed)
		emit_changed()

## Persists an explicit null (hard edge): Godot does not serialize a null Object property
## because it equals the typed default, so the cleared state is stored separately.
@export_storage var _falloff_cleared: bool = false:
	set(value):
		_falloff_cleared = value
		if value and falloff != null:
			falloff = null

func _init() -> void:
	if falloff:
		falloff.changed.connect(emit_changed)

func local_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, rotation), Vector3(offset.x, 0.0, offset.y))

func make_snapshot(context: Dictionary) -> RefCounted:
	var snap := MaskSnapshot.new()
	_fill_common(snap, context)
	snap.kind = MaskSnapshot.Kind.REGION
	var xform := _space_xform(context) * local_transform()
	snap.inv_xform = xform.affine_inverse()
	snap.shape = shape
	snap.half = Raster.shape_half_extents(shape, size)
	snap.falloff_lut = CurveLut.bake(falloff) if falloff else PackedFloat32Array()
	snap.bounds = Raster.shape_bounds(xform, snap.half)
	return snap
