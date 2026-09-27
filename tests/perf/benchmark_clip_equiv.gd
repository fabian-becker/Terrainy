extends SceneTree

## Verifies that clipping the influence pass to the feature bounds produces the same map as the
## unclipped full-grid pass, and measures what the clip buys.
##
## An optimization that changes the terrain is not an optimization, so the equivalence check runs
## before the timings and across the cases that stress the clip region:
##   - a small feature (the case the clip exists for),
##   - a feature exactly the size of the terrain,
##   - a feature larger than the terrain,
##   - a feature fully outside the terrain,
##   - a rotated feature (the AABB is rotation-aware),
##   - a circle, a rectangle and an ellipse,
##   - a feature whose influence reaches the grid border.
##
## The reference is a local copy of the original full-grid loop, so the two are compared against
## each other rather than against a remembered result.

const TerrainHeightmapBuilder = preload("res://addons/terrainy/helpers/terrain_heightmap_builder.gd")

const BOUNDS := Rect2(-512.0, -512.0, 1024.0, 1024.0)
const RES := Vector2i(257, 257)


func _process(_delta: float) -> bool:
	print("Influence-map clipping: equivalence + speedup")
	print("grid %dx%d, terrain bounds %s\n" % [RES.x, RES.y, BOUNDS])

	var builder = TerrainHeightmapBuilder.new()
	var failures := 0

	var cases: Array = [
		{"label": "small circle r=25", "size": Vector2(50, 50), "shape": TerrainFeatureNode.InfluenceShape.CIRCLE, "pos": Vector3.ZERO, "rot": Vector3.ZERO},
		{"label": "small rectangle 40x40", "size": Vector2(40, 40), "shape": TerrainFeatureNode.InfluenceShape.RECTANGLE, "pos": Vector3(120, 0, -80), "rot": Vector3.ZERO},
		{"label": "small ellipse 60x30", "size": Vector2(60, 30), "shape": TerrainFeatureNode.InfluenceShape.ELLIPSE, "pos": Vector3(-200, 0, 150), "rot": Vector3.ZERO},
		{"label": "rotated 37deg rect", "size": Vector2(120, 80), "shape": TerrainFeatureNode.InfluenceShape.RECTANGLE, "pos": Vector3(90, 0, 40), "rot": Vector3(0, 37, 0)},
		{"label": "rotated 45deg tiny", "size": Vector2(30, 30), "shape": TerrainFeatureNode.InfluenceShape.CIRCLE, "pos": Vector3(-60, 0, -60), "rot": Vector3(0, 45, 0)},
		{"label": "terrain-sized rect", "size": Vector2(1024, 1024), "shape": TerrainFeatureNode.InfluenceShape.RECTANGLE, "pos": Vector3.ZERO, "rot": Vector3.ZERO},
		{"label": "larger than terrain", "size": Vector2(3000, 3000), "shape": TerrainFeatureNode.InfluenceShape.CIRCLE, "pos": Vector3.ZERO, "rot": Vector3.ZERO},
		{"label": "fully outside", "size": Vector2(50, 50), "shape": TerrainFeatureNode.InfluenceShape.CIRCLE, "pos": Vector3(5000, 0, 5000), "rot": Vector3.ZERO},
		{"label": "at the min corner", "size": Vector2(80, 80), "shape": TerrainFeatureNode.InfluenceShape.CIRCLE, "pos": Vector3(-512, 0, -512), "rot": Vector3.ZERO},
		{"label": "at the max corner", "size": Vector2(80, 80), "shape": TerrainFeatureNode.InfluenceShape.CIRCLE, "pos": Vector3(512, 0, 512), "rot": Vector3.ZERO},
		{"label": "crossing the left edge", "size": Vector2(120, 120), "shape": TerrainFeatureNode.InfluenceShape.RECTANGLE, "pos": Vector3(-540, 0, 0), "rot": Vector3.ZERO},
		{"label": "no falloff small", "size": Vector2(50, 50), "shape": TerrainFeatureNode.InfluenceShape.CIRCLE, "pos": Vector3(30, 0, 30), "rot": Vector3.ZERO, "falloff": 0.0},
	]

	for case in cases:
		var hill := HillNode.new()
		hill.height = 30.0
		hill.influence_size = case["size"]
		hill.influence_shape = case["shape"]
		hill.edge_falloff = case.get("falloff", 0.3)
		hill.position = case["pos"]
		hill.rotation_degrees = case["rot"]
		get_root().add_child(hill)

		var ctx = hill.prepare_evaluation_context()
		var clipped: Image = builder._generate_influence_map(hill, ctx, RES, BOUNDS)
		var reference := _full_grid_reference(hill, ctx, RES, BOUNDS)

		var diff := _compare(clipped, reference)
		var verdict := "IDENTICAL" if diff[0] == 0 else "DIFFERS"
		if diff[0] != 0:
			failures += 1

		var bounds := TerrainHeightmapBuilder.new()._influence_pixel_bounds(hill, ctx, RES, BOUNDS)
		var coverage := float(bounds.size.x * bounds.size.y) / float(RES.x * RES.y) * 100.0
		print("  %-24s %-9s (n=%d, max %.9f)  clip covers %6.2f%% of the grid" % [
			case["label"], verdict, diff[0], diff[1], coverage
		])

		hill.free()
	print("")

	if failures == 0:
		print("EQUIVALENCE: all %d cases identical to the full-grid pass.\n" % cases.size())
	else:
		print("EQUIVALENCE: %d case(s) DIFFER -- do not ship.\n" % failures)

	_measure_speedup(builder)
	builder.cleanup()
	quit(0)
	return true


