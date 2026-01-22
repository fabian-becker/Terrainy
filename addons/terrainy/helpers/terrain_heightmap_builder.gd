class_name TerrainHeightmapBuilder
extends RefCounted

## Helper class for composing heightmaps from terrain features
## Handles GPU/CPU composition, caching, and influence map generation

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")
const GpuHeightmapBlender = preload("res://addons/terrainy/helpers/gpu_heightmap_blender.gd")

# Constants
const INFLUENCE_WEIGHT_THRESHOLD = 0.001
const CACHE_KEY_POSITION_PRECISION = 0.01
const CACHE_KEY_FALLOFF_PRECISION = 0.01

# Caches
var _heightmap_cache: Dictionary = {}  # feature -> Image
var _influence_cache: Dictionary = {}  # feature -> Image
var _influence_cache_keys: Dictionary = {}  # feature -> cache key
var _cached_resolution: Vector2i
var _cached_bounds: Rect2

# GPU compositor
var _gpu_compositor: GpuHeightmapBlender = null
var _use_gpu: bool = true

func _init() -> void:
	_initialize_gpu_compositor()

func _initialize_gpu_compositor() -> void:
	# Check if GPU composition is available
	if not RenderingServer.get_rendering_device():
		print("[TerrainHeightmapBuilder] No RenderingDevice available (compatibility renderer?), GPU composition disabled")
		_use_gpu = false
		return
	
	_gpu_compositor = GpuHeightmapBlender.new()
	if not _gpu_compositor.is_available():
		push_warning("[TerrainHeightmapBuilder] GPU composition unavailable, will use CPU fallback")
		_use_gpu = false
	else:
		print("[TerrainHeightmapBuilder] GPU compositor initialized")
		_use_gpu = true

## Compose heightmaps from features
func compose(
	features: Array[TerrainFeatureNode],
	contexts: Dictionary,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	base_height: float,
	use_gpu_composition: bool
) -> Image:
	var total_start = Time.get_ticks_msec()
	# Check if resolution or bounds changed (invalidate influence cache)
	if _cached_resolution != resolution or _cached_bounds != terrain_bounds:
		_influence_cache.clear()
		_cached_resolution = resolution
		_cached_bounds = terrain_bounds
	
	# Step 1: Generate/update heightmaps for dirty features using contexts (PARALLEL)
	var feature_gen_start = Time.get_ticks_msec()
	var generated_count := 0
	var reused_count := 0
	var parallel_tasks := []
	var task_results := {}  # Shared dictionary for worker results
	
	# Separate features into: need generation vs cached
	for feature in features:
		if not is_instance_valid(feature) or not feature.is_inside_tree() or not feature.visible:
			if _heightmap_cache.has(feature):
				_heightmap_cache.erase(feature)
			continue
		
		# Check if we need to regenerate this feature's heightmap
		if not _heightmap_cache.has(feature) or feature.is_dirty():
			# Launch parallel generation task
			var ctx = contexts.get(feature)
			if ctx:
				var task_id = WorkerThreadPool.add_task(
					_generate_heightmap_worker.bind(feature, resolution, terrain_bounds, ctx, task_results)
				)
				parallel_tasks.append({"feature": feature, "task_id": task_id})
			else:
				# Fallback: generate on main thread (shouldn't happen in Phase 4+)
				push_warning("[TerrainHeightmapBuilder] No context for feature '%s', generating on main thread" % feature.name)
				_heightmap_cache[feature] = feature.generate_heightmap(resolution, terrain_bounds)
			generated_count += 1
		else:
			reused_count += 1
	
	# Wait for all parallel tasks to complete
	for task in parallel_tasks:
		WorkerThreadPool.wait_for_task_completion(task.task_id)
	
	# Retrieve results from shared dictionary and cache them
	for task in parallel_tasks:
		var feature = task.feature
		if task_results.has(feature):
			_heightmap_cache[feature] = task_results[feature]
		else:
			push_error("[TerrainHeightmapBuilder] Failed to generate heightmap for feature '%s'" % feature.name)
	
	var feature_gen_elapsed = Time.get_ticks_msec() - feature_gen_start
	if generated_count > 0:
		print("[TerrainHeightmapBuilder] Feature heightmaps: %d generated in parallel, %d cached in %d ms" % [generated_count, reused_count, feature_gen_elapsed])
	else:
		print("[TerrainHeightmapBuilder] Feature heightmaps: all %d cached (0 generated)" % reused_count)
	
	# Step 2: Compose all heightmaps
	if _should_use_gpu(use_gpu_composition):
		var result = _compose_gpu(features, contexts, resolution, terrain_bounds, base_height)
		if result:
			var total_elapsed = Time.get_ticks_msec() - total_start
			print("[TerrainHeightmapBuilder] Compose total time: %d ms" % total_elapsed)
			return result
		# GPU failed, fall back to CPU
		push_warning("[TerrainHeightmapBuilder] GPU composition failed, falling back to CPU")
	
	var cpu_result = _compose_cpu(features, contexts, resolution, terrain_bounds, base_height)
	var total_elapsed = Time.get_ticks_msec() - total_start
	print("[TerrainHeightmapBuilder] Compose total time: %d ms" % total_elapsed)
	return cpu_result

