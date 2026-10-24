@tool
@icon("res://addons/terrainy/icons/mask.svg")
class_name TerrainMaskPath
extends TerrainMaskResource

## Path mask: distance to a route (Curve3D) with width + falloff, rasterized with the same fast
## path as the Corridor domain. Point [member path_node] at the Path3D of a corridor field to
## keep e.g. a river and the texture mask of its banks aligned by construction.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")

## Path3D whose curve (and transform) is used; resolved relative to the mask's owner node.
## Takes precedence over [member curve].
@export var path_node: NodePath:
	set(value):
		path_node = value
		emit_changed()

## Standalone curve, in the owner's (or generator's) space. Used when [member path_node] is empty.
@export var curve: Curve3D:
	set(value):
		if curve and curve.changed.is_connected(emit_changed):
			curve.changed.disconnect(emit_changed)
		curve = value
		if curve:
			curve.changed.connect(emit_changed)
		emit_changed()

## Full corridor width in meters.
@export var width: float = 8.0:
	set(value):
		width = maxf(value, 0.01)
		emit_changed()

## Weight from the corridor edge (x = 0) to its center line (x = 1). Null = hard edge.
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

func make_snapshot(context: Dictionary) -> RefCounted:
	var snap := MaskSnapshot.new()
	_fill_common(snap, context)
	snap.kind = MaskSnapshot.Kind.PATH
	snap.half_width = width * 0.5
	snap.falloff_lut = CurveLut.bake(falloff) if falloff else PackedFloat32Array()
	var grid = context.get("grid")
	var step: float = grid.cell if grid else 1.0
	var source_curve: Curve3D = curve
	var xform := _space_xform(context)
	var owner_node: Node = context.get("owner_node")
	if not path_node.is_empty() and owner_node and owner_node.is_inside_tree():
		var path := owner_node.get_node_or_null(path_node) as Path3D
		if path:
			source_curve = path.curve
			xform = path.global_transform
	snap.polyline = Raster.polyline_from_curve(source_curve, xform, step)
	snap.bounds = Raster.polyline_bounds(snap.polyline, snap.half_width)
	return snap
