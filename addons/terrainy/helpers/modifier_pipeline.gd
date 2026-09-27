class_name ModifierPipeline
extends RefCounted

## Applies modifiers (smoothing, terracing, clamping) to heightmap images.
## Can use GPU compute or CPU fallback.
## Both paths apply modifiers in the same order (smoothing -> terracing -> clamping)
## and share the same normalization constants.

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
	var item := {
		"heightmap": heightmap,
		"bounds": terrain_bounds,
		"context": context,
		"smoothing": smoothing,
		"smoothing_radius": smoothing_radius,
		"enable_terracing": enable_terracing,
		"terrace_levels": terrace_levels,
		"terrace_smoothness": terrace_smoothness,
		"enable_min_clamp": enable_min_clamp,
		"min_height": min_height,
		"enable_max_clamp": enable_max_clamp,
		"max_height": max_height,
		"use_gpu": use_gpu
	}
	var results := apply_modifiers_batch([item])
	if results.size() > 0 and results[0] != null:
		return results[0]
	return heightmap

## Apply modifiers to several heightmaps. Every item is a Dictionary as accepted by
## apply_modifiers() ("heightmap", "bounds" and the modifier settings). The GPU path
## issues a single compute list submit for all items; items that cannot run on the GPU
## (or return nothing) fall back to the CPU implementation.
## Returns an Array of Images parallel to `items`; entries are null only when the item
## had no heightmap at all.
func apply_modifiers_batch(items: Array) -> Array:
	var results: Array = []
	results.resize(items.size())
	if items.is_empty():
		return results

	var gpu_indices: Array = []
	var gpu_items: Array = []
	var gpu_enabled: bool = true
	for i in items.size():
		var item: Dictionary = items[i]
		var heightmap: Image = item.get("heightmap")
		if heightmap == null:
			continue
		if not has_any_modifiers(
			item.get("smoothing", 0),
			item.get("enable_terracing", false),
			item.get("enable_min_clamp", false),
			item.get("enable_max_clamp", false)
		):
			results[i] = heightmap
			continue
		if not item.get("use_gpu", true):
			gpu_enabled = false
		gpu_indices.append(i)
		gpu_items.append(item)

	if not gpu_items.is_empty() and gpu_enabled and _gpu_processor and _gpu_processor.is_available():
		var gpu_results := _gpu_processor.apply_modifiers_batch(gpu_items)
		for j in gpu_indices.size():
			var index: int = gpu_indices[j]
			if j < gpu_results.size() and gpu_results[j] != null:
				results[index] = gpu_results[j]

	# CPU fallback for anything the GPU did not produce
	for i in items.size():
		if results[i] == null and items[i].get("heightmap") != null:
			results[i] = _apply_modifiers_cpu(items[i])

	return results

func _apply_modifiers_cpu(item: Dictionary) -> Image:
	var heightmap: Image = item.get("heightmap")
	if heightmap == null:
		return null

	var resolution := Vector2i(heightmap.get_width(), heightmap.get_height())
	if resolution.x <= 0 or resolution.y <= 0:
		return heightmap

	var height_data := heightmap.get_data().to_float32_array()
	var enable_terracing: bool = item.get("enable_terracing", false)
	var enable_min_clamp: bool = item.get("enable_min_clamp", false)
	var enable_max_clamp: bool = item.get("enable_max_clamp", false)

	# Terracing normalizes against the maximum |height| of the *input* heightmap, which
	# is the same value the GPU path uploads as `max_abs_height`. Compute it before
	# smoothing so both paths agree.
	var max_abs := 0.0
	if enable_terracing:
		for h in height_data:
			max_abs = max(max_abs, abs(h))
		if max_abs < 0.001:
			enable_terracing = false

	# Modifier order matches the compute shader: smoothing -> terracing -> clamping.
	var smoothing: int = item.get("smoothing", 0)
	if smoothing != 0:
		height_data = _apply_smoothing_pass(
			height_data, resolution, item.get("bounds", Rect2()), item.get("context"),
			smoothing, item.get("smoothing_radius", 2.0)
		)

	if enable_terracing or enable_min_clamp or enable_max_clamp:
		var terrace_levels: int = item.get("terrace_levels", 5)
		var terrace_smoothness: float = item.get("terrace_smoothness", 0.2)
		var min_height: float = item.get("min_height", 0.0)
		var max_height: float = item.get("max_height", 100.0)
		for i in height_data.size():
			var h := height_data[i]
			if enable_terracing:
				h = _apply_terracing_single(h, terrace_levels, terrace_smoothness, max_abs)
			if enable_min_clamp:
				h = max(h, min_height)
			if enable_max_clamp:
				h = min(h, max_height)
			height_data[i] = h

	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, height_data.to_byte_array())

func _apply_terracing_single(height: float, levels: int, smoothness: float, max_abs: float) -> float:
	if levels <= 1 or max_abs < 0.001:
		return height

	var normalized = height / max_abs
	var level = floor(normalized * levels)
	var level_h = level / float(levels)

	if smoothness > 0.001:
		var next_level_h = (level + 1.0) / float(levels)
		var t = (normalized * levels) - level
		t = smoothstep(0.0, 1.0, clampf(t / maxf(smoothness, 0.001), 0.0, 1.0))
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

	# Precompute loop-invariant normalization factor
	var inv_step_min: float = 1.0 / min(step_x, step_y)
	var inv_norm: float = 1.0 / (sample_radius * inv_step_min * 1.5)

	for y in height:
		for x in width:
			var idx := y * width + x
			var center_h := data[idx]
			var total_h := center_h
			var total_w := 1.0

			for s in sample_count:
				var angle := (s / float(sample_count)) * TAU
				var offset_x := (cos(angle) * sample_radius) / step_x
				var offset_y := (sin(angle) * sample_radius) / step_y
				var sx := clampi(x + int(round(offset_x)), 0, width - 1)
				var sy := clampi(y + int(round(offset_y)), 0, height - 1)
				var sidx := sy * width + sx
				var sample_h := data[sidx]
				# Distance uses the unrounded pixel offsets, matching the compute shader.
				var dist := sqrt(offset_x * offset_x + offset_y * offset_y)
				var w: float = max(0.0, 1.0 - dist * inv_norm)
				total_h += sample_h * w
				total_w += w

			result[idx] = total_h / total_w

	return result