## Check if GPU composition should be used
func _should_use_gpu(user_wants_gpu: bool) -> bool:
	if not user_wants_gpu:
		return false
	if not _use_gpu:
		return false
	if not _gpu_compositor or not _gpu_compositor.is_available():
		return false
	return true

## Compose final heightmap using GPU
func _compose_gpu(
	features: Array[TerrainFeatureNode],
	contexts: Dictionary,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	base_height: float
) -> Image:
	var start_time = Time.get_ticks_msec()
	
	# Prepare data arrays
	var feature_heightmaps: Array[Image] = []
	var influence_maps: Array[Image] = []
	var blend_modes := PackedInt32Array()
	var strengths := PackedFloat32Array()
	
	var influence_gen_time = 0
	var influence_generated_count = 0
	var influence_cached_count = 0
	
	# Collect valid features
	for feature in features:
		if not _heightmap_cache.has(feature):
			continue
		
		var feature_map = _heightmap_cache[feature]
		
		# Validate resolution match
		if feature_map.get_width() != resolution.x or feature_map.get_height() != resolution.y:
			continue
		
		# Get or generate cached influence map
		var influence_map: Image
		var cache_key = _get_influence_cache_key(feature)
		
		if _influence_cache.has(feature) and _influence_cache_keys.get(feature) == cache_key:
			influence_map = _influence_cache[feature]
			influence_cached_count += 1
		else:
			var inf_start = Time.get_ticks_msec()
			# Use GPU to generate influence map for better performance
			if _gpu_compositor and _gpu_compositor.is_available():
				influence_map = _gpu_compositor.generate_influence_map_gpu(feature, resolution, terrain_bounds)
				print("[TerrainHeightmapBuilder] Generated influence map for '%s' on GPU in %d ms" % [feature.name, Time.get_ticks_msec() - inf_start])
			else:
				# Get context for thread-safe influence calculation
				var ctx = contexts.get(feature)
				if ctx:
					influence_map = _generate_influence_map(feature, ctx, resolution, terrain_bounds)
				else:
					push_warning("[TerrainHeightmapBuilder] No context for feature '%s', using fallback" % feature.name)
					influence_map = _generate_influence_map(feature, null, resolution, terrain_bounds)
				print("[TerrainHeightmapBuilder] Generated influence map for '%s' on CPU in %d ms" % [feature.name, Time.get_ticks_msec() - inf_start])
			influence_gen_time += Time.get_ticks_msec() - inf_start
			influence_generated_count += 1
			_influence_cache[feature] = influence_map
			_influence_cache_keys[feature] = cache_key
		
		feature_heightmaps.append(feature_map)
		influence_maps.append(influence_map)
		blend_modes.append(feature.blend_mode)
		strengths.append(feature.strength)
	
	# If no features, return base height
	if feature_heightmaps.is_empty():
		var base_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
		base_map.fill(Color(base_height, 0, 0, 1))
		return base_map
	
	# Compose on GPU
	var result = _gpu_compositor.compose_gpu(
		resolution,
		base_height,
		feature_heightmaps,
		influence_maps,
		blend_modes,
		strengths
	)
	
	var elapsed = Time.get_ticks_msec() - start_time
	if influence_gen_time > 0:
		print("[TerrainHeightmapBuilder] GPU composed %d features in %d ms (%d generated, %d cached, %d ms influence generation)" % [
			feature_heightmaps.size(), elapsed, influence_generated_count, influence_cached_count, influence_gen_time
		])
	else:
		print("[TerrainHeightmapBuilder] GPU composed %d features in %d ms (all %d influence maps cached)" % [
			feature_heightmaps.size(), elapsed, influence_cached_count
		])
	
	return result

