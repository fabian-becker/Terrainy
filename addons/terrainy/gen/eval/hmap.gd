@tool
extends RefCounted

## A float map covering a sample rectangle of the composition grid.
##
## Field maps only cover the field's own bounds; group composites and the terrain composite
## cover the full grid. Coordinates passed to [method index_of] are absolute grid samples.

var rect: Rect2i = Rect2i()
var data: PackedFloat32Array = PackedFloat32Array()

func _init(p_rect: Rect2i = Rect2i(), fill: float = 0.0) -> void:
	rect = p_rect
	data = PackedFloat32Array()
	data.resize(maxi(rect.size.x, 0) * maxi(rect.size.y, 0))
	if fill != 0.0:
		data.fill(fill)

func width() -> int:
	return rect.size.x

func height() -> int:
	return rect.size.y

func is_empty() -> bool:
	return rect.size.x <= 0 or rect.size.y <= 0

func has_sample(x: int, y: int) -> bool:
	return x >= rect.position.x and y >= rect.position.y and x < rect.end.x and y < rect.end.y

func index_of(x: int, y: int) -> int:
	return (y - rect.position.y) * rect.size.x + (x - rect.position.x)

func get_at(x: int, y: int, fallback: float = 0.0) -> float:
	if not has_sample(x, y):
		return fallback
	return data[index_of(x, y)]

func duplicate_map() -> RefCounted:
	var copy = get_script().new(Rect2i())
	copy.rect = rect
	copy.data = data.duplicate()
	return copy

## Copy of the sub rectangle [param sub] (clipped to this map). Row copies are native slices.
func extract(sub: Rect2i) -> RefCounted:
	var clipped := rect.intersection(sub)
	var out = get_script().new(Rect2i())
	out.rect = clipped
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		out.rect = Rect2i(clipped.position, Vector2i.ZERO)
		return out
	var w := rect.size.x
	var ow := clipped.size.x
	if clipped == rect:
		out.data = data.duplicate()
		return out
	var buf := PackedFloat32Array()
	for y in clipped.size.y:
		var src := (clipped.position.y + y - rect.position.y) * w + (clipped.position.x - rect.position.x)
		buf.append_array(data.slice(src, src + ow))
	out.data = buf
	return out

## Write the overlapping part of [param other] into this map (rebuilds rows natively).
func paste(other) -> void:
	var clipped := rect.intersection(other.rect)
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	var w := rect.size.x
	var ow: int = other.rect.size.x
	var buf := PackedFloat32Array()
	var first := (clipped.position.y - rect.position.y) * w
	buf.append_array(data.slice(0, first))
	var left := clipped.position.x - rect.position.x
	var right := left + clipped.size.x
	for y in clipped.size.y:
		var gy := clipped.position.y + y
		var row := (gy - rect.position.y) * w
		var src: int = (gy - other.rect.position.y) * ow + (clipped.position.x - other.rect.position.x)
		buf.append_array(data.slice(row, row + left))
		buf.append_array(other.data.slice(src, src + clipped.size.x))
		buf.append_array(data.slice(row + right, row + w))
	buf.append_array(data.slice((clipped.end.y - rect.position.y) * w))
	data = buf

## Bilinear sample at fractional grid coordinates, clamped to the map.
func sample_bilinear(gx: float, gy: float) -> float:
	if is_empty():
		return 0.0
	var fx := clampf(gx - rect.position.x, 0.0, float(rect.size.x - 1))
	var fy := clampf(gy - rect.position.y, 0.0, float(rect.size.y - 1))
	var x0 := int(fx)
	var y0 := int(fy)
	var x1 := mini(x0 + 1, rect.size.x - 1)
	var y1 := mini(y0 + 1, rect.size.y - 1)
	var tx := fx - x0
	var ty := fy - y0
	var w := rect.size.x
	var a := lerpf(data[y0 * w + x0], data[y0 * w + x1], tx)
	var b := lerpf(data[y1 * w + x0], data[y1 * w + x1], tx)
	return lerpf(a, b, ty)

## Separable box blur (repeated -> approximately gaussian) of [param region], returned as a
## buffer laid out over that region. [param radius] is in meters, [param cell] the grid cell size.
## The blur reads a margin around the region from the whole map, so the result does not depend on
## how far the region reaches -- which is what lets paint strokes blur a sub-rect and still match
## a full-map smooth.
func blurred(region: Rect2i, radius: float, cell: float, iterations: int) -> PackedFloat32Array:
	var r := maxi(int(round(radius / maxf(cell, 0.0001))), 1)
	var read := rect.intersection(region.grow(r * iterations))
	var rw := read.size.x
	var rh := read.size.y
	if rw <= 0 or rh <= 0:
		return PackedFloat32Array()
	var buf := PackedFloat32Array()
	buf.resize(rw * rh)
	var mw: int = rect.size.x
	for y in rh:
		var src: int = (read.position.y + y - rect.position.y) * mw + (read.position.x - rect.position.x)
		for x in rw:
			buf[y * rw + x] = data[src + x]
	var tmp := PackedFloat32Array()
	tmp.resize(rw * rh)
	var inv := 1.0 / float(2 * r + 1)
	for _it in maxi(iterations, 1):
		# Horizontal
		for y in rh:
			var row := y * rw
			var acc := 0.0
			for k in range(-r, r + 1):
				acc += buf[row + clampi(k, 0, rw - 1)]
			for x in rw:
				tmp[row + x] = acc * inv
				acc += buf[row + mini(x + r + 1, rw - 1)] - buf[row + maxi(x - r, 0)]
		# Vertical
		for x in rw:
			var acc := 0.0
			for k in range(-r, r + 1):
				acc += tmp[clampi(k, 0, rh - 1) * rw + x]
			for y in rh:
				buf[y * rw + x] = acc * inv
				acc += tmp[mini(y + r + 1, rh - 1) * rw + x] - tmp[maxi(y - r, 0) * rw + x]
	var out := PackedFloat32Array()
	out.resize(region.size.x * region.size.y)
	for y in region.size.y:
		var src := (region.position.y + y - read.position.y) * rw + (region.position.x - read.position.x)
		for x in region.size.x:
			out[y * region.size.x + x] = buf[src + x]
	return out

func to_image() -> Image:
	if is_empty():
		return null
	return Image.create_from_data(rect.size.x, rect.size.y, false, Image.FORMAT_RF, data.to_byte_array())

static func from_image(image: Image, at: Vector2i = Vector2i.ZERO) -> RefCounted:
	var map = load("res://addons/terrainy/gen/eval/hmap.gd").new(Rect2i(at, image.get_size()))
	var copy := image
	if image.get_format() != Image.FORMAT_RF:
		copy = image.duplicate()
		copy.convert(Image.FORMAT_RF)
	map.data = copy.get_data().to_float32_array()
	return map

func min_max() -> Vector2:
	if data.is_empty():
		return Vector2.ZERO
	var lo := INF
	var hi := -INF
	for v in data:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return Vector2(lo, hi)
