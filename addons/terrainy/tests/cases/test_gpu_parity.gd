extends "res://addons/terrainy/tests/framework/test_case.gd"

## CPU/GPU parity tests.
##
## These require a real RenderingDevice, which the headless dummy renderer does not provide,
## so they are reported as skipped unless the suite is run with a rendering driver that can
## create one:
##
##     godot --path . --script res://addons/terrainy/tests/run_tests.gd
##
## The CPU implementations are the reference: any divergence means one of the two paths
## deviates from the shared modifier/composition semantics.

const SIZE := Vector2i(64, 64)
const BOUNDS := Rect2(-64.0, -64.0, 128.0, 128.0)
const BASE_HEIGHT := 20.0
const TOLERANCE := 0.01

var _builders: Array = []

func after_all() -> void:
	for builder in _builders:
		builder.cleanup()
	_builders.clear()
	super.after_all()

func _new_builder() -> TerrainHeightmapBuilder:
	var builder := TerrainHeightmapBuilder.new()
	_builders.append(builder)
	return builder

func _make_perlin(position: Vector3 = Vector3.ZERO, noise_seed: int = 99) -> PerlinNoiseNode:
	var feature := PerlinNoiseNode.new()
	feature.name = "Perlin"
	feature.noise_seed = noise_seed
	feature.amplitude = 12.0
	feature.blend_mode = TerrainFeatureNode.BlendMode.ADD
	feature.influence_shape = TerrainFeatureNode.InfluenceShape.CIRCLE
	feature.influence_size = Vector2(80.0, 80.0)
	feature.edge_falloff = 0.4
	feature.position = position
	spawn(feature)
	return feature

func _make_hill(position: Vector3 = Vector3.ZERO) -> HillNode:
	var feature := HillNode.new()
	feature.name = "Hill"
	feature.blend_mode = TerrainFeatureNode.BlendMode.ADD
	feature.influence_shape = TerrainFeatureNode.InfluenceShape.CIRCLE
	feature.influence_size = Vector2(80.0, 80.0)
	feature.edge_falloff = 0.4
	feature.position = position
	spawn(feature)
	return feature

func test_gpu_modifiers_match_the_cpu_reference() -> void:
	if not has_rendering_device():
		t.skip(gpu_skip_reason())
		return
	var settings := {
		"smoothing": 2,
		"smoothing_radius": 3.0,
		"enable_terracing": true,
		"terrace_levels": 6,
		"terrace_smoothness": 0.3,
		"enable_min_clamp": true,
		"min_height": 8.0,
		"enable_max_clamp": true,
		"max_height": 90.0,
	}
	var cpu_pipeline := ModifierPipeline.new()
	var cpu_item := settings.duplicate()
	cpu_item["heightmap"] = make_ramp_image(SIZE, 100.0)
	cpu_item["bounds"] = BOUNDS
	cpu_item["use_gpu"] = false
	var cpu_result: Image = cpu_pipeline.apply_modifiers_batch([cpu_item])[0]

	# The modifier helper is driven directly on purpose: ModifierPipeline falls back to the
	# CPU implementation whenever the GPU does not return an image, so going through the
	# pipeline would let a broken dispatch pass this test unnoticed.
	var gpu_item := settings.duplicate()
	gpu_item["heightmap"] = make_ramp_image(SIZE, 100.0)
	gpu_item["bounds"] = BOUNDS
	var gpu_processor := GpuHeightmapModifier.new()
	var gpu_results: Array = gpu_processor.apply_modifiers_batch([gpu_item])
	t.check(
		gpu_results.size() == 1 and gpu_results[0] != null,
		"the GPU modifier dispatched without falling back to the CPU"
	)
	if gpu_results.size() == 1 and gpu_results[0] != null:
		var difference: Dictionary = t.image_difference(cpu_result, gpu_results[0])
		t.check(
			difference["max"] <= TOLERANCE,
			"GPU modifiers match the CPU reference (max difference %.6f, mean %.6f)" % [
				difference["max"], difference["mean"]
			]
		)
	gpu_processor.cleanup()
	cpu_pipeline.cleanup()

func test_gpu_composition_matches_the_cpu_reference() -> void:
	if not has_rendering_device():
		t.skip(gpu_skip_reason())
		return
	# A hill is not noise-dependent, so both paths must produce the same heightmap.
	var feature := _make_hill(Vector3(5.0, 0.0, -5.0))
	var hole := HoleNode.new()
	hole.name = "Hole"
	hole.influence_shape = TerrainFeatureNode.InfluenceShape.CIRCLE
	hole.influence_size = Vector2(40.0, 40.0)
	hole.position = Vector3(20.0, 0.0, 0.0)
	spawn(hole)

	var features: Array[TerrainFeatureNode] = [feature, hole]
	var contexts := build_contexts(features)
	var cpu_result: Dictionary = _new_builder().compose(
		features, contexts, SIZE, BOUNDS, BASE_HEIGHT, false, false, false, false
	)
	var gpu_builder := _new_builder()
	# The builder falls back to CPU composition when the compositor is unavailable, which
	# would make this comparison pass while never touching the GPU path.
	t.check(gpu_builder._should_use_gpu(true), "the GPU compositor is available for the parity run")
	var gpu_result: Dictionary = gpu_builder.compose(
		features, contexts, SIZE, BOUNDS, BASE_HEIGHT, true, false, false, false
	)
	var difference: Dictionary = t.image_difference(cpu_result["heightmap"], gpu_result["heightmap"])
	t.check(
		difference["max"] <= TOLERANCE,
		"GPU heightmap composition matches the CPU reference (max difference %.6f)" % difference["max"]
	)

func test_gpu_feature_kernels_match_the_cpu_reference() -> void:
	if not has_rendering_device():
		t.skip(gpu_skip_reason())
		return
	# Both runs compose on the GPU; only the feature evaluation differs, which isolates the
	# compute kernels from the GPU blender.
	var feature := _make_hill(Vector3(5.0, 0.0, -5.0))
	var features: Array[TerrainFeatureNode] = [feature]
	var cpu_builder := _new_builder()
	# If the kernels were unavailable the builder would silently evaluate on the CPU and this
	# test would compare the CPU path with itself.
	t.check(cpu_builder._can_evaluate_on_gpu(feature), "the hill is eligible for GPU feature evaluation")
	var cpu_eval: Dictionary = cpu_builder.compose(
		features, build_contexts(features), SIZE, BOUNDS, BASE_HEIGHT, true, false, false, false
	)
	var gpu_builder := _new_builder()
	t.check(gpu_builder._can_evaluate_on_gpu(feature), "the hill is eligible for GPU feature evaluation")
	var gpu_eval: Dictionary = gpu_builder.compose(
		features, build_contexts(features), SIZE, BOUNDS, BASE_HEIGHT, true, false, false, true
	)
	var difference: Dictionary = t.image_difference(cpu_eval["heightmap"], gpu_eval["heightmap"])
	t.check(
		difference["max"] <= TOLERANCE,
		"GPU feature kernels match the CPU reference (max difference %.6f)" % difference["max"]
	)

func test_noise_features_stay_on_the_cpu() -> void:
	if not has_rendering_device():
		t.skip(gpu_skip_reason())
		return
	var feature := _make_perlin()
	var builder := _new_builder()
	builder.use_gpu_feature_evaluation = true
	t.check(
		not builder._can_evaluate_on_gpu(feature),
		"noise features always stay on the CPU for exact parity with the editor preview"
	)
