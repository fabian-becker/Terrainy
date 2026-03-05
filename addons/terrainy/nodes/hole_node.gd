@tool
class_name HoleNode
extends TerrainFeatureNode

## A terrain hole feature that creates passable openings in the terrain mesh.
## Holes always penetrate through the entire terrain depth.

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

func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint():
		name = "Hole"

func prepare_evaluation_context() -> EvaluationContext:
	var ctx = EvaluationContext.from_feature(self)
	ctx.set_meta("is_hole", true)
	ctx.set_meta("edge_type", edge_type)
	ctx.set_meta("edge_bevel_width", edge_bevel_width)
	return ctx

func get_height_at_safe(_world_pos: Vector3, _context: EvaluationContext) -> float:
	return 0.0

func get_gpu_param_pack() -> Dictionary:
	var extra_floats := PackedFloat32Array([edge_bevel_width])
	var extra_ints := PackedInt32Array([edge_type])
	return _build_gpu_param_pack(FeatureType.HOLE, extra_floats, extra_ints)

func get_hole_edge_extent() -> float:
	if edge_type == EdgeType.BEVELED:
		return edge_bevel_width
	return 0.0