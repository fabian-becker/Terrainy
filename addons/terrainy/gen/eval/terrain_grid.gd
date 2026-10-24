@tool
extends RefCounted

## Square composition grid of a [TerrainGenerator].
##
## [member resolution] is the number of cells per side (0.7 semantics), so the vertex grid
## holds `resolution + 1` samples per side and the default 256 cells over 256 m gives exactly
## 1 m cells. Sample (0, 0) sits at the terrain's -X/-Z corner, sample (resolution, resolution)
## at the +X/+Z corner. World coordinates are XZ; heights are relative to the generator's own
## y (the chunk meshes live in generator-local space).
##
## Immutable value object: safe to hand to worker threads.

var resolution: int = 256
var size: float = 256.0
## World XZ of sample (0, 0).
var origin: Vector2 = Vector2.ZERO
## World size of one cell.
var cell: float = 1.0
## Samples per side (`resolution + 1`).
var samples: int = 257

func _init(p_resolution: int = 256, p_size: float = 256.0, center: Vector2 = Vector2.ZERO) -> void:
	resolution = maxi(p_resolution, 1)
	size = maxf(p_size, 0.001)
	samples = resolution + 1
	cell = size / float(resolution)
	origin = center - Vector2(size, size) * 0.5

func full_rect() -> Rect2i:
	return Rect2i(0, 0, samples, samples)

## World XZ rectangle covered by the grid.
func world_rect() -> Rect2:
	return Rect2(origin, Vector2(size, size))

func world_of(px: int, py: int) -> Vector2:
	return Vector2(origin.x + px * cell, origin.y + py * cell)

## Fractional sample coordinates of a world XZ position.
func sample_of(world_xz: Vector2) -> Vector2:
	return (world_xz - origin) / cell

## Sample rectangle (clamped, inclusive of [param padding] samples of slack) covering a world
## XZ rectangle. Empty when the rectangle misses the terrain.
func rect_for_world(world: Rect2, padding: int = 1) -> Rect2i:
	if world.size.x < 0.0 or world.size.y < 0.0:
		return Rect2i()
	var a := sample_of(world.position)
	var b := sample_of(world.end)
	var x0 := int(floor(a.x)) - padding
	var y0 := int(floor(a.y)) - padding
	var x1 := int(ceil(b.x)) + padding
	var y1 := int(ceil(b.y)) + padding
	if x1 < 0 or y1 < 0 or x0 > samples - 1 or y0 > samples - 1:
		return Rect2i()
	x0 = clampi(x0, 0, samples - 1)
	y0 = clampi(y0, 0, samples - 1)
	x1 = clampi(x1, 0, samples - 1)
	y1 = clampi(y1, 0, samples - 1)
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)

## World XZ rectangle spanned by a sample rectangle.
func world_of_rect(rect: Rect2i) -> Rect2:
	var a := world_of(rect.position.x, rect.position.y)
	return Rect2(a, Vector2(maxi(rect.size.x - 1, 0), maxi(rect.size.y - 1, 0)) * cell)

func equals(other) -> bool:
	return other != null and other.resolution == resolution and is_equal_approx(other.size, size) \
		and other.origin.is_equal_approx(origin)

func signature() -> Array:
	return [resolution, size, origin]
