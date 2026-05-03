class_name TerrainHeightmapBuilder
extends RefCounted

## Helper class for composing heightmaps from terrain features
## Handles GPU/CPU composition, caching, and influence map generation

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")
const GpuHeightmapBlender = preload("res://addons/terrainy/helpers/gpu_heightmap_blender.gd")
const GpuFeatureEvaluator = preload("res://addons/terrainy/helpers/gpu_feature_evaluator.gd")

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

# Thread safety
var _task_mutex: Mutex = Mutex.new()
var _cache_mutex: Mutex = Mutex.new()

# GPU compositor
var _gpu_compositor: GpuHeightmapBlender = null
var _use_gpu: bool = true

# GPU feature evaluator (stub)
var _gpu_feature_evaluator: GpuFeatureEvaluator = null

# GPU parameter pack cache (debug/validation)
var _last_gpu_param_packs: Array = []

func _init() -> void:
	_initialize_gpu_compositor()
	_initialize_gpu_feature_evaluator()

func _initialize_gpu_compositor() -> void:
	# Check if GPU composition is available
	if not RenderingServer.get_rendering_device():
		print("[TerrainHeightmapBuilder] No RenderingDevice available (compatibility renderer?), GPU composition disabled")
		_use_gpu = false
		return
	
	_gpu_compositor = GpuHeightmapBlender.new()
	if not _gpu_compositor.is_available():
		push_warning("[TerrainHeightmapBuilder] GPU composition unavailable")
		_use_gpu = false
	else:
		print("[TerrainHeightmapBuilder] GPU compositor initialized")
		_use_gpu = true

func _initialize_gpu_feature_evaluator() -> void:
	if not RenderingServer.get_rendering_device():
		return
	_gpu_feature_evaluator = GpuFeatureEvaluator.new()
	if not _gpu_feature_evaluator.is_available():
		_gpu_feature_evaluator = null

