@tool
@icon("res://addons/terrainy/icons/group.svg")
class_name TerrainFieldGroup
extends TerrainComposableNode

## Pure container (no height of its own): bundles its children into one composition unit.
##
## Children compose in tree order into the group's own composite (starting flat at 0), which is
## then blended into the enclosing composite with [member blend_mode] / [member strength],
## weighted by the union of the children's coverage. Group-space children of nested fields read
## this group's composite. Bounds are the union of the children's bounds.

@export var scope: TerrainTypes.Scope = TerrainTypes.Scope.CONTRIBUTE:
	set(value):
		scope = value
		_commit()

@export var blend_mode: TerrainTypes.BlendMode = TerrainTypes.BlendMode.ADD:
	set(value):
		blend_mode = value
		_commit()

@export_range(0.0, 2.0, 0.001) var strength: float = 1.0:
	set(value):
		strength = value
		_commit()

func get_unit_kind() -> int:
	return 2  # CompositionPlan.UnitKind.GROUP

func get_influence_bounds() -> Rect2:
	var result := Rect2()
	var first := true
	for child in get_children():
		if child is TerrainComposableNode:
			var b: Rect2 = child.get_influence_bounds()
			if b.size == Vector2.ZERO:
				continue
			result = b if first else result.merge(b)
			first = false
	return result
