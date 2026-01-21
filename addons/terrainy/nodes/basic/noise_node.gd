@tool
@abstract
class_name NoiseNode
extends TerrainFeatureNode

const TerrainFeatureNode = "res://addons/terrainy/nodes/terrain_feature_node.gd"

## Abstract base class for noise-based terrain features

@export var amplitude: float = 5.0:
	set(value):
		amplitude = value
		parameters_changed.emit()

@export var noise: FastNoiseLite:
	set(value):
		noise = value
		if noise and not noise.changed.is_connected(_on_noise_changed):
			noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

func _on_noise_changed() -> void:
	parameters_changed.emit()

## Bulk heightmap generation for noise-based nodes (FastNoiseLite)
func generate_heightmap(resolution: Vector2i, terrain_bounds: Rect2) -> Image:
	var start_time = Time.get_ticks_msec()
	var heightmap: Image = _generate_heightmap_bulk(resolution, terrain_bounds)
	if heightmap == null:
		return super.generate_heightmap(resolution, terrain_bounds)

	# Apply modifiers (GPU if available, CPU fallback)
	if _has_any_modifiers():
		var processor = _get_gpu_modifier_processor()
		if processor and processor.is_available():
			var modified = processor.apply_modifiers(
				heightmap,
				int(smoothing),
				smoothing_radius,
				enable_terracing,
				terrace_levels,
				terrace_smoothness,
				enable_min_clamp,
				min_height,
				enable_max_clamp,
				max_height
			)
			if modified:
				heightmap = modified
			else:
				_apply_modifiers_cpu(heightmap, terrain_bounds)
		else:
			_apply_modifiers_cpu(heightmap, terrain_bounds)

	_heightmap_dirty = false

	var elapsed = Time.get_ticks_msec() - start_time
	if Engine.is_editor_hint():
		print("[%s] Generated %dx%d heightmap (bulk noise) in %d ms" % [name, resolution.x, resolution.y, elapsed])

	return heightmap

func _generate_heightmap_bulk(resolution: Vector2i, terrain_bounds: Rect2) -> Image:
	if not noise:
		return null

	var method_info = _get_method_info(noise, "get_image")
	if method_info.is_empty():
		return null

	var step_x := terrain_bounds.size.x / float(resolution.x - 1)
	var step_y := terrain_bounds.size.y / float(resolution.y - 1)
	var origin_x := terrain_bounds.position.x
	var origin_z := terrain_bounds.position.y

	var call_args: Array = _build_get_image_args(method_info, resolution, origin_x, origin_z, step_x, step_y)
	if call_args.is_empty():
		return null

	var noise_image: Image = noise.callv("get_image", call_args)
	if not (noise_image is Image):
		return null

	if noise_image.get_width() != resolution.x or noise_image.get_height() != resolution.y:
		noise_image.resize(resolution.x, resolution.y, Image.INTERPOLATE_BILINEAR)

	if noise_image.get_format() != Image.FORMAT_RF:
		noise_image.convert(Image.FORMAT_RF)

	var noise_data: PackedFloat32Array = noise_image.get_data().to_float32_array()
	var total_pixels: int = resolution.x * resolution.y
	if noise_data.size() != total_pixels:
		return null

	# Detect whether the noise image is 0..1 or -1..1 by comparing a sample
	var sample_value: float = noise_data[0]
	var expected: float = noise.get_noise_2d(origin_x, origin_z)
	var sample_as_signed: float = sample_value * 2.0 - 1.0
	var use_zero_one: bool = abs(sample_as_signed - expected) < abs(sample_value - expected)

	var height_data := PackedFloat32Array()
	height_data.resize(total_pixels)
	for i in total_pixels:
		var v: float = noise_data[i]
		var n: float = (v * 2.0 - 1.0) if use_zero_one else v
		height_data[i] = (n + 1.0) * 0.5 * amplitude

	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, height_data.to_byte_array())

func _get_method_info(obj: Object, method_name: String) -> Dictionary:
	var method_list = obj.get_method_list()
	for entry in method_list:
		if entry.has("name") and entry["name"] == method_name:
			return entry
	return {}

func _build_get_image_args(method_info: Dictionary, resolution: Vector2i, origin_x: float, origin_z: float, step_x: float, step_z: float) -> Array:
	if not method_info.has("args"):
		return []
	var args = method_info["args"]
	var args_count: int = args.size()
	var default_count := 0
	if method_info.has("default_args"):
		default_count = method_info["default_args"].size()
	var required_args := args_count - default_count

	# Prefer passing offset + scale when allowed
	if args_count >= 4 and required_args <= 4:
		var arg2_type = args[2].get("type", TYPE_NIL)
		var arg3_type = args[3].get("type", TYPE_NIL)
		if arg2_type == TYPE_VECTOR2 and arg3_type == TYPE_VECTOR2:
			return [resolution.x, resolution.y, Vector2(origin_x, origin_z), Vector2(step_x, step_z)]

	# Handle bool third argument if required
	if args_count >= 3 and required_args <= 3:
		var arg2_type = args[2].get("type", TYPE_NIL)
		if arg2_type == TYPE_BOOL:
			return [resolution.x, resolution.y, false]

	if args_count >= 2 and required_args <= 2:
		return [resolution.x, resolution.y]
	return []
