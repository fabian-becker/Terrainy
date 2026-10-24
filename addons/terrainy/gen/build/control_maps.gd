@tool
extends RefCounted

## Stage 6: folds procedural surface contributions and TEXTURE paint layers into one R8 weight
## plane per palette layer (the documented custom-material contract, see api.md):
##
##     terrainy_weight_planes[i] = claim of palette layer i (0..1), sum over layers <= 1
##
## Order: REPLACE contributions first (stacked like repeated mixes, gated contributions scaled
## by the layer's own height/slope blend), then TEXTURE paint layers in layer order. A paint
## value p for layer k scales every claim by (1 - p) and adds p to layer k, so paint wins over
## contributions where painted. ADD / SUPPRESS contributions go to the RG8 modulation planes.
##
## Plane resolution: the paint grid when a TEXTURE layer holds paint, otherwise the composition
## grid. Worker safe.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const MaterialBuilder = preload("res://addons/terrainy/gen/build/material_builder.gd")

const PaintKind = TerrainPaintLayer.PaintKind

## Inputs are captured on the main thread with [method capture_palette].
## [param units]: Array of {node_id, contributions}; [param unit_weights]: node_id -> HMap;
## [param heights]: final full-grid HMap; [param paint]: paint layer snapshots;
## [param palette]: Array of layer param dictionaries (see capture_palette).
## [param size_override] forces the plane size (stroke updates keep the current planes);
## [param region] limits the work to a plane pixel rect: the returned images then cover only
## that rect (`"region"` in the result) and are meant to be blitted into the current planes.
static func plane_size_for(grid, paint: Array, palette_size: int, paint_grid: int) -> int:
	for layer in paint:
		if int(layer["kind"]) == PaintKind.TEXTURE and int(layer["texture_layer"]) < palette_size:
			var cr: Rect2i = layer["content_rect"]
			if cr.size.x > 0 and cr.size.y > 0:
				return paint_grid
	return grid.samples

static func build(grid, world: Rect2, heights, units: Array, unit_weights: Dictionary, paint: Array, palette: Array, paint_grid: int, size_override: int = -1, region: Rect2i = Rect2i()) -> Dictionary:
	var n := palette.size()
	var texture_layers: Array = []
	for layer in paint:
		if int(layer["kind"]) == PaintKind.TEXTURE and int(layer["texture_layer"]) < n:
			var cr: Rect2i = layer["content_rect"]
			if cr.size.x > 0 and cr.size.y > 0:
				texture_layers.append(layer)
	var claim_units: Array = []
	var mod_units: Array = []
	for u in units:
		for c in u["contributions"]:
			if int(c["layer"]) >= n:
				continue
			if int(c["mode"]) == 0:
				claim_units.append([u["node_id"], c])
			else:
				mod_units.append([u["node_id"], c])
	var size: int = size_override if size_override > 0 else (paint_grid if not texture_layers.is_empty() else grid.samples)
	var full := Rect2i(0, 0, size, size)
	var area: Rect2i = full if region.size.x <= 0 or region.size.y <= 0 else region.intersection(full)
	var aw := area.size.x
	var result := {
		"size": size,
		"region": area,
		"claims": [],
		"modulation": [],
		"has_claims": not (claim_units.is_empty() and texture_layers.is_empty()),
		"has_modulation": not mod_units.is_empty(),
	}
	var claims: Array = []
	for i in n:
		var buf := PackedFloat32Array()
		buf.resize(aw * area.size.y)
		claims.append(buf)
	var px_world := world.size.x / float(size)
	# Sample position of plane pixel p: paint grid = pixel centers, composition grid = samples.
	# Track where `size` came from instead of comparing sizes: when paint_grid happens to equal
	# grid.samples the coordinate conventions still differ by half a cell.
	var on_paint_grid := not texture_layers.is_empty()
	if not claim_units.is_empty():
		for entry in claim_units:
			var wmap = unit_weights.get(entry[0])
			if wmap == null:
				continue
			var c: Dictionary = entry[1]
			var k: int = c["layer"]
			var strength: float = c["strength"]
			var gate: bool = c["gate"]
			var buf: PackedFloat32Array = claims[k]
			var rect := _plane_rect_for(wmap.rect, grid, world, size, on_paint_grid).intersection(area)
			for y in rect.size.y:
				var py := rect.position.y + y
				for x in rect.size.x:
					var pxi := rect.position.x + x
					var g := _grid_coord(pxi, py, grid, world, size, on_paint_grid, px_world)
					var v: float = wmap.sample_bilinear(g.x, g.y) if on_paint_grid else wmap.get_at(int(g.x), int(g.y))
					v = clampf(v * strength, 0.0, 1.0)
					if v <= 0.0:
						continue
					if gate:
						v *= _gate(palette[k], heights, grid, g)
					var i := (py - area.position.y) * aw + pxi - area.position.x
					buf[i] = 1.0 - (1.0 - buf[i]) * (1.0 - v)
		# Claims on several layers saturate at a total of 1 (proportional share).
		if claim_units.size() > 1:
			_normalize_total(claims, aw * area.size.y)
	for layer in texture_layers:
		var k: int = layer["texture_layer"]
		var cr: Rect2i = layer["content_rect"]
		var lg: int = layer["grid"]
		var value: PackedFloat32Array = layer["value"]
		var opacity: float = layer["opacity"]
		var mask = layer["mask"]
		var scale := float(size) / float(lg)
		var rect := Rect2i(Vector2i((Vector2(cr.position) * scale).floor()) - Vector2i.ONE,
			Vector2i((Vector2(cr.size) * scale).ceil()) + Vector2i(3, 3)).intersection(area)
		for y in rect.size.y:
			var py := rect.position.y + y
			for x in rect.size.x:
				var pxi := rect.position.x + x
				var p := Raster.sample_buffer(value, Vector2i(lg, lg), (pxi + 0.5) / scale - 0.5, (py + 0.5) / scale - 0.5) * opacity
				if p <= 0.0:
					continue
				if mask != null:
					var wpos := Vector2(world.position.x + (pxi + 0.5) * px_world, world.position.y + (py + 0.5) * px_world)
					p *= mask.value_at(wpos.x, wpos.y, 0.0, 0.0)
					if p <= 0.0:
						continue
				p = minf(p, 1.0)
				var i := (py - area.position.y) * aw + pxi - area.position.x
				for j in n:
					var b: PackedFloat32Array = claims[j]
					b[i] *= 1.0 - p
				var bk: PackedFloat32Array = claims[k]
				bk[i] += p
	for i in n:
		var buf: PackedFloat32Array = claims[i]
		result["claims"].append(_to_r8(buf, aw, area.size.y))
	if not mod_units.is_empty() and area == full:
		var s = grid.samples
		var mods: Array = []
		for i in n:
			var b := PackedFloat32Array()
			b.resize(s * s * 2)
			mods.append(b)
		for entry in mod_units:
			var wmap = unit_weights.get(entry[0])
			if wmap == null:
				continue
			var c: Dictionary = entry[1]
			var k: int = c["layer"]
			var channel := 0 if int(c["mode"]) == 1 else 1
			var b: PackedFloat32Array = mods[k]
			var r: Rect2i = wmap.rect
			for y in r.size.y:
				for x in r.size.x:
					var v: float = clampf(wmap.data[y * r.size.x + x] * float(c["strength"]), 0.0, 1.0)
					if v <= 0.0:
						continue
					if c["gate"]:
						v *= _gate(palette[k], heights, grid, Vector2(r.position.x + x, r.position.y + y))
					var i = ((r.position.y + y) * s + r.position.x + x) * 2 + channel
					b[i] = 1.0 - (1.0 - b[i]) * (1.0 - v)
		for i in n:
			result["modulation"].append(_to_rg8(mods[i], s))
	return result

