extends SceneTree

## Terrainy performance benchmark harness (headless).
##
## Usage:
##     godot --headless --path . --script res://tests/perf/benchmark.gd
##     godot --headless --path . --script res://tests/perf/benchmark.gd -- --quick
##
## Measures the real cost of the pipeline stages instead of guessing at them. Every section
## times a stage in isolation so the numbers can be attributed, and each measurement runs
## `REPEATS` rounds and reports the best and the median (the best run is the least noisy
## estimate of the intrinsic cost; the spread shows how much the environment interferes).
##
## Exit code is always 0: this is a measurement tool, not a gate.

const TerrainHeightmapBuilder = preload("res://addons/terrainy/helpers/terrain_heightmap_builder.gd")
const TerrainMeshGenerator = preload("res://addons/terrainy/helpers/terrain_mesh_generator.gd")
const TerrainCollisionBuilder = preload("res://addons/terrainy/helpers/terrain_collision_builder.gd")
const TerrainDiagnostics = preload("res://addons/terrainy/helpers/terrain_diagnostics.gd")
const ModifierPipeline = preload("res://addons/terrainy/helpers/modifier_pipeline.gd")

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(257, 257),
	Vector2i(513, 513),
	Vector2i(1025, 1025),
]
const CHUNK_RESOLUTIONS: Array[int] = [129, 257, 513]
const BOUNDS := Rect2(-512.0, -512.0, 1024.0, 1024.0)
const BASE_HEIGHT := 0.0
const REPEATS := 5
const QUICK_REPEATS := 3

var _quick: bool = false
var _repeats: int = REPEATS
var _results: Array[Dictionary] = []
var _section: String = ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--quick":
			_quick = true
			_repeats = QUICK_REPEATS


func _process(_delta: float) -> bool:
	print("================================================================")
	print("Terrainy performance benchmark")
	print("Godot %s | renderer=%s | RenderingDevice=%s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		"yes" if RenderingServer.get_rendering_device() != null else "no",
	])
	print("repeats=%d (best/median reported) | quick=%s" % [_repeats, _quick])
	print("================================================================")

	_bench_feature_heightmap_generation()
	_bench_influence_map_generation()
	_bench_composition()
	_bench_mesh_generation()
	_bench_collision_generation()
	_bench_modifier_pipeline()
	_bench_cache_behaviour()

	_report()
	quit(0)
	return true


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

## Time `body` `_repeats` times and record min/median/mean in milliseconds.
func _measure(label: String, body: Callable, note: String = "") -> Dictionary:
	var samples: Array[float] = []
	for i in _repeats:
		var start := Time.get_ticks_usec()
		body.call()
		samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
	samples.sort()
	var min_ms: float = samples[0]
	var median_ms: float = samples[samples.size() / 2]
	var sum := 0.0
	for s in samples:
		sum += s
	var mean_ms := sum / float(samples.size())
	var entry := {
		"section": _section,
		"label": label,
		"min": min_ms,
		"median": median_ms,
		"mean": mean_ms,
		"note": note,
	}
	_results.append(entry)
	print("  %-52s min %9.2f ms  median %9.2f ms  %s" % [label, min_ms, median_ms, note])
	return entry


func _print_section(title: String) -> void:
	_section = title
	print("\n--- %s ---" % title)


## A feature set with the mix a real scene uses: noise, primitives, a landscape and a hole.
func _make_features(count_noise: int = 2, count_primitive: int = 2) -> Array:
	var features: Array = []
	for i in count_noise:
		var n := PerlinNoiseNode.new()
		n.name = "Perlin%d" % i
		n.noise_seed = 1000 + i
		n.amplitude = 20.0
		n.influence_size = Vector2(600.0, 600.0)
		n.edge_falloff = 0.3
		n.position = Vector3(-200.0 + i * 200.0, 0.0, -200.0)
		get_root().add_child(n)
		features.append(n)
	for i in count_primitive:
		var h := HillNode.new()
		h.name = "Hill%d" % i
		h.height = 60.0
		h.influence_size = Vector2(300.0, 300.0)
		h.edge_falloff = 0.3
		h.position = Vector3(150.0 - i * 300.0, 0.0, 150.0)
		get_root().add_child(h)
		features.append(h)
	var range_node := MountainRangeNode.new()
	range_node.name = "Range"
	range_node.influence_size = Vector2(500.0, 500.0)
	range_node.position = Vector3(0.0, 0.0, 300.0)
	get_root().add_child(range_node)
	features.append(range_node)
	return features


