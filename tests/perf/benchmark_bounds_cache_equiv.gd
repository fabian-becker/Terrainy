extends SceneTree

## Equivalence check for the influence-bounds cache.
##
## _influence_bounds_for() memoizes the active-pixel rectangle of a feature's influence map. A
## stale rectangle would silently shrink or shift the blended region, so this proves that a warm
## compose (bounds served from the cache) produces exactly the same heightmap as a cold one
## (bounds recomputed by a full scan), and that invalidation really does drop the entry.
##
## Exact float equality on the resulting heightmap.

const TerrainHeightmapBuilder = preload("res://addons/terrainy/helpers/terrain_heightmap_builder.gd")

const RES := Vector2i(257, 257)
const BOUNDS := Rect2(-512.0, -512.0, 1024.0, 1024.0)
const BASE_HEIGHT := 5.0


func _process(_delta: float) -> bool:
	print("Influence-bounds cache: warm vs cold equivalence\n")

	var features := _make_features()
	var typed := _typed(features)
	var contexts := _contexts_for(features)

	# Cold: fresh builder each time, so the bounds are always scanned.
	var cold := _compose(typed, contexts, false)
	# Warm: one builder, composed twice. The second compose is served from the caches.
	var builder = TerrainHeightmapBuilder.new()
	builder.compose(typed, contexts, RES, BOUNDS, BASE_HEIGHT, false, false, false)
	var warm: Image = builder.compose(typed, contexts, RES, BOUNDS, BASE_HEIGHT, false, false, false)[
		"heightmap"
	]

	var diff := _compare(cold["heightmap"], warm)
	print("  warm compose vs cold compose:  %s (n=%d, max %.9f)" % [
		"IDENTICAL" if diff[0] == 0 else "DIFFERS", diff[0], diff[1]
	])
	var failures := 0 if diff[0] == 0 else 1

	# A third compose after invalidate_influence must rescan and still match.
	builder.clear_influence_cache()
	var after_clear: Image = builder.compose(
		typed, contexts, RES, BOUNDS, BASE_HEIGHT, false, false, false
	)["heightmap"]
	var diff2 := _compare(cold["heightmap"], after_clear)
	print("  after clear_influence_cache:   %s (n=%d, max %.9f)" % [
		"IDENTICAL" if diff2[0] == 0 else "DIFFERS", diff2[0], diff2[1]
	])
	if diff2[0] != 0:
		failures += 1

	# Moving one feature must change the bounds; if the cache were not dropped the blend would
	# keep using the old rectangle. Mirror the production flow in TerrainComposer._on_feature_changed
	# exactly: a moved feature invalidates BOTH its heightmap (a Hill's heightmap is generated in
	# its own local space, so it is position-dependent) and its influence map.
	features[0].position = Vector3(300.0, 0.0, -250.0)
	var moved_contexts := _contexts_for(features)
	builder.invalidate_heightmap(features[0])
	builder.invalidate_influence_if_changed(features[0])
	var moved_warm: Image = builder.compose(
		typed, moved_contexts, RES, BOUNDS, BASE_HEIGHT, false, false, false
	)["heightmap"]
	var moved_cold := _compose(typed, moved_contexts, false)
	var diff3 := _compare(moved_cold["heightmap"], moved_warm)
	print("  after moving a feature:        %s (n=%d, max %.9f)" % [
		"IDENTICAL" if diff3[0] == 0 else "DIFFERS", diff3[0], diff3[1]
	])
	if diff3[0] != 0:
		failures += 1

	# And the moved terrain must actually differ from the original, otherwise the test above
	# would pass even if the move had no effect.
	var moved_vs_original := _compare(cold["heightmap"], moved_warm)
	print("  sanity: the move changed the terrain: %s (n=%d)" % [
		"yes" if moved_vs_original[0] > 0 else "NO -- test is vacuous", moved_vs_original[0]
	])
	if moved_vs_original[0] == 0:
		failures += 1

	# Direct check that the bounds entry itself is dropped on a position change -- the failure
	# mode this cache could introduce. A stale rectangle left behind here would silently clip the
	# blend region while every other cache looked consistent.
	var probe = TerrainHeightmapBuilder.new()
	var probe_ctx := _contexts_for(features)
	probe.compose(typed, probe_ctx, RES, BOUNDS, BASE_HEIGHT, false, false, false)
	var bounds_before: bool = probe._influence_bounds_cache.has(features[0])
	features[0].position = Vector3(-400.0, 0.0, 300.0)
	var moved_ctx := _contexts_for(features)
	probe.invalidate_heightmap(features[0])
	probe.invalidate_influence_if_changed(features[0])
	var bounds_dropped: bool = not probe._influence_bounds_cache.has(features[0])
	print("  bounds entry after a move:     %s (had=%s, dropped=%s)" % [
		"dropped" if bounds_dropped else "STALE -- NOT dropped", bounds_before, bounds_dropped
	])
	if not bounds_dropped:
		failures += 1
	probe.cleanup()

	print("")
	if failures == 0:
		print("EQUIVALENCE: the bounds cache does not change the composed heightmap.")
	else:
		print("EQUIVALENCE: %d check(s) failed." % failures)

	builder.cleanup()
	_free_all(features)
	quit(0)
	return true


func _compose(typed, contexts, warm: bool) -> Dictionary:
	var builder = TerrainHeightmapBuilder.new()
	var result: Dictionary = builder.compose(
		typed, contexts, RES, BOUNDS, BASE_HEIGHT, false, false, false
	)
	return result


func _make_features() -> Array:
	var features: Array = []
	for i in 3:
		var h := HillNode.new()
		h.name = "Hill%d" % i
		h.height = 40.0
		h.influence_size = Vector2(120.0 + i * 30.0, 120.0 + i * 30.0)
		h.influence_shape = TerrainFeatureNode.InfluenceShape.CIRCLE
		h.edge_falloff = 0.3
		h.position = Vector3(-200.0 + i * 180.0, 0.0, -150.0 + i * 130.0)
		get_root().add_child(h)
		features.append(h)
	return features


func _typed(features: Array) -> Array[TerrainFeatureNode]:
	var typed: Array[TerrainFeatureNode] = []
	for f in features:
		typed.append(f)
	return typed


func _contexts_for(features: Array) -> Dictionary:
	var contexts: Dictionary = {}
	for f in features:
		contexts[f] = f.prepare_evaluation_context()
	return contexts


func _compare(a: Image, b: Image) -> Array:
	var da := a.get_data().to_float32_array()
	var db := b.get_data().to_float32_array()
	if da.size() != db.size():
		return [maxi(da.size(), db.size()), INF]
	var count := 0
	var max_diff := 0.0
	for i in da.size():
		if da[i] != db[i]:
			count += 1
			max_diff = maxf(max_diff, absf(da[i] - db[i]))
	return [count, max_diff]


func _free_all(nodes: Array) -> void:
	for node in nodes:
		if is_instance_valid(node):
			node.free()
