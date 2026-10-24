@tool
@icon("res://addons/terrainy/icons/flatten.svg")
class_name TerrainFlattenModifier
extends TerrainModifier

## Pulls existing terrain toward a target height inside its own footprint (falloff + strength +
## mask). Combined with slope/elevation masks this makes "flatten only the valleys" or
## "flatten slopes steeper than 35 degrees" pure configuration.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")

enum TargetMode {
	## The modifier node's own height (drag it / its gizmo handle in the viewport).
	NODE_HEIGHT,
	## [member target_height] as an absolute world elevation.
	ABSOLUTE,
	## The owner unit's local level (owner node height + target_height offset).
	OWNER_LEVEL,
}

@export var target_mode: TargetMode = TargetMode.NODE_HEIGHT:
	set(value):
		target_mode = value
		_commit()

@export var target_height: float = 0.0:
	set(value):
		target_height = value
		_commit()

@export_enum("Circle", "Ellipse", "Rectangle") var footprint_shape: int = 0:
	set(value):
		footprint_shape = value
		_commit()

@export var footprint_size: Vector2 = Vector2(32, 32):
	set(value):
		footprint_size = value.max(Vector2(0.1, 0.1))
		_commit()

## Weight from the footprint edge (x = 0) to its center (x = 1). Null = hard edge.
@export var falloff: Curve = CurveLut.default_falloff():
	set(value):
		_track_resource(falloff, value)
		falloff = value
		_falloff_cleared = value == null
		_commit()

## Persists an explicit null (hard edge): Godot does not serialize a null Object property
## because it equals the typed default, so the cleared state is stored separately.
@export_storage var _falloff_cleared: bool = false:
	set(value):
		_falloff_cleared = value
		if value and falloff != null:
			falloff = null

func _init() -> void:
	super._init()
	_track_resource(null, falloff)

## Target height in world space (the plane the editor gizmo draws on).
func resolve_target_world_y() -> float:
	match target_mode:
		TargetMode.ABSOLUTE:
			return target_height
		TargetMode.OWNER_LEVEL:
			var owner_unit := get_owner_unit()
			if owner_unit is Node3D:
				return (owner_unit as Node3D).global_position.y + target_height
			# No field/group owner: the generator is the level, matching the old generator_y
			# fallback in resolve_target_height().
			var generator := get_generator()
			var level: float = (generator as Node3D).global_position.y if generator is Node3D else global_position.y
			return level + target_height
		_:
			return global_position.y

## Target height relative to the generator (the space every composite lives in).
func resolve_target_height(generator_y: float) -> float:
	return resolve_target_world_y() - generator_y

func _fill_snapshot(snap, context: Dictionary) -> void:
	var gen_xform: Transform3D = context.get("generator_xform", Transform3D.IDENTITY)
	snap.op = ModifierSnapshot.Op.FLATTEN
	snap.target_height = resolve_target_height(gen_xform.origin.y)
	snap.inv_xform = global_transform.affine_inverse()
	snap.shape = footprint_shape
	snap.half = Raster.shape_half_extents(footprint_shape, footprint_size)
	snap.falloff_lut = CurveLut.bake(falloff) if falloff else PackedFloat32Array()
	snap.bounds = Raster.shape_bounds(global_transform, snap.half)
	snap.has_bounds = true

func _params_signature() -> String:
	var owner_unit := get_owner_unit()
	return "%d|%s|%d|%s|%s|%s|%s" % [target_mode, var_to_str(target_height), footprint_shape,
		var_to_str(footprint_size), var_to_str(global_transform),
		var_to_str((owner_unit as Node3D).global_position.y) if owner_unit is Node3D else "-",
		Signature.of_object(falloff) if falloff else "-"]

func get_influence_bounds() -> Rect2:
	return Raster.shape_bounds(global_transform, Raster.shape_half_extents(footprint_shape, footprint_size))
