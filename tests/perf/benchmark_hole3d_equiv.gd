extends SceneTree

## Equivalence check for the 3D hole influence path (the one case the flat clipping test cannot
## cover).
##
## A 3D hole's shape extends along Y, so clipping it with the 4-corner AABB of the flat path would
## truncate it as soon as the hole is tilted about X or Z. _influence_pixel_bounds therefore uses a
## conservative square (sqrt of the squared half extents) for those. This proves that the
## conservative region really does contain every non-zero pixel at every tested rotation.

const TerrainHeightmapBuilder = preload("res://addons/terrainy/helpers/terrain_heightmap_builder.gd")

const BOUNDS := Rect2(-512.0, -512.0, 1024.0, 1024.0)
const RES := Vector2i(257, 257)


func _process(_delta: float) -> bool:
	print("3D hole influence: clipped vs full-grid reference\n")
	var builder = TerrainHeightmapBuilder.new()
	var failures := 0

	var cases: Array = [
		{"label": "flat, no rotation", "size": Vector2(80, 80), "depth": 50.0, "rot": Vector3.ZERO},
		{"label": "tilted 30deg X", "size": Vector2(80, 80), "depth": 50.0, "rot": Vector3(30, 0, 0)},
		{"label": "tilted 45deg Z", "size": Vector2(80, 80), "depth": 50.0, "rot": Vector3(0, 0, 45)},
		{"label": "tilted 45deg X+Z", "size": Vector2(80, 80), "depth": 50.0, "rot": Vector3(45, 0, 45)},
		{"label": "tilted 60deg X, deep", "size": Vector2(60, 60), "depth": 400.0, "rot": Vector3(60, 0, 0)},
		{"label": "spinning + tilt", "size": Vector2(120, 60), "depth": 100.0, "rot": Vector3(35, 40, 25)},
		{"label": "deep, no rotation", "size": Vector2(40, 40), "depth": 800.0, "rot": Vector3.ZERO},
		{"label": "shallow wide", "size": Vector2(300, 150), "depth": 10.0, "rot": Vector3(20, 55, 0)},
	]

	for case in cases:
		var hole := HoleNode.new()
		hole.influence_size = case["size"]
		hole.influence_shape = TerrainFeatureNode.InfluenceShape.RECTANGLE
		hole.edge_falloff = 0.3
		hole.position = Vector3.ZERO
		hole.rotation_degrees = case["rot"]
		hole.use_3d_influence = true
		hole.hole_depth = case["depth"]
		get_root().add_child(hole)

		var ctx = hole.prepare_evaluation_context()
		var clipped: Image = builder._generate_hole_influence_map_3d(
			hole, ctx, RES, BOUNDS, case["depth"]
		)
		var reference := _full_grid_reference(hole, ctx, RES, BOUNDS, case["depth"])

		var diff := _compare(clipped, reference)
		if diff[0] != 0:
			failures += 1
		var bounds := builder._influence_pixel_bounds(hole, ctx, RES, BOUNDS)
		print("  %-22s %-9s (n=%d, max %.9f)  clip covers %6.2f%%" % [
			case["label"],
			"IDENTICAL" if diff[0] == 0 else "DIFFERS",
			diff[0], diff[1],
			float(bounds.size.x * bounds.size.y) / float(RES.x * RES.y) * 100.0
		])
		hole.free()

	print("")
	if failures == 0:
		print("EQUIVALENCE: all %d 3D hole cases identical (conservative region is sufficient)." % cases.size())
	else:
		print("EQUIVALENCE: %d case(s) DIFFER -- the conservative region is too small." % failures)
	builder.cleanup()
	quit(0)
	return true


func _full_grid_reference(feature, context, resolution: Vector2i, terrain_bounds: Rect2, hole_depth: float) -> Image:
	var influence_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	var influence_data := influence_map.get_data().to_float32_array()
	var step = terrain_bounds.size / Vector2(resolution - Vector2i.ONE)
	var shape_size = Vector3(feature.influence_size.x, hole_depth, feature.influence_size.y)
	for y in range(resolution.y):
		var world_z = terrain_bounds.position.y + (y * step.y)
		for x in range(resolution.x):
			var world_x = terrain_bounds.position.x + (x * step.x)
			influence_data[y * resolution.x + x] = context.get_influence_weight_3d(
				Vector3(world_x, 0, world_z), shape_size
			)
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
