@tool
class_name HeightmapNode
extends TerrainFeatureNode

const TerrainFeatureNode = "res://addons/terrainy/nodes/terrain_feature_node.gd"
const HeightmapEvaluationContext = preload("res://addons/terrainy/nodes/basic/heightmap_evaluation_context.gd")

## Terrain feature that samples a heightmap texture and maps it into world space.

enum WrapMode {
	CLAMP,
	REPEAT
}

@export var heightmap_texture: Texture2D:
	set(value):
		if heightmap_texture == value:
			return
		if heightmap_texture and heightmap_texture.changed.is_connected(_on_heightmap_changed):
			heightmap_texture.changed.disconnect(_on_heightmap_changed)
		heightmap_texture = value
		if heightmap_texture and not heightmap_texture.changed.is_connected(_on_heightmap_changed):
			heightmap_texture.changed.connect(_on_heightmap_changed)
		_invalidate_heightmap_cache()
		_commit_parameter_change()

@export var height_scale: float = 20.0:
	set(value):
		height_scale = value
		_commit_parameter_change()

@export var height_offset: float = 0.0:
	set(value):
		height_offset = value
		_commit_parameter_change()

@export var wrap_mode: WrapMode = WrapMode.CLAMP:
	set(value):
		wrap_mode = value
		_commit_parameter_change()

@export var invert: bool = false:
	set(value):
		invert = value
		_commit_parameter_change()

# Cached heightmap data
var _cached_height_data: PackedFloat32Array = PackedFloat32Array()
var _cached_height_size: Vector2i = Vector2i.ZERO
var _heightmap_data_dirty: bool = true

func _ready() -> void:
	super._ready()
	if heightmap_texture and not heightmap_texture.changed.is_connected(_on_heightmap_changed):
		heightmap_texture.changed.connect(_on_heightmap_changed)

func _on_heightmap_changed() -> void:
	_invalidate_heightmap_cache()
	_commit_parameter_change()

func _invalidate_heightmap_cache() -> void:
	_cached_height_data = PackedFloat32Array()
	_cached_height_size = Vector2i.ZERO
	_heightmap_data_dirty = true

func prepare_evaluation_context() -> HeightmapEvaluationContext:
	var height_data = _get_heightmap_data()
	return HeightmapEvaluationContext.from_heightmap_feature(
		self,
		height_data,
		_cached_height_size,
		height_scale,
		height_offset,
		int(wrap_mode),
		invert
	)

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as HeightmapEvaluationContext
	if ctx == null:
		return 0.0

	var size = ctx.influence_size
	if size.x <= 0.0 or size.y <= 0.0:
		return 0.0

	var local_pos = ctx.to_local(world_pos)
	var u = (local_pos.x / size.x) + 0.5
	var v = (local_pos.z / size.y) + 0.5

	return ctx.sample_height(Vector2(u, v))

func _get_heightmap_data() -> PackedFloat32Array:
	if not _heightmap_data_dirty and not _cached_height_data.is_empty():
		return _cached_height_data

	_cached_height_data = PackedFloat32Array()
	_cached_height_size = Vector2i.ZERO
	_heightmap_data_dirty = false

	if heightmap_texture == null:
		return _cached_height_data

	var img = heightmap_texture.get_image()
	if img == null:
		return _cached_height_data

	if img.get_format() != Image.FORMAT_RF:
		img.convert(Image.FORMAT_RF)

	var data = img.get_data().to_float32_array()
	if data.is_empty():
		return _cached_height_data

	_cached_height_data = data
	_cached_height_size = Vector2i(img.get_width(), img.get_height())
	return _cached_height_data
