@tool
class_name ShapeNode
extends TerrainFeatureNode

const TerrainFeatureNode = "res://addons/terrainy/nodes/terrain_feature_node.gd"
const ShapeEvaluationContext = preload("res://addons/terrainy/nodes/basic/shape_evaluation_context.gd")
const ShapeMaskResource = preload("res://addons/terrainy/resources/shape_mask_resource.gd")

const DEFAULT_MASK_RESOLUTION := Vector2i(256, 256)

## Custom top-view mask as height stamp.

@export var shape_height: float = 10.0:
	set(value):
		shape_height = value
		_commit_parameter_change()

@export var shape_mask: ShapeMaskResource:
	set(value):
		if shape_mask == value:
			return
		_disconnect_mask_signal()
		shape_mask = value
		_connect_mask_signal()
		_invalidate_mask_cache()
		_commit_parameter_change()

@export var smoothness: float = 0.1:
	set(value):
		smoothness = clamp(value, 0.0, 0.5)
		_commit_parameter_change()

@export var shape_rotation: float = 0.0:
	set(value):
		shape_rotation = value
		_commit_parameter_change()

var _cached_mask_data: PackedFloat32Array = PackedFloat32Array()
var _cached_mask_size: Vector2i = Vector2i.ZERO
var _mask_data_dirty: bool = true

func _ready() -> void:
	super._ready()
	if shape_mask == null:
		shape_mask = ShapeMaskResource.new()
		shape_mask.ensure_initialized(DEFAULT_MASK_RESOLUTION)
	_connect_mask_signal()
	_invalidate_mask_cache()

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

func prepare_evaluation_context() -> ShapeEvaluationContext:
	var mask_data = _get_mask_data()
	return ShapeEvaluationContext.from_shape_feature(
		self,
		shape_height,
		smoothness,
		deg_to_rad(shape_rotation),
		mask_data,
		_cached_mask_size
	)

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as ShapeEvaluationContext
	if ctx == null:
		return 0.0
	var local_pos = ctx.to_local(world_pos)
	var pos_2d = Vector2(local_pos.x, local_pos.z)

	# Apply rotation
	if abs(ctx.rotation_angle) > 0.001:
		pos_2d = ctx.rotate_point_2d(pos_2d)

	var size = ctx.influence_size
	if size.x <= 0.0 or size.y <= 0.0:
		return 0.0

	var half_size = size * 0.5
	var normalized_distance = max(
		abs(pos_2d.x) / max(half_size.x, 0.0001),
		abs(pos_2d.y) / max(half_size.y, 0.0001)
	)
	if normalized_distance >= 1.0:
		return 0.0

	var uv = Vector2(
		(pos_2d.x / size.x) + 0.5,
		(pos_2d.y / size.y) + 0.5
	)
	var mask_value = ctx.sample_mask(uv)
	if mask_value <= 0.0:
		return 0.0

	# Smooth falloff at edges
	var edge_start = 1.0 - ctx.smoothness
	var height_factor = 1.0

	if normalized_distance > edge_start and 1.0 > edge_start:
		var edge_t = (normalized_distance - edge_start) / (1.0 - edge_start)
		height_factor = 1.0 - smoothstep(0.0, 1.0, edge_t)

	return ctx.shape_height * mask_value * height_factor

func get_gpu_param_pack() -> Dictionary:
	var mask_data = _get_mask_data()
	var mask_size = _cached_mask_size
	var extra_floats := PackedFloat32Array([shape_height, smoothness, deg_to_rad(shape_rotation)])
	var data_offset = 19 + extra_floats.size()
	if not mask_data.is_empty():
		extra_floats.append_array(mask_data)
	var extra_ints := PackedInt32Array([
		mask_size.x,
		mask_size.y,
		data_offset,
		mask_data.size()
	])
	return _build_gpu_param_pack(FeatureType.SHAPE, extra_floats, extra_ints)

func _connect_mask_signal() -> void:
	if shape_mask and not shape_mask.changed.is_connected(_on_shape_mask_changed):
		shape_mask.changed.connect(_on_shape_mask_changed)

func _disconnect_mask_signal() -> void:
	if shape_mask and shape_mask.changed.is_connected(_on_shape_mask_changed):
		shape_mask.changed.disconnect(_on_shape_mask_changed)

func _on_shape_mask_changed() -> void:
	_invalidate_mask_cache()
	_commit_parameter_change()

func _invalidate_mask_cache() -> void:
	_cached_mask_data = PackedFloat32Array()
	_cached_mask_size = Vector2i.ZERO
	_mask_data_dirty = true

func _get_mask_data() -> PackedFloat32Array:
	if not _mask_data_dirty and not _cached_mask_data.is_empty():
		return _cached_mask_data

	_cached_mask_data = PackedFloat32Array()
	_cached_mask_size = Vector2i.ZERO
	_mask_data_dirty = false

	if shape_mask == null:
		return _cached_mask_data

	shape_mask.ensure_initialized(shape_mask.resolution)
	var source_image = shape_mask.mask_image
	if source_image == null:
		return _cached_mask_data

	var img = source_image.duplicate()
	if img.get_format() != Image.FORMAT_RF:
		img.convert(Image.FORMAT_RF)

	var data = img.get_data().to_float32_array()
	if data.is_empty():
		return _cached_mask_data

	# Convert from visual grayscale (black=0, white=1) to shape contribution (black=1, white=0).
	for i in data.size():
		data[i] = clamp(1.0 - data[i], 0.0, 1.0)

	_cached_mask_data = data
	_cached_mask_size = Vector2i(img.get_width(), img.get_height())
	return _cached_mask_data
