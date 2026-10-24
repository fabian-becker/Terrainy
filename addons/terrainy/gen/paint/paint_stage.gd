@tool
extends RefCounted

## Stage 5: applies the height paint layers (in layer order) on top of the procedural
## composite. Worker safe: works on layer snapshots (see TerrainPaintLayer.make_snapshot()).
##
## Delta / smooth / mask-gated layers are chunk-local: [method apply_region] recomposes any
## sub-rect from the procedural map alone (it reads a margin around the rect so SMOOTH layers
## see their neighbourhood), which is what stroke updates use.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const PaintKind = TerrainPaintLayer.PaintKind

## Margin (grid samples) the region must read so every SMOOTH layer sees real neighbours.
static func margin_for(layers: Array, grid) -> int:
	var m := 1
	for layer in layers:
		if int(layer["kind"]) == PaintKind.SMOOTH:
			m += int(ceil(float(layer["smooth_radius"]) / grid.cell)) * 2 + 1
	return m

static func has_height_layers(layers: Array) -> bool:
	for layer in layers:
		var k := int(layer["kind"])
		if k == PaintKind.HEIGHT_DELTA or k == PaintKind.HEIGHT_ABSOLUTE or k == PaintKind.SMOOTH:
			var cr: Rect2i = layer["content_rect"]
			if cr.size.x > 0 and cr.size.y > 0:
				return true
	return false

## Recompose [param rect] (grid samples) of the final map from [param procedural].
static func apply_region(procedural, grid, layers: Array, rect: Rect2i, world: Rect2):
	var read: Rect2i = procedural.rect.intersection(rect.grow(margin_for(layers, grid)))
	var work = procedural.extract(read)
	for layer in layers:
		_apply_layer(work, grid, layer, world)
	return work.extract(rect)

static func _layer_grid_rect(layer: Dictionary, grid, world: Rect2) -> Rect2:
	var cr: Rect2i = layer["content_rect"]
	var g: int = layer["grid"]
	var px := world.size.x / float(g)
	return Rect2(world.position + Vector2(cr.position) * px - Vector2(px, px), (Vector2(cr.size) + Vector2(2, 2)) * px)

static func _apply_layer(work, grid, layer: Dictionary, world: Rect2) -> void:
	var kind := int(layer["kind"])
	if kind == PaintKind.TEXTURE or kind == PaintKind.MASK:
		return
	var cr: Rect2i = layer["content_rect"]
	if cr.size.x <= 0 or cr.size.y <= 0:
		return
	var opacity: float = layer["opacity"]
	if opacity <= 0.0:
		return
	var rect: Rect2i = work.rect.intersection(grid.rect_for_world(_layer_grid_rect(layer, grid, world), 1))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var g: int = layer["grid"]
	var gsize := Vector2i(g, g)
	var value: PackedFloat32Array = layer["value"]
	var coverage: PackedFloat32Array = layer["coverage"]
	var scale := float(g) / world.size.x
	var mask_w := PackedFloat32Array()
	if layer["mask"] != null:
		mask_w = layer["mask"].weights(grid, rect, work)
	var blurred := PackedFloat32Array()
	if kind == PaintKind.SMOOTH:
		blurred = work.blurred(rect, layer["smooth_radius"], grid.cell, 2)
	var d: PackedFloat32Array = work.data
	var ww: int = work.rect.size.x
	var w := rect.size.x
	for y in rect.size.y:
		var gy := rect.position.y + y
		var wz: float = grid.origin.y + gy * grid.cell
		var fy := (wz - world.position.y) * scale - 0.5
		var row: int = (gy - work.rect.position.y) * ww - work.rect.position.x
		for x in w:
			var gx := rect.position.x + x
			var wx: float = grid.origin.x + gx * grid.cell
			var fx := (wx - world.position.x) * scale - 0.5
			var k := y * w + x
			var m := opacity
			if not mask_w.is_empty():
				m *= mask_w[k]
			if m <= 0.0:
				continue
			var i := row + gx
			match kind:
				PaintKind.HEIGHT_DELTA:
					d[i] += Raster.sample_buffer(value, gsize, fx, fy) * m
				PaintKind.HEIGHT_ABSOLUTE:
					var c := Raster.sample_buffer(coverage, gsize, fx, fy)
					if c > 0.0:
						d[i] = lerpf(d[i], Raster.sample_buffer(value, gsize, fx, fy), clampf(c * m, 0.0, 1.0))
				PaintKind.SMOOTH:
					var s := Raster.sample_buffer(value, gsize, fx, fy) * m
					if s > 0.0:
						d[i] = lerpf(d[i], blurred[k], clampf(s, 0.0, 1.0))

## World XZ rect touched by a paint px rect of a layer of [param grid_px] pixels.
static func paint_rect_to_world(rect: Rect2i, grid_px: int, world: Rect2) -> Rect2:
	var px := world.size.x / float(grid_px)
	return Rect2(world.position + Vector2(rect.position) * px, Vector2(rect.size) * px)
