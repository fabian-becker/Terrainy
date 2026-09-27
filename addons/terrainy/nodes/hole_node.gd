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
## [b]Note:[/b] This auto-enables when the node is rotated in the editor.
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
		_auto_enable_3d_influence_if_rotated()

func _enter_tree() -> void:
	_auto_enable_3d_influence_if_rotated()

func _notification(what: int) -> void:
	super._notification(what)
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		if Engine.is_editor_hint() and is_node_ready() and not use_3d_influence:
			if not global_transform.basis.is_equal_approx(Basis.IDENTITY):
				use_3d_influence = true
				push_warning("[%s] Auto-enabled 'use_3d_influence' because the hole is rotated. Disable manually if 2D projection is intended." % name)

func _auto_enable_3d_influence_if_rotated() -> void:
	if Engine.is_editor_hint() and not use_3d_influence:
		if not global_transform.basis.is_equal_approx(Basis.IDENTITY):
			use_3d_influence = true
			push_warning("[%s] Auto-enabled 'use_3d_influence' because the hole is rotated. Disable manually if 2D projection is intended." % name)

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = []
	var hide := [
		"edge_falloff",
		"blend_mode",
		"strength",
		"smoothing",
		"smoothing_radius",
		"enable_terracing",
		"terrace_levels",
		"terrace_smoothness",
		"enable_min_clamp",
		"min_height",
		"enable_max_clamp",
		"max_height",
		"mask_texture",
		"mask_channel",
		"mask_invert"
	]
	for name_prop in hide:
		props.append({
			"name": name_prop,
			"type": TYPE_NIL,
			"usage": PROPERTY_USAGE_NO_EDITOR,
			"hint": PROPERTY_HINT_NONE
		})
	return props

func prepare_evaluation_context() -> EvaluationContext:
	var ctx = EvaluationContext.from_feature(self)
	ctx.set_meta("is_hole", true)
	ctx.set_meta("edge_type", edge_type)
	ctx.set_meta("edge_bevel_width", edge_bevel_width)
	ctx.set_meta("use_3d_influence", use_3d_influence)
	ctx.set_meta("hole_depth", hole_depth)
	return ctx

func is_hole_feature() -> bool:
	return true

func get_hole_3d_influence() -> bool:
	return use_3d_influence

func get_hole_depth() -> float:
	return hole_depth

func get_hole_edge_extent() -> float:
	if edge_type == EdgeType.BEVELED:
		return edge_bevel_width
	return 0.0

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

func is_point_inside_hole(world_pos: Vector3) -> bool:
	var ctx = prepare_evaluation_context()
	return get_influence_weight_safe(world_pos, ctx) > 0.5

func get_gpu_param_pack() -> Dictionary:
	var extra_floats := PackedFloat32Array([edge_bevel_width, hole_depth])
	var extra_ints := PackedInt32Array([edge_type, 1 if use_3d_influence else 0])
	return _build_gpu_param_pack(FeatureType.HOLE, extra_floats, extra_ints)