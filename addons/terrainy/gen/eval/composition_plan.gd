@tool
extends RefCounted

## Ordered, worker-safe description of one composition (stage 1, "plan scan").
##
## Built on the main thread from the generator's subtree; afterwards nothing in the plan touches
## a node again. Units keep tree order; Global-space units are collected into [member post]
## (stage 4) in scene (pre-)order; holes and paint layers are listed separately.

enum UnitKind { FIELD, MODIFIER, GROUP, HOLE, SCATTER, ROOT }

class Unit:
	extends RefCounted
	var kind: int = UnitKind.FIELD
	var node_id: int = 0
	var node_name: String = ""
	var space: int = 1
	## FieldSnapshot / ModifierSnapshot
	var snap = null
	## MaskSnapshot for fields/groups (null = unmasked)
	var mask = null
	var blend_mode: int = 0
	## Group blend strength (fields fold strength into their weight map)
	var strength: float = 1.0
	var children: Array = []
	var signature: String = ""
	## World XZ bounds (dirty bookkeeping)
	var bounds: Rect2 = Rect2()
	## Surface contributions: Array of Dictionary {layer, mode, strength, gate}
	var contributions: Array = []

var root: Unit = Unit.new()
var post: Array = []
var holes: Array = []
var paint_layers: Array = []
## Node ids of every unit, in plan order (structure signature).
var structure: PackedInt64Array = PackedInt64Array()
var signature: String = ""
var unit_count: int = 0

func _init() -> void:
	root.kind = UnitKind.ROOT

## Every unit (root excluded) in plan order, post-pass units included.
func all_units() -> Array:
	var out: Array = []
	_collect(root, out)
	for unit in post:
		out.append(unit)
		_collect(unit, out)
	return out

func _collect(unit: Unit, out: Array) -> void:
	for child in unit.children:
		out.append(child)
		_collect(child, out)

func find_unit(node_id: int) -> Unit:
	for unit in all_units():
		if unit.node_id == node_id:
			return unit
	return null