## Compose heightmaps from features. Returns Dictionary with "heightmap" and "hole_mask".
func compose(
	features: Array[TerrainFeatureNode],
	contexts: Dictionary,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	base_height: float,
	use_gpu_composition: bool,
	use_multithreading: bool = true,
	max_worker_threads: int = 4
) -> Dictionary:
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
	var pending_tasks := []
	var task_results := {}  # Shared dictionary for worker results
	var gpu_eval_count := 0
	
	# Separate features into: need generation vs cached
	for feature in features:
		if not is_instance_valid(feature) or not feature.is_inside_tree() or not feature.visible:
			if _has_heightmap_cached(feature):
				_remove_cached_heightmap(feature)
			continue
		
		# Check if we need to regenerate this feature's heightmap
		if not _has_heightmap_cached(feature) or feature.is_dirty():
			# Check for mask texture (GPU evaluators can't handle texture masking)
			var has_mask = feature.has_method("has_mask_texture") and feature.has_mask_texture()
			# GPU feature evaluation (limited types and no mask textures)
			if not has_mask and _should_use_gpu(use_gpu_composition) and _gpu_feature_evaluator:
				if feature.has_method("get_gpu_param_pack"):
					var pack = feature.get_gpu_param_pack()
					var gpu_result = _gpu_feature_evaluator.evaluate_single_feature_gpu(resolution, terrain_bounds, pack)
					if gpu_result:
						if feature.has_method("apply_modifiers_to_heightmap"):
							gpu_result = feature.apply_modifiers_to_heightmap(gpu_result, terrain_bounds, contexts.get(feature))
						_store_heightmap(feature, gpu_result)
						gpu_eval_count += 1
						generated_count += 1
						continue
			# Launch parallel generation task (batched) or generate on main thread
			var ctx = contexts.get(feature)
			if use_multithreading and ctx:
				var task_id = WorkerThreadPool.add_task(
					_generate_heightmap_worker.bind(feature, resolution, terrain_bounds, ctx, task_results, _task_mutex)
				)
				parallel_tasks.append({"feature": feature, "task_id": task_id})
				pending_tasks.append({"feature": feature, "task_id": task_id})
				# Batch wait to limit concurrency
				var batch_size = clampi(max_worker_threads, 1, 32)
				if pending_tasks.size() >= batch_size:
					for task in pending_tasks:
						WorkerThreadPool.wait_for_task_completion(task.task_id)
					pending_tasks.clear()
			else:
				# Fallback: generate on main thread (or no context)
				if not ctx:
					push_warning("[TerrainHeightmapBuilder] No context for feature '%s', generating on main thread" % feature.name)
					_store_heightmap(feature, feature.generate_heightmap(resolution, terrain_bounds))
				else:
					_store_heightmap(feature, feature.generate_heightmap_with_context_raw(resolution, terrain_bounds, ctx))
				if is_instance_valid(feature) and feature.has_method("apply_modifiers_to_heightmap"):
					_store_heightmap(feature, feature.apply_modifiers_to_heightmap(
						_get_cached_heightmap(feature),
						terrain_bounds,
						ctx
					))
			generated_count += 1
		else:
			reused_count += 1
	
	# Wait for any remaining parallel tasks to complete
	for task in pending_tasks:
		WorkerThreadPool.wait_for_task_completion(task.task_id)
	
	# Take snapshot of shared results under lock
	_task_mutex.lock()
	var local_results = task_results.duplicate()
	_task_mutex.unlock()
	
	# Retrieve results from snapshot and cache them
	for task in parallel_tasks:
		var feature = task.feature
		if local_results.has(feature):
			var heightmap = local_results[feature]
			var ctx = contexts.get(feature)
			if is_instance_valid(feature) and feature.has_method("apply_modifiers_to_heightmap"):
				heightmap = feature.apply_modifiers_to_heightmap(heightmap, terrain_bounds, ctx)
			_store_heightmap(feature, heightmap)
		else:
			push_error("[TerrainHeightmapBuilder] Failed to generate heightmap for feature '%s'" % feature.name)
	
	var feature_gen_elapsed = Time.get_ticks_msec() - feature_gen_start
	if generated_count > 0:
		print("[TerrainHeightmapBuilder] Feature heightmaps: %d generated (%d GPU, %d CPU), %d cached in %d ms" % [generated_count, gpu_eval_count, generated_count - gpu_eval_count, reused_count, feature_gen_elapsed])
	else:
		print("[TerrainHeightmapBuilder] Feature heightmaps: all %d cached (0 generated)" % reused_count)
	
	# Step 2: Compose all heightmaps
	if _should_use_gpu(use_gpu_composition):
		_last_gpu_param_packs = _collect_gpu_param_packs(features)
		var result = _compose_gpu(features, contexts, resolution, terrain_bounds, base_height)
		if result:
			var total_elapsed = Time.get_ticks_msec() - total_start
			print("[TerrainHeightmapBuilder] Compose total time: %d ms" % total_elapsed)
			return result
		# GPU failed, fall back to CPU
		push_warning("[TerrainHeightmapBuilder] GPU composition failed, falling back to CPU")
	
	var cpu_result = _compose_cpu(features, contexts, resolution, terrain_bounds, base_height, use_gpu_composition)
	var total_elapsed = Time.get_ticks_msec() - total_start
	print("[TerrainHeightmapBuilder] Compose total time: %d ms" % total_elapsed)
	return cpu_result

## Collect GPU parameter packs for validation and future GPU kernels
func _collect_gpu_param_packs(features: Array[TerrainFeatureNode]) -> Array:
	var packs: Array = []
	for feature in features:
		if not is_instance_valid(feature) or not feature.is_inside_tree() or not feature.visible:
			continue
		if not feature.has_method("get_gpu_param_pack"):
			push_warning("[TerrainHeightmapBuilder] Feature '%s' missing GPU parameter pack" % feature.name)
			continue
		var pack = feature.get_gpu_param_pack()
		if not pack.has("version") or pack["version"] != TerrainFeatureNode.GPU_PARAM_VERSION:
			push_warning("[TerrainHeightmapBuilder] GPU param version mismatch for '%s'" % feature.name)
		packs.append(pack)
	return packs

