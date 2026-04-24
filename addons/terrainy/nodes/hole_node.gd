@tool
class_name HoleNode
extends TerrainFeatureNode

## A terrain hole feature that creates passable openings in the terrain mesh.
## Holes always penetrate through the entire terrain depth.
## Rotation is supported: rotated holes project their shape onto the XZ plane.

enum EdgeType {
	SHARP,    ## Sharp vertical edges at hole boundaries
	BEVELED   ## Sloped edges around hole perimeter for smoother appearance
}

## Type of edge at hole boundaries
@export var edge_type: EdgeType = EdgeType.SHARP:
	set(value):
		edge_type = value
		_commit_parameter_change()

## Width of the bevel (slope) around hole edges, in world units.
## Only used when edge_type is BEVELED.
@export_range(0.1, 20.0) var edge_bevel_width: float = 2.0:
	set(value):
		edge_bevel_width = value
		_commit_parameter_change()

## Whether to use 3D influence calculation (for rotated holes).
## When true, considers the full 3D shape when rotated.
## When false, uses fast 2D approximation (ignores Y component).
@export var use_3d_influence: bool = false:
	set(value):
		use_3d_influence = value
		_commit_parameter_change()

## The height/depth extent for 3D hole calculation.
## For non-rotated holes this should match terrain depth.
## For rotated/tilted holes, this defines how far the hole extends.
@export var hole_depth: float = 100.0:
	set(value):
		hole_depth = max(1.0, value)
		_commit_parameter_change()

func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint():
		name = "Hole"

func prepare_evaluation_context() -> EvaluationContext:
	var ctx = EvaluationContext.from_feature(self)
	ctx.set_meta("is_hole", true)
	ctx.set_meta("edge_type", edge_type)
	ctx.set_meta("edge_bevel_width", edge_bevel_width)
	ctx.set_meta("use_3d_influence", use_3d_influence)
	ctx.set_meta("hole_depth", hole_depth)
	return ctx

func get_height_at_safe(_world_pos: Vector3, _context: EvaluationContext) -> float:
	return 0.0

func get_influence_weight_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	# Holes are boolean cut-out features, not blended height features.
	# Mask textures are intentionally ignored for holes.
	return _get_raw_influence_weight(world_pos, context)

func _get_raw_influence_weight(world_pos: Vector3, context: EvaluationContext) -> float:
	if not use_3d_influence:
		return context.get_influence_weight(world_pos)
	
	var shape_size = Vector3(influence_size.x, hole_depth, influence_size.y)
	return context.get_influence_weight_3d(world_pos, shape_size)

func get_gpu_param_pack() -> Dictionary:
	var extra_floats := PackedFloat32Array([edge_bevel_width, hole_depth])
	var extra_ints := PackedInt32Array([edge_type, 1 if use_3d_influence else 0])
	return _build_gpu_param_pack(FeatureType.HOLE, extra_floats, extra_ints)

func get_hole_edge_extent() -> float:
	if edge_type == EdgeType.BEVELED:
		return edge_bevel_width
	return 0.0