@tool
@icon("res://addons/terrainy/icons/mask.svg")
class_name TerrainMaskResource
extends Resource

## Base class of the Terrainy 2 mask family (data resources, not nodes).
##
## A mask is referenced by a field's `mask`, a modifier's `mask`, a paint layer's `mask`, a
## scatter node's `masks` or the brush `limit_mask`. It answers "how much (0..1) does the owner
## act here?". Transforms of spatial masks are relative to the owning node unless
## [member relative_to_owner] is off (then relative to the generator).

const MaskSnapshot = preload("res://addons/terrainy/gen/eval/mask_snapshot.gd")

## Flip the mask (1 - value).
@export var invert: bool = false:
	set(value):
		invert = value
		emit_changed()

## Scales the mask value (clamped to 0..1).
@export_range(0.0, 1.0) var strength: float = 1.0:
	set(value):
		strength = clampf(value, 0.0, 1.0)
		emit_changed()

## Spatial masks follow their owner node (default) or the generator.
@export var relative_to_owner: bool = true:
	set(value):
		relative_to_owner = value
		emit_changed()

## Worker-safe snapshot. [param context] keys: `owner_xform` (Transform3D), `generator_xform`
## (Transform3D), `generator` (TerrainGenerator, main thread only), `grid`.
func make_snapshot(context: Dictionary) -> RefCounted:
	var snap := MaskSnapshot.new()
	_fill_common(snap, context)
	return snap

func _fill_common(snap, context: Dictionary) -> void:
	snap.invert = invert
	snap.strength = strength
	var gen_xform: Transform3D = context.get("generator_xform", Transform3D.IDENTITY)
	snap.reference_y = gen_xform.origin.y

func _space_xform(context: Dictionary) -> Transform3D:
	if relative_to_owner:
		return context.get("owner_xform", Transform3D.IDENTITY)
	return context.get("generator_xform", Transform3D.IDENTITY)

## True when the mask reads the heightmap it is applied to (slope/elevation), which keeps it
## out of the per-field evaluation cache.
func depends_on_heights() -> bool:
	return false