## Check if GPU composition should be used
func _should_use_gpu(user_wants_gpu: bool) -> bool:
	if not user_wants_gpu:
		return false
	if not _use_gpu:
		return false
	if not _gpu_compositor or not _gpu_compositor.is_available():
		return false
	return true

## Compose final heightmap using GPU. Returns Dictionary with "heightmap" and "hole_mask".
func _compose_gpu(
	features: Array[TerrainFeatureNode],
	contexts: Dictionary,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	base_height: float
) -> Dictionary:
	var start_time = Time.get_ticks_msec()
	if not _gpu_compositor or not _gpu_compositor.is_available():
		push_error("[TerrainHeightmapBuilder] GPU compositor not initialized")
		return {}
	
	# Prepare data arrays
	var feature_heightmaps: Array[Image] = []
	var influence_maps: Array[Image] = []
	var blend_modes := PackedInt32Array()
	var strengths := PackedFloat32Array()
	var hole_features: Array = []  # Track hole features separately
	
	var influence_gen_time = 0
	var influence_generated_count = 0
	var influence_cached_count = 0
	
	# Collect valid features
	for feature in features:
		if not _has_heightmap_cached(feature):
			continue
		
		var feature_map = _get_cached_heightmap(feature)
		
		# Validate resolution match
		if feature_map.get_width() != resolution.x or feature_map.get_height() != resolution.y:
			continue
		
		# Check if this is a hole feature
		var is_hole = feature.is_hole_feature()
		if is_hole:
			hole_features.append(feature)
		
		# Check if feature has a mask texture (GPU influence maps don't support textures)
		var has_mask = feature.has_method("has_mask_texture") and feature.has_mask_texture()
		
		# Get or generate cached influence map
		var influence_map: Image
		var cache_key = _get_influence_cache_key(feature)
		
		if _influence_cache.has(feature) and _influence_cache_keys.get(feature) == cache_key:
			influence_map = _influence_cache[feature]
			influence_cached_count += 1
		else:
			var inf_start = Time.get_ticks_msec()
			# Use GPU to generate influence map for better performance (unless masked)
			if has_mask:
				print("[TerrainHeightmapBuilder] Skipping GPU influence map for '%s' — mask textures require CPU path" % feature.name)
			if not has_mask and _gpu_compositor and _gpu_compositor.is_available():
				influence_map = _gpu_compositor.generate_influence_map_gpu(feature, resolution, terrain_bounds)
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
		
		# Hole features don't contribute to heightmap blending, skip in arrays
		if not is_hole:
			feature_heightmaps.append(feature_map)
			influence_maps.append(influence_map)
			blend_modes.append(feature.blend_mode)
			strengths.append(feature.strength)
	
	# If no features (heightmap-contributing), create base height
	var final_heightmap: Image
	if feature_heightmaps.is_empty():
		final_heightmap = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
		final_heightmap.fill(Color(base_height, 0, 0, 1))
	else:
		# Compose on GPU
		final_heightmap = _gpu_compositor.compose_gpu(
			resolution,
			base_height,
			feature_heightmaps,
			influence_maps,
			blend_modes,
			strengths
		)
	
	# Compose hole mask
	var hole_mask = _compose_hole_mask(hole_features, contexts, resolution, terrain_bounds)
	
	var elapsed = Time.get_ticks_msec() - start_time
	if influence_gen_time > 0:
		print("[TerrainHeightmapBuilder] GPU composed %d features in %d ms (%d generated, %d cached, %d ms influence generation)" % [
			feature_heightmaps.size(), elapsed, influence_generated_count, influence_cached_count, influence_gen_time
		])
	else:
		print("[TerrainHeightmapBuilder] GPU composed %d features in %d ms (all %d influence maps cached)" % [
			feature_heightmaps.size(), elapsed, influence_cached_count
		])
	
	return {
		"heightmap": final_heightmap,
		"hole_mask": hole_mask
	}