func _contexts_for(features: Array) -> Dictionary:
	var contexts: Dictionary = {}
	for feature in features:
		contexts[feature] = feature.prepare_evaluation_context()
	return contexts


func _typed(features: Array) -> Array[TerrainFeatureNode]:
	var typed: Array[TerrainFeatureNode] = []
	for feature in features:
		typed.append(feature)
	return typed


func _free_all(nodes: Array) -> void:
	for node in nodes:
		if is_instance_valid(node):
			node.free()


# ---------------------------------------------------------------------------
# Stage 1: per-feature heightmap generation (CPU, the innermost loop)
# ---------------------------------------------------------------------------

func _bench_feature_heightmap_generation() -> void:
	_print_section("Feature heightmap generation (generate_heightmap_with_context_raw)")
	var features := _make_features()
	var contexts := _contexts_for(features)

	for resolution in RESOLUTIONS:
		var pixels := resolution.x * resolution.y
		for feature in features:
			var ctx = contexts[feature]
			_measure(
				"%s @ %dx%d" % [feature.name, resolution.x, resolution.y],
				func() -> void:
					feature.generate_heightmap_with_context_raw(resolution, BOUNDS, ctx)
			)
		# Per-pixel cost summary for the whole feature set.
		var start := Time.get_ticks_usec()
		for feature in features:
			feature.generate_heightmap_with_context_raw(resolution, BOUNDS, contexts[feature])
		var elapsed_us := Time.get_ticks_usec() - start
		print("    -> whole set (%d features, %d px each): %.2f ms total, %.3f us/px" % [
			features.size(), pixels, float(elapsed_us) / 1000.0,
			float(elapsed_us) / float(pixels * features.size()),
		])

	_free_all(features)


# ---------------------------------------------------------------------------
# Stage 2: influence map generation (CPU fallback path)
# ---------------------------------------------------------------------------

func _bench_influence_map_generation() -> void:
	_print_section("Influence map generation (CPU path, _generate_influence_map)")
	var features := _make_features(1, 1)
	var contexts := _contexts_for(features)
	var builder = TerrainHeightmapBuilder.new()

	for resolution in RESOLUTIONS:
		var pixels := resolution.x * resolution.y
		for feature in features:
			var ctx = contexts[feature]
			_measure(
				"%s influence @ %dx%d" % [feature.name, resolution.x, resolution.y],
				func() -> void:
					builder._generate_influence_map(feature, ctx, resolution, BOUNDS)
			)

	_measure(
		"influence bounds scan (Rect2i) @ 1025x1025",
		func() -> void:
			var img: Image = builder._generate_influence_map(features[0], contexts[features[0]], Vector2i(1025, 1025), BOUNDS)
			builder._compute_influence_bounds(img, Vector2i(1025, 1025))
	)

	builder.cleanup()
	_free_all(features)


# ---------------------------------------------------------------------------
# Stage 3: composition (CPU blend + GPU when available)
# ---------------------------------------------------------------------------

func _bench_composition() -> void:
	_print_section("Heightmap composition (builder.compose)")
	var features := _make_features(2, 2)
	var typed := _typed(features)
	var contexts := _contexts_for(features)
	var has_device := RenderingServer.get_rendering_device() != null

	for resolution in RESOLUTIONS:
		var builder = TerrainHeightmapBuilder.new()
		# Cold: caches empty, everything generated + composed.
		_measure(
			"compose cold, CPU only @ %dx%d" % [resolution.x, resolution.y],
			func() -> void:
				builder.clear_all_caches()
				for feature in features:
					feature.mark_dirty()
				builder.compose(typed, contexts, resolution, BOUNDS, BASE_HEIGHT, false, false, false)
		)
		# Warm: caches populated, only the blend runs.
		builder.compose(typed, contexts, resolution, BOUNDS, BASE_HEIGHT, false, false, false)
		_measure(
			"compose warm (cached) @ %dx%d" % [resolution.x, resolution.y],
			func() -> void:
				builder.compose(typed, contexts, resolution, BOUNDS, BASE_HEIGHT, false, false, false)
		)
		if has_device:
			_measure(
				"compose cold, GPU compose @ %dx%d" % [resolution.x, resolution.y],
				func() -> void:
					builder.clear_all_caches()
					for feature in features:
						feature.mark_dirty()
					builder.compose(typed, contexts, resolution, BOUNDS, BASE_HEIGHT, true, false, true)
			)
		builder.cleanup()

	_free_all(features)


