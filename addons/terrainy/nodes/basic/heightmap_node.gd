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
		_ensure_texture_connection()
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
	_ensure_texture_connection()

func _ensure_texture_connection() -> void:
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
		push_warning("[%s] No heightmap texture assigned" % name)
		return _cached_height_data

	var img = heightmap_texture.get_image()
	if img == null:
		if heightmap_texture is NoiseTexture2D:
			var noise = heightmap_texture.noise
			if noise:
				img = noise.get_image(heightmap_texture.width, heightmap_texture.height)
		
		if img == null and (heightmap_texture is CompressedTexture2D or heightmap_texture is ImageTexture):
			var texture_path = heightmap_texture.resource_path
			if not texture_path.is_empty():
				var loaded_image = Image.load_from_file(texture_path)
				if loaded_image != null:
					img = loaded_image
					if not Engine.is_editor_hint():
						print("[%s] Loaded heightmap image from file: %s" % [name, texture_path])
		
		if img == null:
			push_error("[%s] Failed to get heightmap image data - texture may not be loaded yet (path: %s)" % [name, heightmap_texture.resource_path])
			return _cached_height_data

	if img.get_format() != Image.FORMAT_RF:
		img.convert(Image.FORMAT_RF)

	var data = img.get_data().to_float32_array()
	if data.is_empty():
		push_warning("[%s] Heightmap image has no data (size: %dx%d)" % [name, img.get_width(), img.get_height()])
		return _cached_height_data

	_cached_height_data = data
	_cached_height_size = Vector2i(img.get_width(), img.get_height())
	print("[%s] Cached heightmap data: %dx%d (%d values)" % [name, _cached_height_size.x, _cached_height_size.y, _cached_height_data.size()])
	return _cached_height_data

func get_gpu_param_pack() -> Dictionary:
	var height_data = _get_heightmap_data()
	var size = _cached_height_size
	var extra_floats := PackedFloat32Array([height_scale, height_offset])
	var data_offset = 19 + extra_floats.size()
	if not height_data.is_empty():
		extra_floats.append_array(height_data)
	else:
		push_warning("[%s] GPU param pack has no heightmap data - terrain may be flat at runtime" % name)
	var extra_ints := PackedInt32Array([
		int(wrap_mode),
		1 if invert else 0,
		size.x,
		size.y,
		data_offset,
		height_data.size()
	])
	return _build_gpu_param_pack(FeatureType.HEIGHTMAP, extra_floats, extra_ints)
