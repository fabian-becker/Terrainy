@tool
class_name HeightmapEvaluationContext
extends EvaluationContext

## Specialized context for heightmap-based terrain features.
## Captures heightmap data for thread-safe evaluation.

const WRAP_CLAMP := 0
const WRAP_REPEAT := 1

## Heightmap data (0..1 range)
var height_data: PackedFloat32Array

## Heightmap size (width, height)
var heightmap_size: Vector2i

## Height scale and offset
var height_scale: float
var height_offset: float

## Wrap mode (0=clamp, 1=repeat)
var wrap_mode: int = WRAP_CLAMP

## Invert height values (1 - value)
var invert: bool = false

## Create a HeightmapEvaluationContext from a terrain feature node.
static func from_heightmap_feature(
	feature: TerrainFeatureNode,
	data: PackedFloat32Array,
	size: Vector2i,
	scale: float,
	offset: float,
	wrap: int,
	invert_height: bool
) -> HeightmapEvaluationContext:
	var ctx = HeightmapEvaluationContext.new()

	# Copy base context properties
	ctx.world_position = feature.global_position
	ctx.inverse_transform = feature.global_transform.affine_inverse()
	ctx.influence_shape = feature.influence_shape
	ctx.influence_size = feature.influence_size
	ctx.influence_radius = max(feature.influence_size.x, feature.influence_size.y)
	ctx.influence_radius_sq = ctx.influence_radius * ctx.influence_radius
	ctx.edge_falloff = feature.edge_falloff
	ctx.strength = feature.strength
	ctx.blend_mode = feature.blend_mode

	var half_size = Vector3(ctx.influence_radius, 1000.0, ctx.influence_radius)
	ctx.aabb = AABB(ctx.world_position - half_size, half_size * 2.0)

	# Heightmap-specific properties
	ctx.height_data = data
	ctx.heightmap_size = size
	ctx.height_scale = scale
	ctx.height_offset = offset
	ctx.wrap_mode = wrap
	ctx.invert = invert_height

	return ctx

## Sample heightmap at UV (0..1). Returns world height.
func sample_height(uv: Vector2) -> float:
	if heightmap_size.x <= 0 or heightmap_size.y <= 0:
		return 0.0
	if height_data.is_empty():
		return 0.0

	var u = uv.x
	var v = uv.y

	match wrap_mode:
		WRAP_REPEAT:
			u = u - floor(u)
			v = v - floor(v)
		_:
			u = clamp(u, 0.0, 1.0)
			v = clamp(v, 0.0, 1.0)

	var width = heightmap_size.x
	var height = heightmap_size.y
	var x = u * float(width - 1)
	var y = v * float(height - 1)

	var x0 = int(floor(x))
	var y0 = int(floor(y))
	var x1 = min(x0 + 1, width - 1)
	var y1 = min(y0 + 1, height - 1)

	var dx = x - float(x0)
	var dy = y - float(y0)

	var idx00 = y0 * width + x0
	var idx10 = y0 * width + x1
	var idx01 = y1 * width + x0
	var idx11 = y1 * width + x1

	var h00 = height_data[idx00]
	var h10 = height_data[idx10]
	var h01 = height_data[idx01]
	var h11 = height_data[idx11]

	var h0 = lerp(h00, h10, dx)
	var h1 = lerp(h01, h11, dx)
	var h = lerp(h0, h1, dy)

	if invert:
		h = 1.0 - h

	return (h * height_scale) + height_offset