# ---------------------------------------------------------------------------
# Stage 4: mesh generation (generate_surface_arrays)
# ---------------------------------------------------------------------------

func _bench_mesh_generation() -> void:
	_print_section("Mesh generation (TerrainMeshGenerator.generate_surface_arrays)")
	var terrain_size := Vector2(512.0, 512.0)

	for chunk_res in CHUNK_RESOLUTIONS:
		var heightmap := _make_noise_image(chunk_res)
		var verts := chunk_res * chunk_res
		var tris := (chunk_res - 1) * (chunk_res - 1) * 2
		_measure(
			"solid mesh %dx%d" % [chunk_res, chunk_res],
			func() -> void:
				TerrainMeshGenerator.generate_surface_arrays(heightmap, terrain_size, null, false),
			"%d verts / %d tris" % [verts, tris]
		)

	# Holed variant: marching squares with boundary vertices is the expensive branch.
	for chunk_res in [129, 257]:
		var heightmap := _make_noise_image(chunk_res)
		var hole_mask := _make_hole_mask_image(chunk_res)
		_measure(
			"holed mesh %dx%d (marching squares)" % [chunk_res, chunk_res],
			func() -> void:
				TerrainMeshGenerator.generate_surface_arrays(heightmap, terrain_size, hole_mask, false)
		)


func _make_noise_image(res: int) -> Image:
	var data := PackedFloat32Array()
	data.resize(res * res)
	for y in res:
		for x in res:
			data[y * res + x] = sin(float(x) * 0.05) * cos(float(y) * 0.05) * 30.0
	return Image.create_from_data(res, res, false, Image.FORMAT_RF, data.to_byte_array())


func _make_hole_mask_image(res: int) -> Image:
	var data := PackedFloat32Array()
	data.resize(res * res)
	var center := float(res) * 0.5
	var radius := float(res) * 0.2
	for y in res:
		for x in res:
			var d := sqrt(pow(float(x) - center, 2.0) + pow(float(y) - center, 2.0))
			data[y * res + x] = 1.0 if d < radius else 0.0
	return Image.create_from_data(res, res, false, Image.FORMAT_RF, data.to_byte_array())


# ---------------------------------------------------------------------------
# Stage 5: collision generation
# ---------------------------------------------------------------------------

func _bench_collision_generation() -> void:
	_print_section("Collision generation (TerrainCollisionBuilder.build_faces)")
	var terrain_size := Vector2(512.0, 512.0)

	for chunk_res in [129, 257, 513]:
		var heightmap := _make_noise_image(chunk_res)
		var hole_mask := _make_hole_mask_image(chunk_res)
		_measure(
			"build_faces %dx%d, EXACT" % [chunk_res, chunk_res],
			func() -> void:
				TerrainCollisionBuilder.build_faces(heightmap, terrain_size, hole_mask, 0, 0)
		)
		_measure(
			"build_faces %dx%d, FAST(8192) stride-decimated" % [chunk_res, chunk_res],
			func() -> void:
				TerrainCollisionBuilder.build_faces(heightmap, terrain_size, hole_mask, 8192, 0)
		)

	var big := _make_noise_image(513)
	_measure(
		"mask_has_holes 513x513",
		func() -> void:
			TerrainCollisionBuilder.mask_has_holes(_make_hole_mask_image(513))
	)


# ---------------------------------------------------------------------------
# Stage 6: modifier pipeline
# ---------------------------------------------------------------------------

