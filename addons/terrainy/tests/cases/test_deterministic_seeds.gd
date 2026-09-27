extends "res://addons/terrainy/tests/framework/test_case.gd"

## Determinism (finding C9): every feature must derive its noise from `noise_seed` instead of
## calling randi(), so bakes and reloads reproduce the same terrain.

const SIZE := Vector2i(24, 24)
const BOUNDS := Rect2(-64.0, -64.0, 128.0, 128.0)

func _feature_classes() -> Array:
	return [
		PerlinNoiseNode,
		VoronoiNode,
		MountainNode,
		IslandNode,
		CanyonNode,
		DuneSeaNode,
		MountainRangeNode,
	]

func _label(feature_class: Script) -> String:
	return feature_class.resource_path.get_file().get_basename()

func _spawn_feature(feature_class: Script, seed_value: int = -1) -> TerrainFeatureNode:
	var feature: TerrainFeatureNode = feature_class.new()
	feature.name = _label(feature_class)
	if seed_value >= 0:
		feature.noise_seed = seed_value
	return spawn(feature) as TerrainFeatureNode

func _generate(feature: TerrainFeatureNode) -> Image:
	return feature.generate_heightmap_with_context_raw(SIZE, BOUNDS, feature.prepare_evaluation_context())

func test_equal_seeds_produce_identical_terrain() -> void:
	for feature_class in _feature_classes():
		var first := _spawn_feature(feature_class, 4242)
		var second := _spawn_feature(feature_class, 4242)
		t.check_images_match(
			_generate(second), _generate(first),
			"%s is deterministic for a fixed noise_seed" % _label(feature_class)  # C9
		)

func test_default_seeds_are_stable_between_instances() -> void:
	for feature_class in _feature_classes():
		var first := _spawn_feature(feature_class)
		var second := _spawn_feature(feature_class)
		t.check_eq(first.noise_seed, 0, "%s starts with the default seed" % _label(feature_class))
		t.check_images_match(
			_generate(second), _generate(first),
			"%s does not use randi() for its default noise" % _label(feature_class)  # C9
		)

func test_different_seeds_produce_different_terrain() -> void:
	for feature_class in _feature_classes():
		var first := _spawn_feature(feature_class, 111)
		var second := _spawn_feature(feature_class, 222)
		var difference = t.image_difference(_generate(first), _generate(second))
		t.check(
			difference["max"] > 0.001,
			"%s reacts to a noise_seed change (max difference %.6f)" % [
				_label(feature_class), difference["max"]
			]  # C9
		)

func test_seed_setter_propagates_to_the_noise_instance() -> void:
	var perlin := _spawn_feature(PerlinNoiseNode, 7)
	t.check(perlin.noise != null, "the feature created its noise instance")
	if perlin.noise != null:
		t.check_eq(perlin.noise.seed, 7, "the seed is applied when the noise is created")

	var before := _generate(perlin)
	perlin.noise_seed = 20250101
	t.check_eq(perlin.noise.seed, 20250101, "assigning noise_seed updates the noise instance")
	var difference = t.image_difference(before, _generate(perlin))
	t.check(difference["max"] > 0.001, "the new seed changes the generated terrain")

func test_mountain_range_derives_both_noise_seeds() -> void:
	var range_node := _spawn_feature(MountainRangeNode, 1234)
	t.check(range_node.peak_noise != null, "the peak noise exists")
	t.check(range_node.detail_noise != null, "the detail noise exists")
	if range_node.peak_noise != null:
		t.check_eq(range_node.peak_noise.seed, 1234, "peak noise uses noise_seed")
	if range_node.detail_noise != null:
		t.check_eq(range_node.detail_noise.seed, 2234, "detail noise uses a derived seed")

func test_dune_sea_derives_the_detail_seed() -> void:
	var dunes := _spawn_feature(DuneSeaNode, 100)
	t.check(dunes.noise != null, "the dune noise exists")
	t.check(dunes.detail_noise != null, "the detail noise exists")
	if dunes.noise != null:
		t.check_eq(dunes.noise.seed, 100, "the dune noise uses noise_seed")
	if dunes.detail_noise != null:
		t.check_eq(dunes.detail_noise.seed, 600, "the detail noise uses a derived seed")