## Compose final heightmap using CPU. Returns Dictionary with "heightmap" and "hole_mask".
func _compose_cpu(
	features: Array[TerrainFeatureNode],
	contexts: Dictionary,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	base_height: float,
	use_gpu_composition: bool = false
) -> Dictionary:
	var start_time = Time.get_ticks_msec()
	
	# Auto-prefer GPU for large workloads even if user disabled it
	var pixel_count = resolution.x * resolution.y
	if not use_gpu_composition and features.size() > 4 and pixel_count > 128 * 128:
		if _gpu_compositor and _gpu_compositor.is_available():
			push_warning("[TerrainHeightmapBuilder] Large workload detected (%d features, %d pixels), auto-enabling GPU composition" % [features.size(), pixel_count])
			var gpu_result = _compose_gpu(features, contexts, resolution, terrain_bounds, base_height)
			if gpu_result and gpu_result.has("heightmap"):
				return gpu_result
			push_warning("[TerrainHeightmapBuilder] Auto GPU composition failed, falling back to CPU")
	
	# Create base heightmap
	var final_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	final_map.fill(Color(base_height, 0, 0, 1))
	
	# Step 1: Pre-compute all influence maps on main thread (avoids to_local() issues in threads)
	var blend_data = []
	var hole_features: Array = []  # Track hole features separately
	
	for feature in features:
		if not _has_heightmap_cached(feature):
			continue
		
		var feature_map = _get_cached_heightmap(feature)
		
		# Validate resolution match
		if feature_map.get_width() != resolution.x or feature_map.get_height() != resolution.y:
			push_warning("[TerrainHeightmapBuilder] Feature '%s' heightmap size mismatch, skipping" % feature.name)
			continue
		
		# Check if this is a hole feature
		var is_hole = feature.is_hole_feature()
		if is_hole:
			hole_features.append(feature)
			continue  # Holes don't contribute to heightmap blending
		
		# Get or generate cached influence map
		var influence_map: Image
		var cache_key = _get_influence_cache_key(feature)

		if _influence_cache.has(feature) and _influence_cache_keys.get(feature) == cache_key:
			influence_map = _influence_cache[feature]
		else:
			# Try GPU influence generation first when available
			if _gpu_compositor and _gpu_compositor.is_available():
				influence_map = _gpu_compositor.generate_influence_map_gpu(feature, resolution, terrain_bounds)
			
			if not influence_map:
				# Fallback to CPU
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
	
	# Step 2: Blend using optimized byte array operations (if there are non-hole features)
	if not blend_data.is_empty():
		_blend_all_features(final_map, blend_data, resolution)
	
	# Step 3: Compose hole mask
	var hole_mask = _compose_hole_mask(hole_features, contexts, resolution, terrain_bounds)
	
	var elapsed = Time.get_ticks_msec() - start_time
	print("[TerrainHeightmapBuilder] CPU composed %d features in %d ms" % [
		blend_data.size(), elapsed
	])
	
	return {
		"heightmap": final_map,
		"hole_mask": hole_mask
	}

## Blend all features into final map using PackedFloat32Array operations
func _blend_all_features(
	final_map: Image,
	blend_data: Array,
	resolution: Vector2i
) -> void:
	var final_data := final_map.get_data().to_float32_array()
	var width = resolution.x
	var height = resolution.y
	
	# Process each feature
	for data in blend_data:
		var feature_map: Image = data["heightmap"]
		var feature_data := feature_map.get_data().to_float32_array()
		var influence_map: Image = data["influence"]
		var influence_data := influence_map.get_data().to_float32_array()
		var blend_mode: int = data["blend_mode"]
		var strength: float = data["strength"]
		
		# Process all pixels natively
		for i in final_data.size():
			var weight = influence_data[i]
			if weight <= INFLUENCE_WEIGHT_THRESHOLD:
				continue
			
			var feature_h = feature_data[i]
			var current_h = final_data[i]
			var weighted_h = feature_h * weight * strength
			
			match blend_mode:
				TerrainFeatureNode.BlendMode.ADD:
					final_data[i] = current_h + weighted_h
				TerrainFeatureNode.BlendMode.SUBTRACT:
					final_data[i] = current_h - weighted_h
				TerrainFeatureNode.BlendMode.MAX:
					final_data[i] = max(current_h, feature_h * weight)
				TerrainFeatureNode.BlendMode.MIN:
					final_data[i] = min(current_h, feature_h * weight)
				TerrainFeatureNode.BlendMode.MULTIPLY:
					final_data[i] = current_h * (1.0 + weighted_h)
				TerrainFeatureNode.BlendMode.AVERAGE:
					final_data[i] = (current_h + weighted_h) * 0.5
				_:
					final_data[i] = current_h + weighted_h
	
	# Write back once
	final_map.set_data(width, height, false, Image.FORMAT_RF, final_data.to_byte_array())

