extends "res://addons/terrainy/tests/framework/test_case.gd"

## Tests for the public query APIs added for terrain sampling (finding C3/C10b):
## _sample_image_bilinear, get_height_at_world_position and is_hole_at_world_position.

const BOUNDS := Rect2(-64.0, -64.0, 128.0, 128.0)

var _composer: TerrainComposer = null

func before_all() -> void:
	_composer = TerrainComposer.new()
	_composer.name = "QueryTerrain"
	_composer.auto_update = false  # keep the fixture static: no automatic rebuilds
	# Chunk meshes are built synchronously: a worker thread would still be mid-flight
	# when the fixture is freed at the end of the first frame (headless teardown then
	# stalls for the _exit_tree timeout and reports a leaked RenderingServer RID).
	_composer.use_multithreading = false
	spawn(_composer)

func test_bilinear_sampling_of_a_ramp() -> void:
	var ramp := make_ramp_image(Vector2i(32, 32), 100.0)
	t.check_almost_eq(_composer._sample_image_bilinear(ramp, 0.0, 0.0), 0.0, "corner 0,0")
	t.check_almost_eq(_composer._sample_image_bilinear(ramp, 1.0, 1.0), 100.0, "corner 1,1")
	t.check_almost_eq(_composer._sample_image_bilinear(ramp, 0.5, 0.0), 25.0, "mid X, top edge")
	t.check_almost_eq(_composer._sample_image_bilinear(ramp, 0.0, 0.5), 25.0, "left edge, mid Z")
	t.check_almost_eq(_composer._sample_image_bilinear(ramp, 0.5, 0.5), 50.0, "center")

func test_bilinear_sampling_clamps_outside_the_image() -> void:
	var ramp := make_ramp_image(Vector2i(32, 32), 100.0)
	t.check_almost_eq(_composer._sample_image_bilinear(ramp, -1.0, -4.0), 0.0, "u/v below 0 clamp to 0")
	t.check_almost_eq(_composer._sample_image_bilinear(ramp, 2.0, 3.0), 100.0, "u/v above 1 clamp to 1")

func test_height_query_before_a_build_returns_the_fallback() -> void:
	_composer.position = Vector3.ZERO
	_composer.base_height = 3.0
	_composer._final_heightmap = null
	t.check_eq(_composer._final_heightmap, null, "no composed heightmap before a rebuild")
	t.check_almost_eq(
		_composer.get_height_at_world_position(Vector3.ZERO), 3.0,
		"an unbuilt terrain reports global_position.y + base_height"
	)

func test_height_query_samples_the_composed_heightmap() -> void:
	_composer.position = Vector3.ZERO
	_composer.base_height = 3.0
	_composer._final_heightmap = make_flat_image(Vector2i(16, 16), 7.0)
	_composer._terrain_bounds = BOUNDS
	t.check_almost_eq(
		_composer.get_height_at_world_position(Vector3(0.0, 0.0, 0.0)), 7.0,
		"inside the bounds the composed height is returned"
	)
	t.check_almost_eq(
		_composer.get_height_at_world_position(Vector3(-64.0, 0.0, -64.0)), 7.0,
		"the min corner is inside the bounds"
	)
	t.check_almost_eq(
		_composer.get_height_at_world_position(Vector3(64.0, 0.0, 64.0)), 7.0,
		"the max corner is inside the bounds"
	)
	t.check_almost_eq(
		_composer.get_height_at_world_position(Vector3(-64.1, 0.0, 0.0)), 3.0,
		"outside the bounds the base height is used"
	)
	t.check_almost_eq(
		_composer.get_height_at_world_position(Vector3(0.0, 0.0, 64.1)), 3.0,
		"outside the bounds on Z the base height is used"
	)

func test_height_query_adds_the_composer_offset() -> void:
	_composer.position = Vector3(0.0, 12.5, 0.0)
	_composer._final_heightmap = make_flat_image(Vector2i(16, 16), 7.0)
	_composer._terrain_bounds = BOUNDS
	t.check_almost_eq(
		_composer.get_height_at_world_position(Vector3.ZERO), 19.5,
		"the sampled height is expressed in world space"
	)

func test_height_query_uses_the_uv_mapping_of_the_bounds() -> void:
	_composer.position = Vector3.ZERO
	_composer._final_heightmap = make_ramp_image(Vector2i(32, 32), 100.0)
	_composer._terrain_bounds = BOUNDS
	t.check_almost_eq(
		_composer.get_height_at_world_position(Vector3(-64.0, 0.0, -64.0)), 0.0,
		"the min corner maps to pixel (0, 0)"
	)
	t.check_almost_eq(
		_composer.get_height_at_world_position(Vector3(64.0, 0.0, 64.0)), 100.0,
		"the max corner maps to the last pixel"
	)
	t.check_almost_eq(
		_composer.get_height_at_world_position(Vector3(-64.0, 0.0, 64.0)), 50.0,
		"Z is mapped to V"
	)

func test_hole_query_without_a_mask() -> void:
	_composer._final_hole_mask = null
	_composer._terrain_bounds = BOUNDS
	t.check(not _composer.is_hole_at_world_position(Vector3.ZERO), "no mask means no holes")

func test_hole_query_interpolates_the_mask() -> void:
	_composer._final_heightmap = make_flat_image(Vector2i(16, 16), 7.0)
	_composer._terrain_bounds = BOUNDS
	var mask := Image.create(4, 4, false, Image.FORMAT_RF)
	mask.fill(Color(0.0, 0.0, 0.0, 1.0))
	mask.set_pixel(0, 0, Color(1.0, 0.0, 0.0, 1.0))
	_composer._final_hole_mask = mask

	t.check(_composer.is_hole_at_world_position(Vector3(-64.0, 0.0, -64.0)), "pixel (0,0) is a hole")
	t.check(
		not _composer.is_hole_at_world_position(Vector3(0.0, 0.0, 0.0)),
		"the interpolated mask falls below the threshold away from the hole"
	)
	t.check(
		not _composer.is_hole_at_world_position(Vector3(100.0, 0.0, 100.0)),
		"positions outside the bounds are not holes"
	)

func test_hole_query_agrees_with_a_solid_mask() -> void:
	_composer._final_hole_mask = make_flat_image(Vector2i(8, 8), 1.0)
	_composer._terrain_bounds = BOUNDS
	t.check(_composer.is_hole_at_world_position(Vector3.ZERO), "a solid mask is a hole everywhere")
	_composer._final_hole_mask = make_flat_image(Vector2i(8, 8), 0.0)
	t.check(not _composer.is_hole_at_world_position(Vector3.ZERO), "an empty mask is a hole nowhere")
