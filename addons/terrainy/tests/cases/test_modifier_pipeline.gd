extends "res://addons/terrainy/tests/framework/test_case.gd"

## Tests for ModifierPipeline: modifier order, clamping, terracing, smoothing, batching and
## the "nothing to do" fast path. The CPU implementation is also the fallback used when no
## GPU is available, so it must stay correct on its own.

const SIZE := Vector2i(32, 32)
const BOUNDS := Rect2(-64.0, -64.0, 128.0, 128.0)

var _pipelines: Array = []

func after_all() -> void:
	for pipeline in _pipelines:
		pipeline.cleanup()
	_pipelines.clear()
	super.after_all()

func _new_pipeline() -> ModifierPipeline:
	var pipeline := ModifierPipeline.new()
	_pipelines.append(pipeline)
	return pipeline

## Apply modifiers on the CPU path only.
func _apply(image: Image, settings: Dictionary) -> Image:
	var pipeline := _new_pipeline()
	var item := settings.duplicate()
	item["heightmap"] = image
	item["bounds"] = BOUNDS
	item["use_gpu"] = false
	var results := pipeline.apply_modifiers_batch([item])
	t.check_eq(results.size(), 1, "batch returned one result")
	return results[0]

func _spike_image() -> Image:
	var image := make_flat_image(SIZE, 10.0)
	image.set_pixel(SIZE.x / 2, SIZE.y / 2, Color(60.0, 0.0, 0.0, 1.0))
	return image

func test_no_modifiers_returns_the_input_unchanged() -> void:
	var image := make_ramp_image(SIZE, 100.0)
	var pipeline := _new_pipeline()
	t.check(
		not pipeline.has_any_modifiers(0, false, false, false),
		"no modifiers detected"
	)
	var result := _apply(image, {})
	t.check_images_match(result, image, "identity when nothing is enabled", 0.0)

func test_min_clamp_raises_low_values() -> void:
	var result := _apply(make_ramp_image(SIZE, 100.0), {
		"enable_min_clamp": true,
		"min_height": 30.0,
	})
	t.check_almost_eq(t.image_min(result), 30.0, "minimum raised to the clamp", 0.001)
	t.check_almost_eq(t.image_max(result), 100.0, "maximum untouched", 0.001)

func test_max_clamp_lowers_high_values() -> void:
	var result := _apply(make_ramp_image(SIZE, 100.0), {
		"enable_max_clamp": true,
		"max_height": 40.0,
	})
	t.check_almost_eq(t.image_max(result), 40.0, "maximum lowered to the clamp", 0.001)
	t.check_almost_eq(t.image_min(result), 0.0, "minimum untouched", 0.001)

func test_terracing_quantises_values() -> void:
	var result := _apply(make_ramp_image(SIZE, 100.0), {
		"enable_terracing": true,
		"terrace_levels": 5,
		"terrace_smoothness": 0.0,
	})
	var distinct: int = t.image_count_distinct(result, 0.01)
	t.check(distinct <= 6, "hard terracing collapses the ramp into 5 steps (got %d distinct)" % distinct)
	t.check_in_range(t.image_min(result), 0.0, 0.001, "lowest terrace stays at 0")
	t.check_in_range(t.image_max(result), 99.999, 100.001, "highest terrace stays at the input maximum")

func test_terracing_is_skipped_for_flat_zero_heightmaps() -> void:
	var result := _apply(make_flat_image(SIZE, 0.0), {
		"enable_terracing": true,
		"terrace_levels": 5,
		"terrace_smoothness": 0.0,
	})
	t.check_almost_eq(t.image_max(result), 0.0, "terracing a zero heightmap is a no-op", 0.0)
	t.check_almost_eq(t.image_min(result), 0.0, "terracing a zero heightmap is a no-op", 0.0)

func test_smoothing_flattens_local_peaks() -> void:
	var image := _spike_image()
	var peak_before := image.get_pixel(SIZE.x / 2, SIZE.y / 2).r
	# smoothing_radius is given in world units: BOUNDS are 128 units across 32 pixels, so the
	# radius has to be several units wide before it covers neighbouring pixels.
	var result := _apply(image, {"smoothing": 3, "smoothing_radius": 16.0})
	var peak_after := result.get_pixel(SIZE.x / 2, SIZE.y / 2).r
	t.check(peak_after < peak_before, "smoothing reduces an isolated peak (%.3f -> %.3f)" % [peak_before, peak_after])
	t.check(peak_after > 10.0, "smoothing keeps most of the surrounding height")
	t.check_almost_eq(t.image_min(result), 10.0, "flat regions stay flat", 0.001)

func test_batch_processes_every_item_independently() -> void:
	var pipeline := _new_pipeline()
	var raised := make_ramp_image(SIZE, 100.0)
	var lowered := make_ramp_image(SIZE, 100.0)
	var results := pipeline.apply_modifiers_batch([
		{
			"heightmap": raised,
			"bounds": BOUNDS,
			"enable_min_clamp": true,
			"min_height": 50.0,
			"use_gpu": false,
		},
		{
			"heightmap": lowered,
			"bounds": BOUNDS,
			"enable_max_clamp": true,
			"max_height": 5.0,
			"use_gpu": false,
		},
	])
	t.check_eq(results.size(), 2, "batch result count")
	t.check_almost_eq(t.image_min(results[0]), 50.0, "first item uses its own clamp", 0.001)
	t.check_almost_eq(t.image_max(results[1]), 5.0, "second item uses its own clamp", 0.001)
	t.check_almost_eq(raised.get_pixel(0, 0).r, 0.0, "the input image is not modified in place", 0.001)

func test_modifiers_run_in_a_stable_order() -> void:
	var image := make_flat_image(SIZE, 90.0)
	image.set_pixel(SIZE.x / 2, SIZE.y / 2, Color(100.0, 0.0, 0.0, 1.0))
	var result := _apply(image, {
		"smoothing": 1,
		"smoothing_radius": 2.0,
		"enable_terracing": true,
		"terrace_levels": 4,
		"terrace_smoothness": 0.0,
		"enable_min_clamp": true,
		"min_height": 5.0,
		"enable_max_clamp": true,
		"max_height": 95.0,
	})
	t.check_in_range(t.image_min(result), 5.0, 95.0, "clamping is applied after the other modifiers")
	t.check_in_range(t.image_max(result), 5.0, 95.0, "clamping is applied after the other modifiers")

func test_null_heightmap_is_reported_as_null_result() -> void:
	var pipeline := _new_pipeline()
	var results := pipeline.apply_modifiers_batch([{"bounds": BOUNDS, "enable_max_clamp": true}])
	t.check_eq(results.size(), 1, "batch result count")
	t.check(results[0] == null, "items without a heightmap produce null results")