## Generate influence map for a feature using context (thread-safe)
func _generate_influence_map(
	feature: TerrainFeatureNode,
	context,
	resolution: Vector2i,
	terrain_bounds: Rect2
) -> Image:
	var influence_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	var influence_data := influence_map.get_data().to_float32_array()
	
	var step = terrain_bounds.size / Vector2(resolution - Vector2i.ONE)
	
	for y in range(resolution.y):
		var world_z = terrain_bounds.position.y + (y * step.y)
		for x in range(resolution.x):
			var world_x = terrain_bounds.position.x + (x * step.x)
			var world_pos = Vector3(world_x, 0, world_z)
			
			# Use thread-safe context-based influence calculation
			var weight = feature.get_influence_weight_safe(world_pos, context)
			var pixel_index = y * resolution.x + x
			influence_data[pixel_index] = weight
	
	# Update image with computed data
	influence_map.set_data(resolution.x, resolution.y, false, Image.FORMAT_RF, influence_data.to_byte_array())
	
	return influence_map

## Compose hole mask from hole features. Returns Image where 1.0 = hole, 0.0 = solid.
func _compose_hole_mask(
	hole_features: Array,
	contexts: Dictionary,
	resolution: Vector2i,
	terrain_bounds: Rect2
) -> Image:
	var hole_mask = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	hole_mask.fill(Color(0, 0, 0, 1))  # 0 = solid terrain
	
	if hole_features.is_empty():
		return hole_mask
	
	var hole_mask_data := hole_mask.get_data().to_float32_array()
	var width = resolution.x
	var height = resolution.y
	
	var step = terrain_bounds.size / Vector2(resolution - Vector2i.ONE)
	
	for feature in hole_features:
		if not is_instance_valid(feature):
			continue
		
		var use_3d = feature.get_hole_3d_influence()
		var hole_depth_val = feature.get_hole_depth()
		var cache_key = _get_influence_cache_key(feature)
		cache_key += "_%d_%.0f" % [1 if use_3d else 0, hole_depth_val]
		cache_key += "_hole"
		
		var influence_map: Image
		
		if _influence_cache.has(feature) and _influence_cache_keys.get(feature) == cache_key:
			influence_map = _influence_cache[feature]
		else:
			var ctx = contexts.get(feature)
			if use_3d:
				influence_map = _generate_hole_influence_map_3d(feature, ctx, resolution, terrain_bounds, hole_depth_val)
			else:
				influence_map = _generate_influence_map(feature, ctx, resolution, terrain_bounds)
			_influence_cache[feature] = influence_map
			_influence_cache_keys[feature] = cache_key
		
		var influence_data := influence_map.get_data().to_float32_array()
		var strength = feature.strength
		
		for y in range(height):
			for x in range(width):
				var pixel_index = y * width + x
				
				var influence = influence_data[pixel_index]
				if influence > INFLUENCE_WEIGHT_THRESHOLD:
					var current_hole = hole_mask_data[pixel_index]
					hole_mask_data[pixel_index] = max(current_hole, influence * strength)
	
	hole_mask.set_data(width, height, false, Image.FORMAT_RF, hole_mask_data.to_byte_array())
	return hole_mask

