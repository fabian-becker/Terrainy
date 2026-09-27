extends SceneTree

## Terrainy bottleneck probes: isolates the specific per-pixel / per-copy costs that the
## full benchmark points at, and measures what the proposed fixes would actually buy.
##
## Usage:
##     godot --headless --path . --script res://tests/perf/benchmark_probes.gd
##
## Each probe is a hypothesis from reading the code, turned into a measurement:
##   A. how expensive is one get_influence_weight() call (full 4x4 transform per pixel)?
##   B. what does one full-resolution get_data().to_float32_array() copy cost?
##   C. how much of the influence-map pass is wasted on pixels outside the feature AABB?
##   D. does the influence bounds scan cost a second full pass on top of generation?

const TerrainHeightmapBuilder = preload("res://addons/terrainy/helpers/terrain_heightmap_builder.gd")

const BOUNDS := Rect2(-512.0, -512.0, 1024.0, 1024.0)
const REPEATS := 5
var _repeats: int = REPEATS


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--quick":
			_repeats = 3


func _process(_delta: float) -> bool:
	print("================================================================")
	print("Terrainy bottleneck probes")
	print("CPU: %s | Godot %s" % [
		OS.get_processor_name(), Engine.get_version_info().string
	])
	print("================================================================")

	_probe_a_per_pixel_weight_cost()
	_probe_b_image_copy_cost()
	_probe_c_aabb_clipping_win()
	_probe_d_bounds_scan_cost()

	print("\nDone.")
	quit(0)
	return true


func _time(label: String, iterations: int, body: Callable) -> float:
	var best_us := INF
	for i in _repeats:
		var start := Time.get_ticks_usec()
		body.call()
		var elapsed := float(Time.get_ticks_usec() - start)
		best_us = min(best_us, elapsed)
	var ms := best_us / 1000.0
	print("  %-56s %9.3f ms  (%8.3f us/iter)" % [
		label, ms, best_us / float(maxi(iterations, 1))
	])
	return ms


# ---------------------------------------------------------------------------
# A. Per-pixel cost of the influence weight call
# ---------------------------------------------------------------------------

func _probe_a_per_pixel_weight_cost() -> void:
	print("\n--- A. Per-pixel influence weight cost (the innermost loop) ---")

	var feature := HillNode.new()
	feature.name = "ProbeHill"
	feature.position = Vector3.ZERO
	feature.influence_size = Vector2(300.0, 300.0)
	feature.edge_falloff = 0.3
	get_root().add_child(feature)
	var context = feature.prepare_evaluation_context()

	# A feature with rotation, because the transform is what costs: identity would flatter it.
	feature.rotation_degrees = Vector3(0.0, 37.0, 0.0)
	feature.transform = feature.transform  # commit
	var rotated_ctx = feature.prepare_evaluation_context()

	var n := 1_000_000
	var pos_cache: Array[Vector3] = []
	pos_cache.resize(1024)
	for i in 1024:
		pos_cache[i] = Vector3(-500.0 + float(i), 0.0, -500.0 + float(i) * 0.5)

	var identity_ctx = context
	_time("context.to_local() x %d (4x4 matrix transform)" % n, n, func() -> void:
		var acc := 0.0
		for i in n:
			var p: Vector3 = pos_cache[i & 1023]
			acc += identity_ctx.to_local(p).x
	)

	_time("context.get_influence_weight() x %d (unrotated)" % n, n, func() -> void:
		var acc := 0.0
		for i in n:
			acc += context.get_influence_weight(pos_cache[i & 1023])
	)

	_time("context.get_influence_weight() x %d (rotated feature)" % n, n, func() -> void:
		var acc := 0.0
		for i in n:
			acc += rotated_ctx.get_influence_weight(pos_cache[i & 1023])
	)

	_time("feature.get_influence_weight_safe() x %d (full path)" % n, n, func() -> void:
		var acc := 0.0
		for i in n:
			acc += feature.get_influence_weight_safe(pos_cache[i & 1023], context)
	)

	# AABB early-reject: how much cheaper is the cheap test than the full weight?
	_time("context.aabb.has_point() x %d (cheap reject test)" % n, n, func() -> void:
		var hits := 0
		for i in n:
			if context.aabb.has_point(pos_cache[i & 1023]):
				hits += 1
	)

	feature.free()


# ---------------------------------------------------------------------------
# B. Image copy cost (get_data().to_float32_array() and back)
# ---------------------------------------------------------------------------

func _probe_b_image_copy_cost() -> void:
	print("\n--- B. Full-image copy cost (get_data/to_float32_array/to_byte_array) ---")

	for res in [257, 513, 1025]:
		var img := _make_noise_image(res)
		var bytes: int = res * res * 4
		_time("get_data().to_float32_array() @ %dx%d (%.1f MB)" % [res, res, bytes / 1048576.0], 1, func() -> void:
			var d := img.get_data().to_float32_array()
			# Keep the result observable so the compiler cannot elide the copy.
			if d.size() == 0:
				print("empty")
		)
		var data := img.get_data().to_float32_array()
		_time("float32_array.to_byte_array() @ %dx%d" % [res, res], 1, func() -> void:
			var b := data.to_byte_array()
			if b.size() == 0:
				print("empty")
		)
		_time("Image.create_from_data() @ %dx%d" % [res, res], 1, func() -> void:
			var i2 := Image.create_from_data(res, res, false, Image.FORMAT_RF, data.to_byte_array())
			if i2 == null:
				print("null")
		)


# ---------------------------------------------------------------------------
# C. What AABB clipping the influence map loop would buy
# ---------------------------------------------------------------------------

