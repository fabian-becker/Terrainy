@tool
class_name ShapeEvaluationContext
extends EvaluationContext

## Specialized context for shape-based terrain features.
## Captures shape geometry and rotation for thread-safe evaluation.

## 2D rotation matrix (pre-computed Basis for XZ plane rotation)
var rotation_matrix: Basis

## Shape type (circle, square, triangle, etc.)
var shape_type: int

## Smoothness factor for shape edges
var smoothness: float

## Height of the shape
var shape_height: float

## Additional shape parameters
var inner_radius_ratio: float = 0.0
var rotation_angle: float = 0.0

## Create a ShapeEvaluationContext from a terrain feature node.
static func from_shape_feature(feature: TerrainFeatureNode, height: float, shape: int, smooth: float = 0.0, rotation: float = 0.0) -> ShapeEvaluationContext:
	var ctx = ShapeEvaluationContext.new()
	
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
	
	# Add shape-specific properties
	ctx.shape_height = height
	ctx.shape_type = shape
	ctx.smoothness = smooth
	ctx.rotation_angle = rotation
	
	# Pre-compute 2D rotation matrix for XZ plane
	# This allows rotating shape coordinates without scene tree access
	ctx.rotation_matrix = Basis(Vector3.UP, rotation)
	
	# Try to get inner radius if available (for ring shapes, etc.)
	if "inner_radius_ratio" in feature:
		ctx.inner_radius_ratio = feature.get("inner_radius_ratio")
	
	return ctx

## Rotate a 2D point (XZ plane) using the pre-computed rotation matrix.
func rotate_point_2d(point: Vector2) -> Vector2:
	var point_3d = Vector3(point.x, 0, point.y)
	var rotated = rotation_matrix * point_3d
	return Vector2(rotated.x, rotated.z)

## Calculate shape distance for various geometric shapes.
## Returns normalized distance (0 at center, 1 at edge, >1 outside).
func get_shape_distance(local_pos: Vector3) -> float:
	var pos_2d = Vector2(local_pos.x, local_pos.z)
	
	# Apply rotation if needed
	if abs(rotation_angle) > 0.001:
		pos_2d = rotate_point_2d(pos_2d)
	
	# Normalize by influence size
	var normalized_pos = Vector2(
		pos_2d.x / (influence_size.x * 0.5),
		pos_2d.y / (influence_size.y * 0.5)
	)
	
	match shape_type:
		0: # Circle
			return normalized_pos.length()
		1: # Square
			return max(abs(normalized_pos.x), abs(normalized_pos.y))
		2: # Triangle
			return _get_triangle_distance(normalized_pos)
		3: # Hexagon
			return _get_hexagon_distance(normalized_pos)
		4: # Ring
			var dist = normalized_pos.length()
			if dist < inner_radius_ratio:
				return 1.0 + (inner_radius_ratio - dist)
			return dist
		_:
			return normalized_pos.length()

## Calculate distance to triangle edge (normalized).
func _get_triangle_distance(pos: Vector2) -> float:
	# Equilateral triangle pointing up
	var abs_x = abs(pos.x)
	var y_adjusted = pos.y + 0.5
	
	if y_adjusted < -0.866:
		return 1.0
	
	var dist_to_side = (abs_x * 0.866 + y_adjusted * 0.5)
	return max(dist_to_side, -y_adjusted)

## Calculate distance to hexagon edge (normalized).
func _get_hexagon_distance(pos: Vector2) -> float:
	var abs_pos = Vector2(abs(pos.x), abs(pos.y))
	var dist = max(abs_pos.x * 0.866 + abs_pos.y * 0.5, abs_pos.y)
	return dist
