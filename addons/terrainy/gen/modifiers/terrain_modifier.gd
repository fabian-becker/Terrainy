@tool
@icon("res://addons/terrainy/icons/modifier.svg")
class_name TerrainModifier
extends TerrainComposableNode

## Base of the five Terrainy 2 modifiers. A modifier is a scene-order child of a field,
## heightmap, group or the generator; [member space] picks the map it modifies:
## Local = the owner unit's own map, Group = the nearest group composite, Global = the whole
## terrain after composition (post-compose pass, scene order).

const ModifierSnapshot = preload("res://addons/terrainy/gen/eval/modifier_snapshot.gd")
const Signature = preload("res://addons/terrainy/gen/eval/signature.gd")

@export_range(0.0, 1.0, 0.001) var strength: float = 1.0:
	set(value):
		strength = clampf(value, 0.0, 1.0)
		_commit()

@export var mask: TerrainMaskResource:
	set(value):
		_track_resource(mask, value)
		mask = value
		_commit()

func get_unit_kind() -> int:
	return 1  # CompositionPlan.UnitKind.MODIFIER

## Owner unit for Local space: nearest field / group ancestor (null = generator).
func get_owner_unit() -> Node:
	var node := get_parent()
	while node != null and not (node is TerrainGenerator):
		if node is TerrainFieldNode or node is TerrainFieldGroup:
			return node
		node = node.get_parent()
	return null

func make_snapshot(context: Dictionary) -> RefCounted:
	var snap := ModifierSnapshot.new()
	snap.strength = strength
	snap.center = Vector2(global_position.x, global_position.z)
	if mask:
		var mask_ctx := context.duplicate()
		mask_ctx["owner_xform"] = global_transform
		mask_ctx["owner_node"] = self
		snap.mask = mask.make_snapshot(mask_ctx)
	_fill_snapshot(snap, context)
	snap.signature = "%s|%s|%s|%s" % [
		get_script().resource_path, var_to_str(strength),
		Signature.of_object(mask) if mask else "nomask", _params_signature()
	]
	if mask:
		snap.signature += "|%s|%s" % [var_to_str(global_transform), snap.mask.signature]
	return snap

func _fill_snapshot(_snap, _context: Dictionary) -> void:
	pass

func _params_signature() -> String:
	return ""
