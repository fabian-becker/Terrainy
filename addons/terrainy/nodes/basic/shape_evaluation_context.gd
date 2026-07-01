@tool
class_name ShapeEvaluationContext
extends EvaluationContext

## Specialized context for mask-based shape terrain features.
## Captures immutable mask data and rotation for thread-safe evaluation.

## 2D rotation matrix (pre-computed Basis for XZ plane rotation)
var rotation_matrix: Basis

## Smoothness factor for shape edges
var smoothness: float

## Height of the shape
var shape_height: float

var rotation_angle: float = 0.0
var mask_size: Vector2i = Vector2i.ZERO
var mask_data: PackedFloat32Array = PackedFloat32Array()
var shape_mode: int = 0

## Create a ShapeEvaluationContext from a terrain feature node.
static func from_shape_feature(
	feature: TerrainFeatureNode,
	height: float,
	smooth: float,
	rotation: float,
	packed_mask_data: PackedFloat32Array,
	packed_mask_size: Vector2i,
	shape_mode_val: int = 0
) -> ShapeEvaluationContext:
	var ctx = ShapeEvaluationContext.new()

	# Copy base context properties
	ctx.world_position = feature.global_position
	ctx.inverse_transform = feature.global_transform.affine_inverse()
	ctx.influence_shape = feature.influence_shape
	ctx.influence_size = feature.influence_size
	ctx.influence_radius = EvaluationContext.get_influence_radius(ctx.influence_shape, ctx.influence_size)
	ctx.influence_radius_sq = ctx.influence_radius * ctx.influence_radius
	ctx.edge_falloff = feature.edge_falloff
	ctx.strength = feature.strength
	ctx.blend_mode = feature.blend_mode

	ctx.aabb = EvaluationContext.compute_rotation_aware_aabb(feature.global_transform, ctx.world_position, ctx.influence_shape, ctx.influence_size)

	# Add shape-specific properties
	ctx.shape_height = height
	ctx.smoothness = smooth
	ctx.rotation_angle = rotation
	ctx.mask_data = packed_mask_data
	ctx.mask_size = packed_mask_size
	ctx.shape_mode = shape_mode_val

	# Pre-compute 2D rotation matrix for XZ plane
	# This allows rotating shape coordinates without scene tree access
	ctx.rotation_matrix = Basis(Vector3.UP, rotation)

	return ctx

## Rotate a 2D point (XZ plane) using the pre-computed rotation matrix.
func rotate_point_2d(point: Vector2) -> Vector2:
	var point_3d = Vector3(point.x, 0, point.y)
	var rotated = rotation_matrix * point_3d
	return Vector2(rotated.x, rotated.z)

func sample_mask(uv: Vector2) -> float:
	if mask_size.x <= 0 or mask_size.y <= 0 or mask_data.is_empty():
		return 0.0
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return 0.0

	var x = uv.x * float(mask_size.x - 1)
	var y = uv.y * float(mask_size.y - 1)
	var x0 = int(floor(x))
	var y0 = int(floor(y))
	var x1 = mini(x0 + 1, mask_size.x - 1)
	var y1 = mini(y0 + 1, mask_size.y - 1)
	var dx = x - float(x0)
	var dy = y - float(y0)

	var idx00 = y0 * mask_size.x + x0
	var idx10 = y0 * mask_size.x + x1
	var idx01 = y1 * mask_size.x + x0
	var idx11 = y1 * mask_size.x + x1

	var h00 = mask_data[idx00]
	var h10 = mask_data[idx10]
	var h01 = mask_data[idx01]
	var h11 = mask_data[idx11]

	var h0 = lerp(h00, h10, dx)
	var h1 = lerp(h01, h11, dx)
	return lerp(h0, h1, dy)