static func _plane_rect_for(map_rect: Rect2i, grid, world: Rect2, size: int, on_paint_grid: bool) -> Rect2i:
	if not on_paint_grid:
		return map_rect
	var w: Rect2 = grid.world_of_rect(map_rect)
	var px := world.size.x / float(size)
	var x0 := int(floor((w.position.x - world.position.x) / px)) - 1
	var y0 := int(floor((w.position.y - world.position.y) / px)) - 1
	var x1 := int(ceil((w.end.x - world.position.x) / px)) + 1
	var y1 := int(ceil((w.end.y - world.position.y) / px)) + 1
	return Rect2i(x0, y0, x1 - x0, y1 - y0).intersection(Rect2i(0, 0, size, size))

static func _grid_coord(px: int, py: int, grid, world: Rect2, size: int, on_paint_grid: bool, px_world: float) -> Vector2:
	if not on_paint_grid:
		return Vector2(px, py)
	var wx := world.position.x + (px + 0.5) * px_world
	var wz := world.position.y + (py + 0.5) * px_world
	return grid.sample_of(Vector2(wx, wz))

static func _gate(layer: Dictionary, heights, grid, g: Vector2) -> float:
	if heights == null:
		return 1.0
	var gx := clampi(int(round(g.x)), 0, grid.samples - 1)
	var gy := clampi(int(round(g.y)), 0, grid.samples - 1)
	var h: float = heights.get_at(gx, gy) + float(layer.get("y_offset", 0.0))
	var inv = 1.0 / (2.0 * grid.cell)
	var dx: float = (heights.get_at(mini(gx + 1, grid.samples - 1), gy) - heights.get_at(maxi(gx - 1, 0), gy)) * inv
	var dz: float = (heights.get_at(gx, mini(gy + 1, grid.samples - 1)) - heights.get_at(gx, maxi(gy - 1, 0))) * inv
	var slope := atan(sqrt(dx * dx + dz * dz))
	return MaterialBuilder.layer_weight(layer, h, slope, 0.0)

static func _normalize_total(claims: Array, count: int) -> void:
	for i in count:
		var total := 0.0
		for b in claims:
			total += b[i]
		if total > 1.0:
			for b in claims:
				b[i] /= total

static func _to_r8(buf: PackedFloat32Array, w: int, h: int) -> Image:
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RF, buf.to_byte_array())
	img.convert(Image.FORMAT_R8)
	return img

static func _to_rg8(buf: PackedFloat32Array, size: int) -> Image:
	var img := Image.create_from_data(size, size, false, Image.FORMAT_RGF, buf.to_byte_array())
	img.convert(Image.FORMAT_RG8)
	return img