## Generate influence map for holes with 3D rotation support.
## Uses full 3D local coordinates to properly handle rotated holes.
func _generate_hole_influence_map_3d(
	feature: TerrainFeatureNode,
	context,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	hole_depth: float
) -> Image:
	var influence_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	var influence_data := influence_map.get_data().to_float32_array()
	
	var step = terrain_bounds.size / Vector2(resolution - Vector2i.ONE)
	var shape_size = Vector3(feature.influence_size.x, hole_depth, feature.influence_size.y)
	
	for y in range(resolution.y):
		var world_z = terrain_bounds.position.y + (y * step.y)
		for x in range(resolution.x):
			var world_x = terrain_bounds.position.x + (x * step.x)
			var world_pos = Vector3(world_x, 0, world_z)
			
			var weight: float
			if context:
				weight = context.get_influence_weight_3d(world_pos, shape_size)
			else:
				weight = feature.get_influence_weight_safe(world_pos, context)
			
			var pixel_index = y * resolution.x + x
			influence_data[pixel_index] = weight
	
	influence_map.set_data(resolution.x, resolution.y, false, Image.FORMAT_RF, influence_data.to_byte_array())
	return influence_map

## Generate cache key for influence map
func _get_influence_cache_key(feature: TerrainFeatureNode) -> String:
	var pos_rounded = (feature.global_position / CACHE_KEY_POSITION_PRECISION).round() * CACHE_KEY_POSITION_PRECISION
	var size_rounded = (feature.influence_size / CACHE_KEY_POSITION_PRECISION).round() * CACHE_KEY_POSITION_PRECISION
	var falloff_rounded = snappedf(feature.edge_falloff, CACHE_KEY_FALLOFF_PRECISION)
	var rot = feature.global_rotation
	var rot_rounded = "%d_%d_%d" % [
		int(round(rot.x * 100.0)),
		int(round(rot.y * 100.0)),
		int(round(rot.z * 100.0))
	]
	return "%s_%s_%d_%f_%s" % [
		pos_rounded,
		size_rounded,
		int(feature.influence_shape),
		falloff_rounded,
		rot_rounded
	]

## Thread-safe helpers for _heightmap_cache
func _has_heightmap_cached(feature: TerrainFeatureNode) -> bool:
	_cache_mutex.lock()
	var has = _heightmap_cache.has(feature)
	_cache_mutex.unlock()
	return has

func _get_cached_heightmap(feature: TerrainFeatureNode) -> Image:
	_cache_mutex.lock()
	var img = _heightmap_cache.get(feature)
	_cache_mutex.unlock()
	return img

func _store_heightmap(feature: TerrainFeatureNode, heightmap: Image) -> void:
	_cache_mutex.lock()
	_heightmap_cache[feature] = heightmap
	_cache_mutex.unlock()

func _remove_cached_heightmap(feature: TerrainFeatureNode) -> void:
	_cache_mutex.lock()
	_heightmap_cache.erase(feature)
	_cache_mutex.unlock()

## Invalidate heightmap cache for a feature
func invalidate_heightmap(feature: TerrainFeatureNode) -> void:
	_remove_cached_heightmap(feature)

## Invalidate influence cache for a feature
func invalidate_influence(feature: TerrainFeatureNode) -> void:
	if _influence_cache.has(feature):
		_influence_cache.erase(feature)
	if _influence_cache_keys.has(feature):
		_influence_cache_keys.erase(feature)

## Clear all caches
func clear_all_caches() -> void:
	_cache_mutex.lock()
	_heightmap_cache.clear()
	_cache_mutex.unlock()
	_influence_cache.clear()
	_influence_cache_keys.clear()

## Worker thread function for parallel heightmap generation
## Writes result to shared dictionary instead of returning (WorkerThreadPool limitation with complex objects)
func _generate_heightmap_worker(
	feature: TerrainFeatureNode,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	context,
	results: Dictionary,
	mutex: Mutex
) -> void:
	var heightmap = feature.generate_heightmap_with_context_raw(resolution, terrain_bounds, context)
	mutex.lock()
	results[feature] = heightmap
	mutex.unlock()

## Cleanup GPU resources
func cleanup() -> void:
	if _gpu_compositor:
		_gpu_compositor.cleanup()
		_gpu_compositor = null
	if _gpu_feature_evaluator:
		_gpu_feature_evaluator.cleanup()
		_gpu_feature_evaluator = null