func _probe_c_aabb_clipping_win() -> void:
	print("\n--- C. Influence map: full-grid loop vs AABB-clipped loop ---")
	print("  (a feature covering a small part of the terrain still walks every pixel)")
	var builder = TerrainHeightmapBuilder.new()

	for res in [513, 1025]:
		var size := Vector2i(res, res)
		var pixels: int = res * res

		# Small feature: 10% of the terrain edge length => ~1% of the pixels.
		var small := _make_hill(Vector2(102.0, 102.0), Vector3.ZERO)
		var ctx_small = small.prepare_evaluation_context()

		# Large feature: covers most of the terrain.
		var large := _make_hill(Vector2(900.0, 900.0), Vector3.ZERO)
		var ctx_large = large.prepare_evaluation_context()

		var full_small := _time("Full-grid influence map, small feature @ %dx%d (%d px)" % [res, res, pixels], 1, func() -> void:
			var img: Image = builder._generate_influence_map(small, ctx_small, size, BOUNDS)
			if img == null:
				print("null")
		)

		# Clipped: only iterate the pixels inside the rotation-aware AABB.
		var clipped_small := _time("AABB-clipped loop, small feature @ %dx%d" % [res, res], 1, func() -> void:
			_clipped_influence_pass(small, ctx_small, size)
		)

		var clipped_large := _time("AABB-clipped loop, large feature @ %dx%d" % [res, res], 1, func() -> void:
			_clipped_influence_pass(large, ctx_large, size)
		)
		var full_large := _time("Full-grid influence map, large feature @ %dx%d" % [res, res], 1, func() -> void:
			var img: Image = builder._generate_influence_map(large, ctx_large, size, BOUNDS)
			if img == null:
				print("null")
		)

		print("    => small feature speedup from clipping: %.1fx (%.1f ms -> %.1f ms)" % [
			full_small / maxf(clipped_small, 0.001), full_small, clipped_small
		])
		print("    => large feature speedup from clipping: %.1fx (%.1f ms -> %.1f ms)" % [
			full_large / maxf(clipped_large, 0.001), full_large, clipped_large
		])
		small.free()
		large.free()

	builder.cleanup()


## A copy of _generate_influence_map's loop, restricted to the feature AABB. Used only to
## measure what the production change would cost; not part of the addon.
func _clipped_influence_pass(feature, context, resolution: Vector2i) -> void:
	var influence_map := Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	var influence_data := influence_map.get_data().to_float32_array()
	var step = BOUNDS.size / Vector2(resolution - Vector2i.ONE)

	var aabb: AABB = context.aabb
	var x0 := clampi(int(floor((aabb.position.x - BOUNDS.position.x) / step.x)), 0, resolution.x - 1)
	var x1 := clampi(int(ceil((aabb.position.x + aabb.size.x - BOUNDS.position.x) / step.x)), 0, resolution.x - 1)
	var y0 := clampi(int(floor((aabb.position.z - BOUNDS.position.y) / step.y)), 0, resolution.y - 1)
	var y1 := clampi(int(ceil((aabb.position.z + aabb.size.z - BOUNDS.position.y) / step.y)), 0, resolution.y - 1)

	for y in range(y0, y1 + 1):
		var world_z = BOUNDS.position.y + (y * step.y)
		var row := y * resolution.x
		for x in range(x0, x1 + 1):
			var world_x = BOUNDS.position.x + (x * step.x)
			influence_data[row + x] = feature.get_influence_weight_safe(
				Vector3(world_x, 0, world_z), context
			)

	influence_map.set_data(resolution.x, resolution.y, false, Image.FORMAT_RF, influence_data.to_byte_array())


func _make_hill(size: Vector2, position: Vector3) -> HillNode:
	var hill := HillNode.new()
	hill.name = "ProbeHill"
	hill.height = 40.0
	hill.influence_size = size
	hill.edge_falloff = 0.3
	hill.position = position
	get_root().add_child(hill)
	return hill


# ---------------------------------------------------------------------------
# D. The extra full pass: _compute_influence_bounds
# ---------------------------------------------------------------------------

func _probe_d_bounds_scan_cost() -> void:
	print("\n--- D. _compute_influence_bounds: a second full pass per feature ---")
	var builder = TerrainHeightmapBuilder.new()

	for res in [513, 1025]:
		var size := Vector2i(res, res)
		var hill := _make_hill(Vector2(200.0, 200.0), Vector3.ZERO)
		var ctx = hill.prepare_evaluation_context()
		var img: Image = builder._generate_influence_map(hill, ctx, size, BOUNDS)

		var gen := _time("generate influence map @ %dx%d (for reference)" % [res, res], 1, func() -> void:
			var i2: Image = builder._generate_influence_map(hill, ctx, size, BOUNDS)
			if i2 == null:
				print("null")
		)
		var scan := _time("_compute_influence_bounds @ %dx%d" % [res, res], 1, func() -> void:
			var r: Rect2i = builder._compute_influence_bounds(img, size)
			if r.size.x < 0:
				print("negative")
		)
		print("    => bounds scan adds %.0f%% on top of generation (%.1f ms vs %.1f ms)" % [
			scan / maxf(gen, 0.001) * 100.0, scan, gen
		])
		hill.free()

	builder.cleanup()


func _make_noise_image(res: int) -> Image:
	var data := PackedFloat32Array()
	data.resize(res * res)
	for y in res:
		for x in res:
			data[y * res + x] = sin(float(x) * 0.05) * cos(float(y) * 0.05) * 30.0
	return Image.create_from_data(res, res, false, Image.FORMAT_RF, data.to_byte_array())
