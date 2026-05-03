class_name ModifierPipeline
extends RefCounted

## Applies modifiers (smoothing, terracing, clamping) to heightmap images.
## Can use GPU compute or CPU fallback.

const GpuHeightmapModifier = preload("res://addons/terrainy/helpers/gpu_heightmap_modifier.gd")

var _gpu_processor: GpuHeightmapModifier = null

func _init() -> void:
	_gpu_processor = GpuHeightmapModifier.new()

func cleanup() -> void:
	if _gpu_processor and _gpu_processor.is_available():
		_gpu_processor.cleanup()
		_gpu_processor = null

func has_any_modifiers(
	smoothing: int,
	enable_terracing: bool,
	enable_min_clamp: bool,
	enable_max_clamp: bool
) -> bool:
	return smoothing != 0 or enable_terracing or enable_min_clamp or enable_max_clamp

func apply_modifiers(
	heightmap: Image,
	terrain_bounds: Rect2,
	context = null,
	smoothing: int = 0,
	smoothing_radius: float = 2.0,
	enable_terracing: bool = false,
	terrace_levels: int = 5,
	terrace_smoothness: float = 0.2,
	enable_min_clamp: bool = false,
	min_height: float = 0.0,
	enable_max_clamp: bool = false,
	max_height: float = 100.0,
	use_gpu: bool = true
) -> Image:
	if not has_any_modifiers(smoothing, enable_terracing, enable_min_clamp, enable_max_clamp):
		return heightmap

	# Try GPU first
	if use_gpu and _gpu_processor and _gpu_processor.is_available():
		var modified = _gpu_processor.apply_modifiers(
			heightmap, smoothing, smoothing_radius,
			enable_terracing, terrace_levels, terrace_smoothness,
			enable_min_clamp, min_height, enable_max_clamp, max_height
		)
		if modified:
			return modified

	# CPU fallback
	return _apply_modifiers_cpu(
		heightmap, terrain_bounds, context,
		smoothing, smoothing_radius,
		enable_terracing, terrace_levels, terrace_smoothness,
		enable_min_clamp, min_height, enable_max_clamp, max_height
	)

func _apply_modifiers_cpu(
	heightmap: Image,
	terrain_bounds: Rect2,
	context,
	smoothing: int,
	smoothing_radius: float,
	enable_terracing: bool,
	terrace_levels: int,
	terrace_smoothness: float,
	enable_min_clamp: bool,
	min_height: float,
	enable_max_clamp: bool,
	max_height: float
) -> Image:
	var resolution := Vector2i(heightmap.get_width(), heightmap.get_height())
	var total_pixels := resolution.x * resolution.y
	var height_data := heightmap.get_data().to_float32_array()

	# Compute actual max absolute height for terracing normalization
	var max_abs := 0.0
	if enable_terracing:
		for h in height_data:
			max_abs = max(max_abs, abs(h))
		if max_abs < 0.001:
			enable_terracing = false

	for i in total_pixels:
		var h := height_data[i]

		# Apply terracing
		if enable_terracing:
			h = _apply_terracing_single(h, terrace_levels, terrace_smoothness, max_abs)

		# Apply clamping
		if enable_min_clamp:
			h = max(h, min_height)
		if enable_max_clamp:
			h = min(h, max_height)

		height_data[i] = h

	# Smoothing is done as a separate 2D pass (cannot be single-pass)
	if smoothing != 0:
		height_data = _apply_smoothing_pass(
			height_data, resolution, terrain_bounds, context,
			smoothing, smoothing_radius
		)

	var result := Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, height_data.to_byte_array())
	return result

func _apply_terracing_single(height: float, levels: int, smoothness: float, max_abs: float) -> float:
	if levels <= 1 or max_abs < 0.001:
		return height

	var normalized = height / max_abs
	var level = floor(normalized * levels)
	var level_h = level / float(levels)

	if smoothness > 0.0:
		var next_level_h = (level + 1.0) / float(levels)
		var t = (normalized * levels) - level
		t = smoothstep(0.0, 1.0, t / smoothness)
		level_h = lerp(level_h, next_level_h, t)

	return level_h * max_abs

func _apply_smoothing_pass(
	data: PackedFloat32Array,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	context,
	smoothing: int,
	radius: float
) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(data.size())

	var sample_count: int
	var sample_radius: float
	match smoothing:
		1: # LIGHT
			sample_count = 4
			sample_radius = radius * 0.5
		2: # MEDIUM
			sample_count = 8
			sample_radius = radius
		3: # HEAVY
			sample_count = 12
			sample_radius = radius * 1.5
		_:
			return data

	var width := resolution.x
	var height := resolution.y
	var step_x := terrain_bounds.size.x / float(width - 1)
	var step_y := terrain_bounds.size.y / float(height - 1)

	for y in height:
		for x in width:
			var idx := y * width + x
			var center_h := data[idx]
			var total_h := center_h
			var total_w := 1.0

			for s in sample_count:
				var angle := (s / float(sample_count)) * TAU
				var ox := int(round(cos(angle) * sample_radius / step_x))
				var oy := int(round(sin(angle) * sample_radius / step_y))
				var sx := clampi(x + ox, 0, width - 1)
				var sy := clampi(y + oy, 0, height - 1)
				var sidx := sy * width + sx
				var sample_h := data[sidx]
				var dist := sqrt(float(ox * ox) + float(oy * oy))
				var w: float = 1.0 - (dist / (sample_radius / min(step_x, step_y) * 1.5))
				w = max(0.0, w)
				total_h += sample_h * w
				total_w += w

			result[idx] = total_h / total_w

	return result