## The original implementation: the full-grid loop, kept here as the reference to compare against.
func _full_grid_reference(feature, context, resolution: Vector2i, terrain_bounds: Rect2) -> Image:
	var influence_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	var influence_data := influence_map.get_data().to_float32_array()
	var step = terrain_bounds.size / Vector2(resolution - Vector2i.ONE)
	for y in range(resolution.y):
		var world_z = terrain_bounds.position.y + (y * step.y)
		for x in range(resolution.x):
			var world_x = terrain_bounds.position.x + (x * step.x)
			var weight = feature.get_influence_weight_safe(Vector3(world_x, 0, world_z), context)
			influence_data[y * resolution.x + x] = weight
	influence_map.set_data(resolution.x, resolution.y, false, Image.FORMAT_RF, influence_data.to_byte_array())
	return influence_map


func _compare(a: Image, b: Image) -> Array:
	var da := a.get_data().to_float32_array()
	var db := b.get_data().to_float32_array()
	var count := 0
	var max_diff := 0.0
	for i in da.size():
		if da[i] != db[i]:
			count += 1
			max_diff = maxf(max_diff, absf(da[i] - db[i]))
	return [count, max_diff]


func _measure_speedup(builder) -> void:
	print("SPEEDUP (clipped vs full-grid, 5 runs, best):")
	var small := HillNode.new()
	small.height = 30.0
	small.influence_size = Vector2(50, 50)
	small.influence_shape = TerrainFeatureNode.InfluenceShape.CIRCLE
	small.position = Vector3.ZERO
	get_root().add_child(small)
	var ctx = small.prepare_evaluation_context()

	for res in [Vector2i(513, 513), Vector2i(1025, 1025)]:
		var clipped := _best(5, func() -> void:
			builder._generate_influence_map(small, ctx, res, BOUNDS)
		)
		var full := _best(5, func() -> void:
			_full_grid_reference(small, ctx, res, BOUNDS)
		)
		print("  small feature @ %dx%d: full %9.1f ms | clipped %7.2f ms | %5.1fx faster" % [
			res.x, res.y, full, clipped, full / maxf(clipped, 0.001)
		])

	var large := HillNode.new()
	large.height = 30.0
	large.influence_size = Vector2(900, 900)
	large.influence_shape = TerrainFeatureNode.InfluenceShape.CIRCLE
	large.position = Vector3.ZERO
	get_root().add_child(large)
	var lctx = large.prepare_evaluation_context()
	for res in [Vector2i(513, 513), Vector2i(1025, 1025)]:
		var clipped := _best(5, func() -> void:
			builder._generate_influence_map(large, lctx, res, BOUNDS)
		)
		var full := _best(5, func() -> void:
			_full_grid_reference(large, lctx, res, BOUNDS)
		)
		print("  large feature @ %dx%d: full %9.1f ms | clipped %7.2f ms | %5.2fx faster" % [
			res.x, res.y, full, clipped, full / maxf(clipped, 0.001)
		])

	small.free()
	large.free()


func _best(samples: int, body: Callable) -> float:
	var best := INF
	for i in samples:
		var start := Time.get_ticks_usec()
		body.call()
		best = min(best, float(Time.get_ticks_usec() - start) / 1000.0)
	return best