func _bench_modifier_pipeline() -> void:
	_print_section("Modifier pipeline (smoothing / terracing / clamping)")
	var pipeline = ModifierPipeline.new()
	var feature := HillNode.new()
	feature.position = Vector3.ZERO
	get_root().add_child(feature)
	var ctx = feature.prepare_evaluation_context()

	for resolution in [Vector2i(257, 257), Vector2i(513, 513)]:
		var heightmap := _make_noise_image(resolution.x)
		for label in ["smoothing_r2", "smoothing_r8", "terracing_5", "terracing_20", "clamp"]:
			_measure(
				"%s @ %dx%d" % [label, resolution.x, resolution.y],
				func() -> void:
					match label:
						"smoothing_r2":
							pipeline.apply_modifiers(heightmap, BOUNDS, ctx, TerrainFeatureNode.SmoothingMode.LIGHT, 2.0, false, 5, 0.2, false, 0.0, false, 100.0, true)
						"smoothing_r8":
							pipeline.apply_modifiers(heightmap, BOUNDS, ctx, TerrainFeatureNode.SmoothingMode.HEAVY, 8.0, false, 5, 0.2, false, 0.0, false, 100.0, true)
						"terracing_5":
							pipeline.apply_modifiers(heightmap, BOUNDS, ctx, TerrainFeatureNode.SmoothingMode.NONE, 2.0, true, 5, 0.2, false, 0.0, false, 100.0, true)
						"terracing_20":
							pipeline.apply_modifiers(heightmap, BOUNDS, ctx, TerrainFeatureNode.SmoothingMode.NONE, 2.0, true, 20, 0.2, false, 0.0, false, 100.0, true)
						"clamp":
							pipeline.apply_modifiers(heightmap, BOUNDS, ctx, TerrainFeatureNode.SmoothingMode.NONE, 2.0, false, 5, 0.2, true, 5.0, true, 25.0, true)
			)

	feature.free()
	pipeline.cleanup()


# ---------------------------------------------------------------------------
# Stage 7: cache behaviour (does a warm rebuild avoid the expensive stages?)
# ---------------------------------------------------------------------------

func _bench_cache_behaviour() -> void:
	_print_section("Cache behaviour (rebuild with no changes = should be near-free)")
	var features := _make_features(2, 2)
	var typed := _typed(features)
	var contexts := _contexts_for(features)
	var builder = TerrainHeightmapBuilder.new()
	var resolution := Vector2i(513, 513)

	builder.compose(typed, contexts, resolution, BOUNDS, BASE_HEIGHT, false, false, false)
	_measure(
		"1st recompose, nothing dirty (heightmaps+influence cached)",
		func() -> void:
			builder.compose(typed, contexts, resolution, BOUNDS, BASE_HEIGHT, false, false, false)
	)
	_measure(
		"recompose after mark_dirty on ONE of 5 features",
		func() -> void:
			features[0].mark_dirty()
			builder.compose(typed, contexts, resolution, BOUNDS, BASE_HEIGHT, false, false, false)
	)
	_measure(
		"recompose after invalidate_influence (heightmaps kept)",
		func() -> void:
			builder.clear_influence_cache()
			builder.compose(typed, contexts, resolution, BOUNDS, BASE_HEIGHT, false, false, false)
	)

	builder.cleanup()
	_free_all(features)


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

func _report() -> void:
	print("\n================================================================")
	print("SUMMARY (best-of-%d, milliseconds)" % _repeats)
	print("================================================================")
	var last_section := ""
	for entry in _results:
		if entry.section != last_section:
			last_section = entry.section
			print("\n%s" % last_section)
		print("  %-52s %9.2f  %s" % [entry.label, entry.min, entry.note])

	print("\nTop 15 by median cost:")
	var sorted_entries := _results.duplicate()
	sorted_entries.sort_custom(func(a, b): return a.median > b.median)
	for i in mini(15, sorted_entries.size()):
		var e: Dictionary = sorted_entries[i]
		print("  %2d. %-50s median %9.2f ms   [%s]" % [i + 1, e.label, e.median, e.section])
	print("")