## Compose final heightmap using CPU
func _compose_cpu(
	features: Array[TerrainFeatureNode],
	contexts: Dictionary,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	base_height: float
) -> Image:
	var start_time = Time.get_ticks_msec()
	
	# Create base heightmap
	var final_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	final_map.fill(Color(base_height, 0, 0, 1))
	
	# Step 1: Pre-compute all influence maps on main thread (avoids to_local() issues in threads)
	var blend_data = []
	for feature in features:
		if not _heightmap_cache.has(feature):
			continue
		
		var feature_map = _heightmap_cache[feature]
		
		# Validate resolution match
		if feature_map.get_width() != resolution.x or feature_map.get_height() != resolution.y:
			push_warning("[TerrainHeightmapBuilder] Feature '%s' heightmap size mismatch, skipping" % feature.name)
			continue
		
		# Get or generate cached influence map
		var influence_map: Image
		var cache_key = _get_influence_cache_key(feature)
		
		if _influence_cache.has(feature) and _influence_cache_keys.get(feature) == cache_key:
			influence_map = _influence_cache[feature]
		else:
			# Get context for thread-safe influence calculation
			var ctx = contexts.get(feature)
			if ctx:
				influence_map = _generate_influence_map(feature, ctx, resolution, terrain_bounds)
			else:
				push_warning("[TerrainHeightmapBuilder] No context for feature '%s', using fallback" % feature.name)
				influence_map = _generate_influence_map(feature, null, resolution, terrain_bounds)
			_influence_cache[feature] = influence_map
			_influence_cache_keys[feature] = cache_key
		
		blend_data.append({
			"heightmap": feature_map,
			"influence": influence_map,
			"blend_mode": feature.blend_mode,
			"strength": feature.strength
		})
	
	if blend_data.is_empty():
		var elapsed = Time.get_ticks_msec() - start_time
		print("[TerrainHeightmapBuilder] CPU composed 0 features in %d ms" % elapsed)
		return final_map
	
	# Step 2: Blend using optimized byte array operations
	# Note: GDScript PackedByteArray cannot be safely shared across threads,
	# so we use single-threaded processing with optimized byte operations
	_blend_all_features(final_map, blend_data, resolution)
	
	var elapsed = Time.get_ticks_msec() - start_time
	print("[TerrainHeightmapBuilder] CPU composed %d features in %d ms" % [
		blend_data.size(), elapsed
	])
	
	return final_map

