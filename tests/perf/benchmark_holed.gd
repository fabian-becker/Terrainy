extends SceneTree

## Converts the per-key microbenchmark into a real impact number: how many boundary-vertex
## keys does a holed mesh actually build, and how much of the holed-mesh cost is that?

const TerrainMeshGenerator = preload("res://addons/terrainy/helpers/terrain_mesh_generator.gd")
const TerrainCollisionBuilder = preload("res://addons/terrainy/helpers/terrain_collision_builder.gd")


func _process(_delta: float) -> bool:
	print("Holed-mesh cost breakdown\n")

	for res in [129, 257, 513]:
		var heightmap := _make_noise_image(res)
		var mask := _make_hole_mask(res, 0.2)
		var solid_ms := _best(3, func() -> void:
			TerrainMeshGenerator.generate_surface_arrays(heightmap, Vector2(512, 512), null, false)
		)
		var holed_ms := _best(3, func() -> void:
			TerrainMeshGenerator.generate_surface_arrays(heightmap, Vector2(512, 512), mask, false)
		)

		# Count the cells that actually reach the key-building branch: only cells whose four
		# corners are not all equal get here (_cell_triangles returns early otherwise).
		var mixed := _count_mixed_cells(mask)
		var total_cells: int = (res - 1) * (res - 1)
		var keys := mixed * 4
		var key_cost_ms := float(keys) * 3.702 / 1000.0   # measured us/op for the string key
		var key_cost_int_ms := float(keys) * 0.500 / 1000.0

		print("  %dx%d: solid %.1f ms | holed %.1f ms | delta %.1f ms" % [
			res, res, solid_ms, holed_ms, holed_ms - solid_ms
		])
		print("         cells %d, mixed (key-building) %d (%.2f%%)" % [
			total_cells, mixed, float(mixed) / float(total_cells) * 100.0
		])
		print("         keys built %d -> string keys cost ~%.1f ms of the delta (int keys: ~%.1f ms)" % [
			keys, key_cost_ms, key_cost_int_ms
		])
		print("         => key formatting is ~%.0f%% of the holed delta; the rest is the per-cell" % [
			key_cost_ms / maxf(holed_ms - solid_ms, 0.001) * 100.0
		])
		print("            static call (20 args) + append-based index building")
		print("")

	quit(0)
	return true


func _count_mixed_cells(mask: Image) -> int:
	var data := mask.get_data().to_float32_array()
	var w := mask.get_width()
	var h := mask.get_height()
	var mixed := 0
	for z in (h - 1):
		var row := z * w
		for x in (w - 1):
			var a := data[row + x] >= TerrainMeshGenerator.HOLE_THRESHOLD
			var b := data[row + x + 1] >= TerrainMeshGenerator.HOLE_THRESHOLD
			var c := data[row + w + x] >= TerrainMeshGenerator.HOLE_THRESHOLD
			var d := data[row + w + x + 1] >= TerrainMeshGenerator.HOLE_THRESHOLD
			if not (a == b and b == c and c == d):
				mixed += 1
	return mixed


func _make_noise_image(res: int) -> Image:
	var data := PackedFloat32Array()
	data.resize(res * res)
	for y in res:
		for x in res:
			data[y * res + x] = sin(float(x) * 0.05) * cos(float(y) * 0.05) * 30.0
	return Image.create_from_data(res, res, false, Image.FORMAT_RF, data.to_byte_array())


func _make_hole_mask(res: int, radius_frac: float) -> Image:
	var data := PackedFloat32Array()
	data.resize(res * res)
	var center := float(res) * 0.5
	var radius := float(res) * radius_frac
	for y in res:
		for x in res:
			var dx := float(x) - center
			var dz := float(y) - center
			data[y * res + x] = 1.0 if (dx * dx + dz * dz) < radius * radius else 0.0
	return Image.create_from_data(res, res, false, Image.FORMAT_RF, data.to_byte_array())


func _best(samples: int, body: Callable) -> float:
	var best := INF
	for i in samples:
		var start := Time.get_ticks_usec()
		body.call()
		best = min(best, float(Time.get_ticks_usec() - start) / 1000.0)
	return best
