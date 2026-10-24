@tool
extends RefCounted

## Immutable, worker-safe snapshot of a [TerrainMaskResource].
##
## [method weights] returns the mask value (0..1) for every sample of a grid rectangle. Slope
## and elevation masks read [param dest]: the map the owner is about to modify, i.e. "the
## current heightmap state" at that point of the composition.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")

enum Kind { REGION, TEXTURE, PATH, SLOPE, ELEVATION, PAINT }

var kind: int = Kind.REGION
var invert: bool = false
var strength: float = 1.0

# Region / texture
var inv_xform: Transform3D = Transform3D.IDENTITY
var shape: int = 0
var half: Vector2 = Vector2.ONE
var falloff_lut: PackedFloat32Array = PackedFloat32Array()
var bounds: Rect2 = Rect2()
var texture_data: PackedFloat32Array = PackedFloat32Array()
var texture_size: Vector2i = Vector2i.ZERO

# Path
var polyline: PackedVector3Array = PackedVector3Array()
var half_width: float = 1.0

# Slope / elevation
var range_min: float = 0.0
var range_max: float = 1.0
var softness: float = 0.0
var reference_y: float = 0.0

# Paint (paint grid geometry)
var paint_origin: Vector2 = Vector2.ZERO
var paint_size: float = 1.0
var paint_grid: int = 1

var signature: String = ""

## Mask weights over [param rect] (row-major, one value per grid sample).
func weights(grid, rect: Rect2i, dest) -> PackedFloat32Array:
	var w := rect.size.x
	var h := rect.size.y
	var out := PackedFloat32Array()
	out.resize(w * h)
	match kind:
		Kind.REGION:
			_region(grid, rect, out)
		Kind.TEXTURE:
			_texture(grid, rect, out)
		Kind.PATH:
			_path(grid, rect, out)
		Kind.SLOPE:
			_slope(grid, rect, dest, out)
		Kind.ELEVATION:
			_elevation(rect, dest, out)
		Kind.PAINT:
			_paint(grid, rect, out)
	if invert or strength != 1.0:
		for i in out.size():
			var v := out[i]
			if invert:
				v = 1.0 - v
			out[i] = clampf(v * strength, 0.0, 1.0)
	return out

## Mask value at one world position (queries, scatter). [param height] is the generator-local
## terrain height and [param slope_deg] the slope there; only slope/elevation masks use them.
func value_at(wx: float, wz: float, height: float, slope_deg: float) -> float:
	var v := 0.0
	match kind:
		Kind.REGION:
			var l := inv_xform * Vector3(wx, 0.0, wz)
			var d := Raster.shape_distance(shape, l.x, l.z, half)
			v = 0.0 if d >= 1.0 else (CurveLut.sample(falloff_lut, 1.0 - d) if not falloff_lut.is_empty() else 1.0)
		Kind.TEXTURE:
			var l := inv_xform * Vector3(wx, 0.0, wz)
			v = _texture_at(l.x, l.z)
		Kind.PATH:
			var n := Raster.polyline_nearest(polyline, wx, wz)
			v = _path_weight(n.x)
		Kind.SLOPE:
			v = _band(slope_deg)
		Kind.ELEVATION:
			v = _band(height + reference_y)
		Kind.PAINT:
			v = _paint_at(wx, wz)
	if invert:
		v = 1.0 - v
	return clampf(v * strength, 0.0, 1.0)

func _band(value: float) -> float:
	var s := maxf(softness, 0.0)
	if s <= 0.0:
		return 1.0 if value >= range_min and value <= range_max else 0.0
	return Raster.smoothstep01(range_min - s, range_min, value) * (1.0 - Raster.smoothstep01(range_max, range_max + s, value))

func _region(grid, rect: Rect2i, out: PackedFloat32Array) -> void:
	var w := rect.size.x
	for y in rect.size.y:
		var gz: float = grid.origin.y + (rect.position.y + y) * grid.cell
		for x in w:
			var gx: float = grid.origin.x + (rect.position.x + x) * grid.cell
			var l := inv_xform * Vector3(gx, 0.0, gz)
			var d := Raster.shape_distance(shape, l.x, l.z, half)
			if d >= 1.0:
				continue
			out[y * w + x] = CurveLut.sample(falloff_lut, 1.0 - d) if not falloff_lut.is_empty() else 1.0

func _texture_at(lx: float, lz: float) -> float:
	if texture_size.x <= 0 or absf(lx) > half.x or absf(lz) > half.y:
		return 0.0
	var u := (lx / half.x) * 0.5 + 0.5
	var v := (lz / half.y) * 0.5 + 0.5
	return Raster.sample_buffer(texture_data, texture_size, u * (texture_size.x - 1), v * (texture_size.y - 1))

func _texture(grid, rect: Rect2i, out: PackedFloat32Array) -> void:
	var w := rect.size.x
	for y in rect.size.y:
		var gz: float = grid.origin.y + (rect.position.y + y) * grid.cell
		for x in w:
			var gx: float = grid.origin.x + (rect.position.x + x) * grid.cell
			var l := inv_xform * Vector3(gx, 0.0, gz)
			out[y * w + x] = _texture_at(l.x, l.z)

func _path_weight(d: float) -> float:
	if d >= half_width:
		return 0.0
	var e := 1.0 - d / maxf(half_width, 0.0001)
	return CurveLut.sample(falloff_lut, e) if not falloff_lut.is_empty() else 1.0

func _path(grid, rect: Rect2i, out: PackedFloat32Array) -> void:
	var raster := Raster.rasterize_polyline(polyline, half_width, grid, rect)
	var dist: PackedFloat32Array = raster["dist"]
	for i in out.size():
		if dist[i] < half_width:
			out[i] = _path_weight(dist[i])

func _slope(grid, rect: Rect2i, dest, out: PackedFloat32Array) -> void:
	if dest == null:
		return
	var w := rect.size.x
	var inv: float = 1.0 / (2.0 * grid.cell)
	for y in rect.size.y:
		var gy := rect.position.y + y
		for x in w:
			var gx := rect.position.x + x
			var dx: float = (dest.get_at(gx + 1, gy, dest.get_at(gx, gy)) - dest.get_at(gx - 1, gy, dest.get_at(gx, gy))) * inv
			var dz: float = (dest.get_at(gx, gy + 1, dest.get_at(gx, gy)) - dest.get_at(gx, gy - 1, dest.get_at(gx, gy))) * inv
			out[y * w + x] = _band(rad_to_deg(atan(sqrt(dx * dx + dz * dz))))

func _elevation(rect: Rect2i, dest, out: PackedFloat32Array) -> void:
	if dest == null:
		return
	var w := rect.size.x
	for y in rect.size.y:
		for x in w:
			out[y * w + x] = _band(dest.get_at(rect.position.x + x, rect.position.y + y) + reference_y)

func _paint_at(wx: float, wz: float) -> float:
	if texture_size.x <= 0:
		return 0.0
	var px := (wx - paint_origin.x) / paint_size * paint_grid - 0.5
	var py := (wz - paint_origin.y) / paint_size * paint_grid - 0.5
	return Raster.sample_buffer(texture_data, texture_size, px, py)

func _paint(grid, rect: Rect2i, out: PackedFloat32Array) -> void:
	var w := rect.size.x
	for y in rect.size.y:
		var gz: float = grid.origin.y + (rect.position.y + y) * grid.cell
		for x in w:
			out[y * w + x] = _paint_at(grid.origin.x + (rect.position.x + x) * grid.cell, gz)
