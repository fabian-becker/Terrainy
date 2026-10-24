@tool
@icon("res://addons/terrainy/icons/mask.svg")
class_name TerrainMaskPaint
extends TerrainMaskResource

## Painted mask: references a MASK-kind [TerrainPaintLayer] of the generator by name.
## Painted masks are never hole sources (holes stay a procedural node).

@export var layer_name: String = "":
	set(value):
		layer_name = value
		emit_changed()

func make_snapshot(context: Dictionary) -> RefCounted:
	var snap := MaskSnapshot.new()
	_fill_common(snap, context)
	snap.kind = MaskSnapshot.Kind.PAINT
	var generator = context.get("generator")
	if generator and generator.has_method("find_paint_layer"):
		var layer = generator.find_paint_layer(layer_name)
		if layer and layer.kind == TerrainPaintLayer.PaintKind.MASK:
			snap.texture_data = layer.get_float_data()
			snap.texture_size = Vector2i(layer.grid_size(), layer.grid_size())
			snap.paint_origin = generator.get_terrain_world_rect().position
			snap.paint_size = generator.terrain_size
			snap.paint_grid = layer.grid_size()
			snap.signature = "paint:%s:%d" % [layer_name, layer.revision]
	return snap
