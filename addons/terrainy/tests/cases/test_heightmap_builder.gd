extends "res://addons/terrainy/tests/framework/test_case.gd"

## End-to-end tests for TerrainHeightmapBuilder: base-height fill, feature blending,
## caching, multi-threaded generation, hole separation, mask textures and parity with the
## (unmodified) reference results.

const RESOLUTION := Vector2i(32, 32)
const BOUNDS := Rect2(-64.0, -64.0, 128.0, 128.0)
const BASE_HEIGHT := 50.0
## Pixel index of the terrain center for RESOLUTION.
const CENTER := 16

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

func _make_perlin(
	position: Vector3 = Vector3.ZERO,
	noise_seed: int = 4242,
	amplitude: float = 10.0
) -> PerlinNoiseNode:
	var feature := PerlinNoiseNode.new()
	feature.name = "Perlin"
	feature.noise_seed = noise_seed
	feature.amplitude = amplitude
	feature.blend_mode = TerrainFeatureNode.BlendMode.ADD
	feature.influence_shape = TerrainFeatureNode.InfluenceShape.RECTANGLE
	feature.influence_size = Vector2(64.0, 64.0)
	feature.edge_falloff = 0.25
	feature.position = position
	spawn(feature)
	return feature

func _make_hole(position: Vector3 = Vector3.ZERO) -> HoleNode:
	var feature := HoleNode.new()
	feature.name = "Hole"
	feature.influence_shape = TerrainFeatureNode.InfluenceShape.RECTANGLE
	feature.influence_size = Vector2(64.0, 64.0)
	feature.edge_falloff = 0.25
	feature.position = position
	spawn(feature)
	return feature

## Compose with the CPU path only (headless deterministic runs).
func _compose(
	builder: TerrainHeightmapBuilder,
	features: Array,
	resolution: Vector2i = RESOLUTION,
	use_multithreading: bool = false
) -> Dictionary:
	var typed: Array[TerrainFeatureNode] = []
	for feature in features:
		typed.append(feature)
	return builder.compose(
		typed,
		build_contexts(typed),
		resolution,
		BOUNDS,
		BASE_HEIGHT,
		false,
		use_multithreading
	)

func test_empty_feature_list_fills_base_height() -> void:
	var result := _compose(_new_builder(), [])
	var heightmap: Image = result["heightmap"]
	t.check_eq(heightmap.get_size(), RESOLUTION, "heightmap resolution")
	t.check_almost_eq(t.image_min(heightmap), BASE_HEIGHT, "flat terrain minimum", 0.001)
	t.check_almost_eq(t.image_max(heightmap), BASE_HEIGHT, "flat terrain maximum", 0.001)
	t.check_almost_eq(t.image_max(result["hole_mask"]), 0.0, "no holes without hole features", 0.0)

func test_feature_only_raises_terrain_inside_its_influence() -> void:
	var feature := _make_perlin()
	var heightmap: Image = _compose(_new_builder(), [feature])["heightmap"]
	t.check_almost_eq(
		heightmap.get_pixel(0, 0).r, BASE_HEIGHT,
		"pixels outside the influence keep the base height", 0.001
	)
	t.check(
		heightmap.get_pixel(CENTER, CENTER).r > BASE_HEIGHT + 0.001,
		"the terrain center is raised above the base height"
	)
	t.check(
		t.image_max(heightmap) <= BASE_HEIGHT + 10.001,
		"additive blending stays within the feature amplitude"
	)

func test_heightmap_cache_is_reused_and_deterministic() -> void:
	var feature := _make_perlin()
	var builder := _new_builder()
	var first: Image = _compose(builder, [feature])["heightmap"]
	t.check(not feature.is_dirty(), "feature heightmap is marked clean after compose")

	var second: Image = _compose(builder, [feature])["heightmap"]
	t.check_images_match(second, first, "recompose with a cached heightmap", 0.0)

	feature.mark_dirty()
	var third: Image = _compose(builder, [feature])["heightmap"]
	t.check_images_match(third, first, "recompose after mark_dirty is deterministic", 0.0)

func test_multithreaded_generation_matches_single_threaded() -> void:
	var single_feature := _make_perlin()
	var multi_feature := _make_perlin()
	var single: Image = _compose(_new_builder(), [single_feature], RESOLUTION, false)["heightmap"]
	var multi: Image = _compose(_new_builder(), [multi_feature], RESOLUTION, true)["heightmap"]
	t.check_images_match(multi, single, "multithreaded compose equals single threaded compose", 0.0001)