## Blend all features into final map using optimized byte array operations
func _blend_all_features(
	final_map: Image,
	blend_data: Array,
	resolution: Vector2i
) -> void:
	var final_data = final_map.get_data()
	var bytes_per_pixel = 4  # FORMAT_RF = 4 bytes (float32)
	var width = resolution.x
	var height = resolution.y
	
	# Process each feature
	for data in blend_data:
		var feature_map: Image = data["heightmap"]
		var influence_map: Image = data["influence"]
		var blend_mode: int = data["blend_mode"]
		var strength: float = data["strength"]
		
		# Get byte buffers for feature and influence
		var feature_data = feature_map.get_data()
		var influence_data = influence_map.get_data()
		
		# Process all pixels
		for y in range(height):
			for x in range(width):
				var pixel_index = y * width + x
				var offset = pixel_index * bytes_per_pixel
				
				# Read influence weight
				var weight = influence_data.decode_float(offset)
				if weight <= INFLUENCE_WEIGHT_THRESHOLD:
					continue
				
				# Read heights
				var current_height = final_data.decode_float(offset)
				var feature_height = feature_data.decode_float(offset)
				var weighted_height = feature_height * weight * strength
				
				# Apply blend mode
				var new_height: float
				match blend_mode:
					TerrainFeatureNode.BlendMode.ADD:
						new_height = current_height + weighted_height
					TerrainFeatureNode.BlendMode.SUBTRACT:
						new_height = current_height - weighted_height
					TerrainFeatureNode.BlendMode.MULTIPLY:
						new_height = current_height * (1.0 + weighted_height)
					TerrainFeatureNode.BlendMode.MAX:
						new_height = max(current_height, feature_height * weight)
					TerrainFeatureNode.BlendMode.MIN:
						new_height = min(current_height, feature_height * weight)
					TerrainFeatureNode.BlendMode.AVERAGE:
						new_height = (current_height + weighted_height) * 0.5
					_:
						new_height = current_height + weighted_height
				
				# Write new height
				final_data.encode_float(offset, new_height)
	
	# Update image with modified data
	final_map.set_data(width, height, false, Image.FORMAT_RF, final_data)

## Generate influence map for a feature using context (thread-safe)
func _generate_influence_map(
	feature: TerrainFeatureNode,
	context,
	resolution: Vector2i,
	terrain_bounds: Rect2
) -> Image:
	var influence_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	var influence_data = influence_map.get_data()
	var bytes_per_pixel = 4  # FORMAT_RF = 4 bytes (float32)
	
	var step = terrain_bounds.size / Vector2(resolution - Vector2i.ONE)
	
	for y in range(resolution.y):
		var world_z = terrain_bounds.position.y + (y * step.y)
		for x in range(resolution.x):
			var world_x = terrain_bounds.position.x + (x * step.x)
			var world_pos = Vector3(world_x, 0, world_z)
			
			# Use thread-safe context-based influence calculation
			var weight = feature.get_influence_weight_safe(world_pos, context)
			var pixel_index = y * resolution.x + x
			var offset = pixel_index * bytes_per_pixel
			influence_data.encode_float(offset, weight)
	
	# Update image with computed data
	influence_map.set_data(resolution.x, resolution.y, false, Image.FORMAT_RF, influence_data)
	
	return influence_map

## Generate cache key for influence map
func _get_influence_cache_key(feature: TerrainFeatureNode) -> String:
	# Only include properties that affect influence calculation
	var pos_rounded = (feature.global_position / CACHE_KEY_POSITION_PRECISION).round() * CACHE_KEY_POSITION_PRECISION
	var size_rounded = (feature.influence_size / CACHE_KEY_POSITION_PRECISION).round() * CACHE_KEY_POSITION_PRECISION
	var falloff_rounded = snappedf(feature.edge_falloff, CACHE_KEY_FALLOFF_PRECISION)
	return "%s_%s_%d_%f" % [
		pos_rounded,
		size_rounded,
		int(feature.influence_shape),
		falloff_rounded
	]

## Invalidate heightmap cache for a feature
func invalidate_heightmap(feature: TerrainFeatureNode) -> void:
	if _heightmap_cache.has(feature):
		_heightmap_cache.erase(feature)

## Invalidate influence cache for a feature
func invalidate_influence(feature: TerrainFeatureNode) -> void:
	if _influence_cache.has(feature):
		_influence_cache.erase(feature)
	if _influence_cache_keys.has(feature):
		_influence_cache_keys.erase(feature)

## Clear all caches
func clear_all_caches() -> void:
	_heightmap_cache.clear()
	_influence_cache.clear()
	_influence_cache_keys.clear()

## Worker thread function for parallel heightmap generation
## Writes result to shared dictionary instead of returning (WorkerThreadPool limitation with complex objects)
func _generate_heightmap_worker(
	feature: TerrainFeatureNode,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	context,
	results: Dictionary
) -> void:
	var heightmap = feature.generate_heightmap_with_context(resolution, terrain_bounds, context)
	results[feature] = heightmap

## Cleanup GPU resources
func cleanup() -> void:
	if _gpu_compositor:
		_gpu_compositor.cleanup()
		_gpu_compositor = null
