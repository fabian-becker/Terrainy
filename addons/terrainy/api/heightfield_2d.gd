@tool
class_name Heightfield2D
extends RefCounted

## A sampled block of terrain heights returned by TerrainyAPI.sample_region().
## Heights are world heights; sample (x, y) sits at
## `rect.position + Vector2(x, y) * rect.size / (resolution - Vector2i.ONE)`.

## World XZ rectangle covered (inclusive corners).
var rect: Rect2 = Rect2()
## Samples per axis.
var resolution: Vector2i = Vector2i.ZERO
## Row-major world heights (resolution.x * resolution.y).
var heights: PackedFloat32Array = PackedFloat32Array()
## Row-major hole flags (1 = hole), empty when the terrain has no holes.
var holes: PackedByteArray = PackedByteArray()

func get_height(x: int, y: int) -> float:
	return heights[clampi(y, 0, resolution.y - 1) * resolution.x + clampi(x, 0, resolution.x - 1)]

func is_hole(x: int, y: int) -> bool:
	if holes.is_empty():
		return false
	return holes[clampi(y, 0, resolution.y - 1) * resolution.x + clampi(x, 0, resolution.x - 1)] != 0

func world_position(x: int, y: int) -> Vector3:
	var step := rect.size / Vector2(maxi(resolution.x - 1, 1), maxi(resolution.y - 1, 1))
	return Vector3(rect.position.x + x * step.x, get_height(x, y), rect.position.y + y * step.y)

## Single channel FORMAT_RF image of the heights.
func to_image() -> Image:
	if resolution.x <= 0 or resolution.y <= 0:
		return null
	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, heights.to_byte_array())

func min_max() -> Vector2:
	var lo := INF
	var hi := -INF
	for h in heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	return Vector2(lo, hi)