func test_hole_features_do_not_change_heights() -> void:
	var perlin := _make_perlin()
	var heightmap_without_hole: Image = _compose(_new_builder(), [perlin])["heightmap"]

	var with_hole := _compose(_new_builder(), [perlin, _make_hole()])
	t.check_images_match(
		with_hole["heightmap"], heightmap_without_hole,
		"holes are excluded from height blending", 0.0001
	)
	t.check(
		with_hole["hole_mask"].get_pixel(CENTER, CENTER).r > 0.5,
		"the hole mask marks the hole center"
	)
	t.check_almost_eq(
		with_hole["hole_mask"].get_pixel(0, 0).r, 0.0,
		"the hole mask stays clear outside the hole", 0.0
	)

func test_hole_only_terrain_keeps_base_height() -> void:
	var result := _compose(_new_builder(), [_make_hole()])
	t.check_almost_eq(t.image_min(result["heightmap"]), BASE_HEIGHT, "hole-only terrain minimum", 0.001)
	t.check_almost_eq(t.image_max(result["heightmap"]), BASE_HEIGHT, "hole-only terrain maximum", 0.001)
	t.check(t.image_max(result["hole_mask"]) > 0.5, "hole-only terrain still reports holes")

func test_mask_texture_scales_feature_influence() -> void:
	var black := _make_perlin()
	black.mask_texture = ImageTexture.create_from_image(make_grey_texture_image(Vector2i(8, 8), 0.0))
	var masked_out: Image = _compose(_new_builder(), [black])["heightmap"]
	t.check_almost_eq(
		t.image_max(masked_out), BASE_HEIGHT,
		"a black mask removes the feature influence", 0.001
	)

	var white := _make_perlin()
	white.mask_texture = ImageTexture.create_from_image(make_grey_texture_image(Vector2i(8, 8), 1.0))
	var masked_in: Image = _compose(_new_builder(), [white])["heightmap"]
	t.check(t.image_max(masked_in) > BASE_HEIGHT, "a white mask keeps the feature influence")

	var inverted := _make_perlin()
	inverted.mask_texture = ImageTexture.create_from_image(make_grey_texture_image(Vector2i(8, 8), 0.0))
	inverted.mask_invert = true
	var inverted_map: Image = _compose(_new_builder(), [inverted])["heightmap"]
	t.check(t.image_max(inverted_map) > BASE_HEIGHT, "an inverted black mask keeps the feature influence")

func test_clearing_caches_keeps_composition_stable() -> void:
	var feature := _make_perlin()
	var builder := _new_builder()
	var first: Image = _compose(builder, [feature])["heightmap"]

	builder.clear_influence_cache()
	var after_influence_clear: Image = _compose(builder, [feature])["heightmap"]
	t.check_images_match(
		after_influence_clear, first,
		"clear_influence_cache does not change the composed result", 0.0
	)

	builder.clear_all_caches()
	var after_full_clear: Image = _compose(builder, [feature])["heightmap"]
	t.check_images_match(
		after_full_clear, first,
		"clear_all_caches does not change the composed result", 0.0
	)

func test_resolution_change_regenerates_at_the_new_size() -> void:
	var feature := _make_perlin()
	var builder := _new_builder()
	var first: Image = _compose(builder, [feature], RESOLUTION)["heightmap"]
	var second: Image = _compose(builder, [feature], RESOLUTION * 2)["heightmap"]
	t.check_eq(first.get_size(), RESOLUTION, "first compose resolution")
	t.check_eq(second.get_size(), RESOLUTION * 2, "second compose resolution")
	t.check(
		second.get_pixel(RESOLUTION.x, RESOLUTION.y).r > BASE_HEIGHT + 0.001,
		"the feature is regenerated for the new resolution instead of being skipped"
	)

func test_bounds_change_regenerates_feature_heightmaps() -> void:
	var feature := _make_perlin()
	var builder := _new_builder()
	var typed: Array[TerrainFeatureNode] = [feature]
	var contexts := build_contexts(typed)
	var first: Image = builder.compose(typed, contexts, RESOLUTION, BOUNDS, BASE_HEIGHT, false, false)["heightmap"]
	var shifted := Rect2(BOUNDS.position + Vector2(8.0, 4.0), BOUNDS.size)
	var second: Image = builder.compose(typed, contexts, RESOLUTION, shifted, BASE_HEIGHT, false, false)["heightmap"]
	t.check(
		not is_equal_approx(first.get_pixel(CENTER, CENTER).r, second.get_pixel(CENTER, CENTER).r),
		"moving the terrain bounds regenerates the feature heightmaps for the new grid"
	)
