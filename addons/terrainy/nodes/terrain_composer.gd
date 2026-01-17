@tool
class_name TerrainComposer
extends Node3D

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")
const TerrainTextureLayer = preload("res://addons/terrainy/resources/terrain_texture_layer.gd")
const TerrainMeshGenerator = preload("res://addons/terrainy/nodes/terrain_mesh_generator.gd")

## Main terrain composer that blends all TerrainFeatureNodes and generates final mesh

signal terrain_updated
signal texture_layers_changed
signal generation_progress(stage: String, progress: float) 

@export var terrain_size: Vector2 = Vector2(100, 100):
	set(value):
		terrain_size = value
		_request_update("terrain_size")

@export var resolution: int = 128:
	set(value):
		resolution = clamp(value, 16, 1024)
		_request_update("resolution")

@export var base_height: float = 0.0:
	set(value):
		base_height = value
		_request_update("base_height")

@export var auto_update: bool = true

@export_group("Performance")
@export var update_debounce_time: float = 0.3:
	set(value):
		update_debounce_time = max(0.0, value)

@export var use_parallel_processing: bool = true
@export var batch_size: int = 64:
	set(value):
		batch_size = clamp(value, 16, 256)

@export var use_chunked_generation: bool = false
@export var chunk_size: int = 32:
	set(value):
		chunk_size = clamp(value, 8, 128)

@export var use_threaded_generation: bool = true

@export_group("Optimization")
@export var use_parallel_height_calculation: bool = true
@export var max_height_threads: int = 8:
	set(value):
		max_height_threads = clamp(value, 1, 16)

@export var use_height_cache: bool = true:
	set(value):
		use_height_cache = value
		if not value:
			_height_cache_valid = false

@export var use_partial_updates: bool = true:
	set(value):
		use_partial_updates = value
		if not value:
			_dirty_regions.clear()
			_full_rebuild_needed = true

@export var show_optimization_stats: bool = false

@export_group("Material")
@export var terrain_material: Material

@export_group("Texture Layers")
## Array of texture layers for terrain rendering
@export var texture_layers: Array[TerrainTextureLayer] = []:
	set(value):
		# Disconnect old layer signals
		for layer in texture_layers:
			if is_instance_valid(layer) and layer.layer_changed.is_connected(_on_texture_layer_changed):
				layer.layer_changed.disconnect(_on_texture_layer_changed)
		
		texture_layers = value
		
		# Connect new layer signals
		for layer in texture_layers:
			if is_instance_valid(layer) and not layer.layer_changed.is_connected(_on_texture_layer_changed):
				layer.layer_changed.connect(_on_texture_layer_changed)
		
		_update_material()
		texture_layers_changed.emit()

@export_group("Collision")
@export var generate_collision: bool = true:
	set(value):
		generate_collision = value
		_update_collision()

var _mesh_instance: MeshInstance3D
var _static_body: StaticBody3D
var _collision_shape: CollisionShape3D
var _update_queued: bool = false
var _debounce_timer: float = 0.0
var _feature_nodes: Array[TerrainFeatureNode] = []
var _initialized: bool = false
var _shader_material: ShaderMaterial
var _texture_arrays_dirty: bool = false
var _generation_thread: Thread = null
var _is_generating: bool = false

# Optimization: Height cache and dirty regions
var _height_cache: PackedFloat32Array = []
var _height_cache_valid: bool = false
var _dirty_regions: Array[Rect2] = []
var _full_rebuild_needed: bool = true
var _cached_resolution: int = 0
var _cached_terrain_size: Vector2 = Vector2.ZERO
var _is_building_cache: bool = false

# Optimization: Update queue and cancellation
var _update_queue: Array[Dictionary] = []
var _cancel_current_generation: bool = false
var _last_update_id: int = 0

func _enter_tree() -> void:
	if Engine.is_editor_hint() and not _initialized:
		# Initialize and generate mesh when first entering the tree
		call_deferred("_initialize_and_generate")

func _exit_tree() -> void:
	# Clean up any running threads
	if _generation_thread and _generation_thread.is_alive():
		_generation_thread.wait_to_finish()
		_generation_thread = null

func _initialize_and_generate() -> void:
	if _initialized:
		return
	_initialized = true
	
	# Ensure mesh instance exists
	if not _mesh_instance:
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)
	
	# Generate initial mesh
	_scan_for_features()
	_update_terrain()

func _ready() -> void:
	if not _mesh_instance:
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)
	
	if not _static_body:
		_static_body = StaticBody3D.new()
		add_child(_static_body)
		_static_body.name = "CollisionBody"
	
	if not _collision_shape:
		_collision_shape = CollisionShape3D.new()
		_static_body.add_child(_collision_shape)
		_collision_shape.name = "CollisionShape"
	
	_scan_for_features()
	_connect_feature_signals()
	
	if Engine.is_editor_hint():
		if not child_entered_tree.is_connected(_on_child_changed):
			child_entered_tree.connect(_on_child_changed)
		if not child_exiting_tree.is_connected(_on_child_changed):
			child_exiting_tree.connect(_on_child_changed)
	
	set_process(false)
	_request_update()

func _scan_for_features() -> void:
	# Disconnect old signals before clearing
	for feature in _feature_nodes:
		if is_instance_valid(feature):
			# Disconnect all connections to avoid duplicate signals
			while feature.parameters_changed.is_connected(_on_feature_changed):
				feature.parameters_changed.disconnect(_on_feature_changed)
	
	_feature_nodes.clear()
	_scan_node_recursive(self)

func _scan_node_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is TerrainFeatureNode and child != _mesh_instance and child != _static_body:
			_feature_nodes.append(child)
			# Recursively scan children of this feature node
			_scan_node_recursive(child)
		elif not (child is MeshInstance3D or child is StaticBody3D or child is CollisionShape3D):
			# Don't scan internal nodes, but do scan other containers
			_scan_node_recursive(child)

func _connect_feature_signals() -> void:
	for feature in _feature_nodes:
		if is_instance_valid(feature):
			# Disconnect all existing connections from this feature to our handler
			# We need to disconnect from this composer's method, not from the feature
			while feature.parameters_changed.is_connected(_on_feature_changed):
				feature.parameters_changed.disconnect(_on_feature_changed)
			
			# Connect once (use a lambda to capture the feature)
			feature.parameters_changed.connect(func(): _on_feature_changed(feature), CONNECT_DEFERRED)
			
			if show_optimization_stats:
				print("[TerrainComposer] Connected signal for feature: %s" % feature.name)

func _on_child_changed(node: Node) -> void:
	# Defer to avoid issues during node deletion
	call_deferred("_rescan_features")

func _rescan_features() -> void:
	_scan_for_features()
	_connect_feature_signals()
	_request_update("full_rebuild")

func _on_feature_changed(feature: TerrainFeatureNode = null) -> void:
	if show_optimization_stats:
		print("[TerrainComposer] Feature changed: %s" % (feature.name if feature else "unknown"))
	_request_update("feature", feature)

func _on_texture_layer_changed() -> void:
	_update_material()

func _request_update(property_changed: String = "", affected_feature: TerrainFeatureNode = null) -> void:
	if not auto_update:
		if show_optimization_stats:
			print("[TerrainComposer] Update skipped - auto_update is false")
		return
	
	# Mark dirty regions based on what changed (always do this, even if update already queued)
	_mark_dirty_region(property_changed, affected_feature)
	
	if show_optimization_stats:
		print("[TerrainComposer] Update requested for property: %s (queued: %s)" % [property_changed, _update_queued])
	
	# Queue the update if not already queued
	if not _update_queued:
		_update_queued = true
		_debounce_timer = update_debounce_time
		set_process(true)
		if show_optimization_stats:
			print("[TerrainComposer] Processing enabled, debounce: %.2f" % _debounce_timer)
	else:
		# Reset debounce timer to batch multiple changes
		_debounce_timer = update_debounce_time
		# Ensure processing is still enabled
		if not is_processing():
			set_process(true)
			if show_optimization_stats:
				print("[TerrainComposer] Re-enabled processing")

## Mark regions of the terrain that need to be recalculated
func _mark_dirty_region(property_changed: String, affected_feature: TerrainFeatureNode = null) -> void:
	# Check if this requires a full rebuild
	if property_changed in ["terrain_size", "resolution", "full_rebuild"]:
		_full_rebuild_needed = true
		_dirty_regions.clear()
		_height_cache_valid = false
		return
	
	# Global properties that affect all heights but can use cached mesh topology
	if property_changed in ["base_height"]:
		# Mark entire terrain as dirty but keep topology
		_add_dirty_region(Rect2(Vector2.ZERO, terrain_size))
		return
	
	# Feature-specific changes - mark only the influenced area
	if property_changed == "feature" and affected_feature:
		var feature_rect = _get_feature_influence_rect(affected_feature)
		_add_dirty_region(feature_rect)
		return
	
	# Unknown change - full rebuild to be safe
	_full_rebuild_needed = true
	_dirty_regions.clear()

## Get the world-space rectangle influenced by a feature
func _get_feature_influence_rect(feature: TerrainFeatureNode) -> Rect2:
	if not is_instance_valid(feature) or not feature.is_inside_tree():
		return Rect2()
	
	var feature_pos = feature.global_position
	var local_pos = to_local(feature_pos)
	var size = feature.influence_size
	
	# Add some padding for edge falloff
	var padding = size * feature.edge_falloff
	var expanded_size = size + padding * 2.0
	
	# Convert to terrain-local coordinates
	var half_size = terrain_size / 2.0
	var rect = Rect2(
		Vector2(local_pos.x, local_pos.z) - expanded_size / 2.0 + half_size,
		expanded_size
	)
	
	return rect

## Add a dirty region, merging with existing regions if they overlap
func _add_dirty_region(rect: Rect2) -> void:
	if rect.get_area() <= 0:
		return
	
	# Clamp to terrain bounds
	var terrain_rect = Rect2(Vector2.ZERO, terrain_size)
	rect = rect.intersection(terrain_rect)
	
	if rect.get_area() <= 0:
		return
	
	# Try to merge with existing dirty regions
	var merged = false
	for i in range(_dirty_regions.size()):
		if _dirty_regions[i].intersects(rect) or _dirty_regions[i].encloses(rect):
			_dirty_regions[i] = _dirty_regions[i].merge(rect)
			merged = true
			break
	
	if not merged:
		_dirty_regions.append(rect)
	
	# If we have too many dirty regions, just do a full update
	if _dirty_regions.size() > 10:
		_full_rebuild_needed = true
		_dirty_regions.clear()

func _process(delta: float) -> void:
	if _update_queued:
		_debounce_timer -= delta		
		if _debounce_timer <= 0.0:
			_update_queued = false
			_debounce_timer = 0.0
			
			if show_optimization_stats:
				print("[TerrainComposer] Debounce complete, starting update...")
			
			# Cancel any ongoing generation before starting new one
			if _is_generating:
				_cancel_current_generation = true
				if show_optimization_stats:
					print("[TerrainComposer] Canceling previous generation...")
			
			_update_terrain()
	elif _is_generating:
		# Check if thread has finished
		if _generation_thread and not _generation_thread.is_alive():
			var mesh = _generation_thread.wait_to_finish()
			_generation_thread = null
			_is_generating = false
			
			if mesh and not _cancel_current_generation:
				if show_optimization_stats:
					print("[TerrainComposer] Thread completed, applying mesh...")
				if _mesh_instance:
					_mesh_instance.mesh = mesh
					_update_material()
				
				# Defer collision to prevent blocking
				call_deferred("_update_collision")
				terrain_updated.emit()
				if show_optimization_stats:
					print("[TerrainComposer] Mesh applied successfully")
			else:
				if _cancel_current_generation:
					if show_optimization_stats:
						print("[TerrainComposer] Generation was canceled")
					_cancel_current_generation = false
				set_process(false)
	else:
		set_process(false)

## Manually trigger terrain regeneration
func rebuild_terrain() -> void:
	_update_queued = false
	_debounce_timer = 0.0
	_full_rebuild_needed = true
	_dirty_regions.clear()
	set_process(false)
	_update_terrain()

func _update_terrain() -> void:
	# Prevent concurrent updates
	if _is_generating:
		if show_optimization_stats:
			print("[TerrainComposer] Update blocked - generation already in progress")
		return
	
	# Decide whether to do full rebuild or partial update
	if not use_partial_updates or _full_rebuild_needed or not _height_cache_valid:
		_update_terrain_full()
	elif not _dirty_regions.is_empty():
		_update_terrain_partial()
	else:
		# Nothing to do
		return

func _update_terrain_full() -> void:
	if show_optimization_stats:
		print("[TerrainComposer] Full terrain rebuild...")
	_full_rebuild_needed = false
	_dirty_regions.clear()
	
	if use_threaded_generation:
		_update_terrain_threaded()
	else:
		_update_terrain_immediate()

func _update_terrain_partial() -> void:
	if show_optimization_stats:
		print("[TerrainComposer] Partial terrain update (%d dirty regions)..." % _dirty_regions.size())
		for i in range(_dirty_regions.size()):
			var r = _dirty_regions[i]
			print("  Region %d: pos=(%.1f, %.1f) size=(%.1f, %.1f)" % [i, r.position.x, r.position.y, r.size.x, r.size.y])
	
	# For now, partial updates use immediate mode (can't easily thread partial updates)
	_update_terrain_partial_immediate()

func _update_terrain_partial_immediate() -> void:
	if not _mesh_instance or not _mesh_instance.mesh:
		# No existing mesh - do full rebuild
		if show_optimization_stats:
			print("[TerrainComposer] No existing mesh - doing full rebuild")
		_full_rebuild_needed = true
		_update_terrain_full()
		return
	
	var mesh = await _update_dirty_regions_in_mesh()
	
	if mesh:
		_mesh_instance.mesh = mesh
		_update_material()
		call_deferred("_update_collision")
		terrain_updated.emit()
		
		if show_optimization_stats:
			print("[TerrainComposer] Partial update complete - mesh applied")
	else:
		if show_optimization_stats:
			print("[TerrainComposer] Partial update failed - no mesh generated")
		
	_dirty_regions.clear()

func _update_terrain_immediate() -> void:
	_is_generating = true
	
	if show_optimization_stats:
		print("[TerrainComposer] Immediate update - use_height_cache: %s" % use_height_cache)
	
	# Build/update height cache first if enabled
	if use_height_cache:
		await _build_height_cache()
		var mesh = await _generate_terrain_mesh_from_cache()
		
		if _mesh_instance:
			_mesh_instance.mesh = mesh
			_update_material()
	else:
		# Legacy path without caching
		var mesh = await _generate_terrain_mesh()
		if _mesh_instance:
			_mesh_instance.mesh = mesh
			_update_material()
	
	# Defer collision to next frame to keep responsive
	call_deferred("_update_collision")
	terrain_updated.emit()
	_is_generating = false

func _update_terrain_threaded() -> void:
	# Don't start a new generation if one is already running
	if _is_generating:
		print("[TerrainComposer] Generation already in progress, skipping...")
		return
	
	# Threading with feature nodes requires pre-calculating heights
	# Since feature nodes use to_local() which can't be called from threads,
	# we fall back to async immediate mode if features are present
	if not _feature_nodes.is_empty():
		print("[TerrainComposer] Features detected - using async immediate mode (threading not supported with feature nodes)")
		_update_terrain_immediate()
		return
	
	# Wait for previous thread to finish
	if _generation_thread and _generation_thread.is_alive():
		_generation_thread.wait_to_finish()
	
	print("[TerrainComposer] Starting threaded mesh generation...")
	_is_generating = true
	
	# Create new thread for generation
	_generation_thread = Thread.new()
	_generation_thread.start(_generate_mesh_on_thread)
	
	# Poll for completion in _process
	set_process(true)

func _update_collision() -> void:
	if not _collision_shape or not _mesh_instance:
		return
	
	if generate_collision and _mesh_instance.mesh:
		_static_body.visible = true
		var shape = _mesh_instance.mesh.create_trimesh_shape()
		_collision_shape.shape = shape
	else:
		_static_body.visible = false
		_collision_shape.shape = null

func _generate_terrain_mesh() -> ArrayMesh:
	# Create a callback for height calculation that uses the correct world position
	var height_callback = func(local_pos: Vector3) -> float:
		var world_pos = to_global(local_pos)
		return _calculate_height_at(world_pos)
	
	var scene_tree = get_tree()
	
	if use_chunked_generation:
		return await TerrainMeshGenerator.generate_chunked(
			resolution,
			terrain_size,
			chunk_size,
			batch_size,
			use_parallel_processing,
			height_callback,
			scene_tree
		)
	else:
		return await TerrainMeshGenerator.generate_batched(
			resolution,
			terrain_size,
			batch_size,
			use_parallel_processing,
			height_callback,
			scene_tree
		)

func _generate_mesh_on_thread() -> ArrayMesh:
	# This runs on a worker thread for simple terrains without feature nodes
	# Note: Can't use async/await in threads, so scene_tree is null (no yielding)
	var thread_base_height = base_height
	
	var height_callback = func(local_pos: Vector3) -> float:
		return thread_base_height
	
	# Generate mesh using the thread-safe callback (no scene_tree = no yielding)
	if use_chunked_generation:
		return await TerrainMeshGenerator.generate_chunked(
			resolution,
			terrain_size,
			chunk_size,
			batch_size,
			use_parallel_processing,
			height_callback,
			null  # No scene_tree on worker thread
		)
	else:
		return await TerrainMeshGenerator.generate_batched(
			resolution,
			terrain_size,
			batch_size,
			use_parallel_processing,
			height_callback,
			null  # No scene_tree on worker thread
		)

## Pre-capture all feature node data on the main thread for thread-safe processing
## Note: Currently unused - threading falls back to immediate mode when features are present
func _capture_feature_data() -> Array:
	var feature_data = []
	
	for feature in _feature_nodes:
		if not is_instance_valid(feature):
			continue
		
		# Create a thread-safe wrapper that captures the height calculation
		# without node dependencies
		var feature_copy = feature  # Capture in closure
		var height_func = func(world_pos: Vector3) -> float:
			# This will be called from main thread during capture to create lookup
			var height = feature_copy.get_height_at(world_pos)
			# Apply modifiers
			if feature_copy.has_method("_apply_modifiers"):
				height = feature_copy._apply_modifiers(world_pos, height)
			return height
		
		# Capture all data we need from this feature node
		var data = {
			"visible": feature.visible,
			"global_transform": feature.global_transform,
			"inverse_transform": feature.global_transform.affine_inverse(),
			"influence_size": feature.influence_size,
			"influence_shape": feature.influence_shape,
			"edge_falloff": feature.edge_falloff,
			"strength": feature.strength,
			"blend_mode": feature.blend_mode,
			"height_func": height_func
		}
		
		feature_data.append(data)
	
	print("[TerrainComposer] Captured data from %d features" % feature_data.size())
	return feature_data

## Initialize or update the height cache
func _build_height_cache() -> void:
	# Prevent concurrent cache building
	if _is_building_cache:
		if show_optimization_stats:
			print("[TerrainComposer] Cache build already in progress, waiting...")
		while _is_building_cache:
			await get_tree().process_frame
		return
	
	_is_building_cache = true
	var cache_start_time = Time.get_ticks_msec()
	
	var total_points = (resolution + 1) * (resolution + 1)
	
	# Check if we need to resize the cache
	if _height_cache.size() != total_points or _cached_resolution != resolution or _cached_terrain_size != terrain_size:
		_height_cache.resize(total_points)
		_cached_resolution = resolution
		_cached_terrain_size = terrain_size
	
	var step = terrain_size / float(resolution)
	var half_size = terrain_size / 2.0
	
	# Pre-filter active features
	var active_features: Array = []
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.is_inside_tree() and feature.visible:
			active_features.append(feature)
	
	if show_optimization_stats:
		print("[TerrainComposer] Building height cache with %d active features..." % active_features.size())
	
	# Pre-calculate feature influence data for thread-safe processing
	# Capture ALL transform and node data on main thread
	var feature_data: Array[Dictionary] = []
	for feature in active_features:
		var max_influence = max(feature.influence_size.x, feature.influence_size.y)
		
		# Capture transform data (can't call to_local in threads)
		var inverse_transform = feature.global_transform.affine_inverse()
		
		# Capture all feature parameters that might need node access
		var data = {
			"feature": feature,  # Keep reference for main-thread calls
			"position": feature.global_position,
			"inverse_transform": inverse_transform,  # For thread-safe to_local
			"max_influence_sq": max_influence * max_influence * 1.5,
			"influence_size": feature.influence_size,
			"influence_shape": feature.influence_shape,
			"edge_falloff": feature.edge_falloff,
			"strength": feature.strength,
			"blend_mode": feature.blend_mode,
			# Capture modifier flags (check if property exists first)
			"enable_smoothing": feature.enable_smoothing if "enable_smoothing" in feature else false,
			"enable_min_clamp": feature.enable_min_clamp if "enable_min_clamp" in feature else false,
			"enable_max_clamp": feature.enable_max_clamp if "enable_max_clamp" in feature else false,
			"min_height": feature.min_height if "min_height" in feature else 0.0,
			"max_height": feature.max_height if "max_height" in feature else 100.0
		}
		
		feature_data.append(data)
	
	# Choose parallel or sequential height calculation
	if show_optimization_stats:
		print("[TerrainComposer] Parallel enabled: %s, Active features: %d" % [use_parallel_height_calculation, active_features.size()])
	
	if use_parallel_height_calculation and active_features.size() > 0:
		await _build_heights_parallel(feature_data, step, half_size, total_points)
	else:
		if show_optimization_stats:
			print("[TerrainComposer] Using sequential (parallel: %s, features: %d)" % [use_parallel_height_calculation, active_features.size()])
		await _build_heights_sequential(feature_data, step, half_size, total_points)
	
	_height_cache_valid = true
	_is_building_cache = false
	
	if show_optimization_stats:
		var elapsed = Time.get_ticks_msec() - cache_start_time
		print("[TerrainComposer] Height cache built (%d points) in %d ms (%.2f ms/1000 points)" % [
			total_points, elapsed, (elapsed * 1000.0) / total_points
		])

## Parallel height calculation using WorkerThreadPool
func _build_heights_parallel(feature_data: Array[Dictionary], step: Vector2, half_size: Vector2, total_points: int) -> void:
	# Split work into batches that can be processed in parallel
	var num_threads = min(OS.get_processor_count(), max_height_threads)
	var batch_size = ceili(float(total_points) / num_threads)
	
	if show_optimization_stats:
		print("[TerrainComposer] Using %d parallel threads (batch size: %d)" % [num_threads, batch_size])
	
	# Capture transform data for threads (can't call to_global in threads)
	var global_transform_captured = global_transform
	
	# Create tasks for parallel height calculation
	var tasks: Array = []
	for thread_id in range(num_threads):
		var start_idx = thread_id * batch_size
		var end_idx = min(start_idx + batch_size, total_points)
		
		if start_idx >= total_points:
			break
		
		# Create a worker function that calculates heights for this batch
		var worker = func():
			for idx in range(start_idx, end_idx):
				var z = idx / (resolution + 1)
				var x = idx % (resolution + 1)
				
				var local_x = (x * step.x) - half_size.x
				var local_z = (z * step.y) - half_size.y
				var local_pos = Vector3(local_x, 0, local_z)
				var world_pos = global_transform_captured * local_pos
				
				# Calculate height using thread-safe pre-captured data
				var height = base_height
				for data in feature_data:
					# Spatial culling with cached position
					var dist_sq = world_pos.distance_squared_to(data.position)
					if dist_sq > data.max_influence_sq:
						continue
					
					# Thread-safe influence weight calculation using pre-captured transform
					var feature_local_pos = data.inverse_transform * world_pos
					var feature_local_2d = Vector2(feature_local_pos.x, feature_local_pos.z)
					
					var distance: float
					var max_distance: float
					
					# Calculate influence based on shape (thread-safe - no node access)
					match data.influence_shape:
						0: # CIRCLE
							distance = feature_local_2d.length()
							max_distance = data.influence_size.x
						1: # RECTANGLE
							var normalized = Vector2(
								abs(feature_local_2d.x) / data.influence_size.x,
								abs(feature_local_2d.y) / data.influence_size.y
							)
							distance = max(normalized.x, normalized.y)
							max_distance = 1.0
						_:
							distance = feature_local_2d.length()
							max_distance = data.influence_size.x
					
					# Calculate weight with falloff
					if distance > max_distance:
						continue
					
					var weight = 1.0
					var falloff_start = max_distance * (1.0 - data.edge_falloff)
					if distance > falloff_start and data.edge_falloff > 0.0:
						var falloff_distance = distance - falloff_start
						var falloff_range = max_distance - falloff_start
						weight = 1.0 - smoothstep(0.0, falloff_range, falloff_distance)
					
					if weight <= 0.001:
						continue
					
					# Get height using thread-safe method with pre-computed local position
					var feature = data.feature
					var h = feature.get_height_at_safe(world_pos, feature_local_pos)
					
					# Apply modifiers using cached data (thread-safe)
					if data.enable_min_clamp:
						h = max(h, data.min_height)
					if data.enable_max_clamp:
						h = min(h, data.max_height)
					
					var weighted_h = h * weight * data.strength
					
					match data.blend_mode:
						0: height += weighted_h
						1: height = max(height, weighted_h)
						2: height = min(height, weighted_h)
						3: height *= (1.0 + weighted_h)
						4: height += weighted_h
				
				_height_cache[idx] = height
		
		var task_id = WorkerThreadPool.add_task(worker)
		tasks.append(task_id)
	
	# Wait for all tasks to complete with progress updates
	var completed = 0
	var last_progress = 0
	while completed < tasks.size():
		await get_tree().process_frame
		var new_completed = 0
		for task_id in tasks:
			if WorkerThreadPool.is_task_completed(task_id):
				new_completed += 1
		
		if new_completed > completed:
			completed = new_completed
			var progress = int((completed * 100.0) / tasks.size())
			if show_optimization_stats and progress != last_progress and progress % 25 == 0:
				print("  Threads completed: %d/%d (%d%%)" % [completed, tasks.size(), progress])
				last_progress = progress
	
	# Ensure all tasks are finished
	for task_id in tasks:
		WorkerThreadPool.wait_for_task_completion(task_id)

## Sequential height calculation (fallback)
func _build_heights_sequential(feature_data: Array[Dictionary], step: Vector2, half_size: Vector2, total_points: int) -> void:
	var yield_frequency = 16384
	var index = 0
	
	if show_optimization_stats:
		print("[TerrainComposer] Using sequential calculation (parallel disabled)")
	
	for z in range(resolution + 1):
		for x in range(resolution + 1):
			var local_x = (x * step.x) - half_size.x
			var local_z = (z * step.y) - half_size.y
			var world_pos = to_global(Vector3(local_x, 0, local_z))
			
			_height_cache[index] = _calculate_height_at_cached(world_pos, feature_data)
			index += 1
			
			if index % yield_frequency == 0:
				if show_optimization_stats:
					print("  Progress: %.1f%%" % ((index * 100.0) / total_points))
				await get_tree().process_frame

## Update only the heights in dirty regions
func _update_dirty_regions_in_cache() -> void:
	if _dirty_regions.is_empty():
		return
	
	var start_time = Time.get_ticks_msec()
	var step = terrain_size / float(resolution)
	var half_size = terrain_size / 2.0
	var updated_count = 0
	
	for dirty_rect in _dirty_regions:
		# Convert world rect to grid coordinates
		var min_x = int(floor((dirty_rect.position.x) / step.x))
		var max_x = int(ceil((dirty_rect.position.x + dirty_rect.size.x) / step.x))
		var min_z = int(floor((dirty_rect.position.y) / step.y))
		var max_z = int(ceil((dirty_rect.position.y + dirty_rect.size.y) / step.y))
		
		# Clamp to valid range
		min_x = clampi(min_x, 0, resolution)
		max_x = clampi(max_x, 0, resolution)
		min_z = clampi(min_z, 0, resolution)
		max_z = clampi(max_z, 0, resolution)
		
		# Update heights in this region
		for z in range(min_z, max_z + 1):
			for x in range(min_x, max_x + 1):
				var local_x = (x * step.x) - half_size.x
				var local_z = (z * step.y) - half_size.y
				var world_pos = to_global(Vector3(local_x, 0, local_z))
				
				var index = z * (resolution + 1) + x
				_height_cache[index] = _calculate_height_at(world_pos)
				updated_count += 1
	
	if show_optimization_stats:
		var elapsed = Time.get_ticks_msec() - start_time
		print("[TerrainComposer] Updated %d cached heights in %d ms" % [updated_count, elapsed])

## Update mesh using dirty regions (partial update)
func _update_dirty_regions_in_mesh() -> ArrayMesh:
	# First update the height cache for dirty regions
	if not _height_cache_valid:
		await _build_height_cache()
	else:
		await _update_dirty_regions_in_cache()
	
	# Now rebuild the mesh from the cache (fast path - no yielding)
	var mesh = await _generate_terrain_mesh_from_cache_fast()
	return mesh

## Fast mesh generation without yielding (for partial updates)
func _generate_terrain_mesh_from_cache_fast() -> ArrayMesh:
	if not _height_cache_valid or _height_cache.is_empty():
		return await _generate_terrain_mesh()
	
	var start_time = Time.get_ticks_msec()
	
	var vertices: PackedVector3Array = []
	var normals: PackedVector3Array = []
	var uvs: PackedVector2Array = []
	var indices: PackedInt32Array = []
	
	var step = terrain_size / float(resolution)
	var half_size = terrain_size / 2.0
	var total_vertices = (resolution + 1) * (resolution + 1)
	
	# Pre-allocate arrays
	vertices.resize(total_vertices)
	uvs.resize(total_vertices)
	normals.resize(total_vertices)
	
	# Build vertices from cache
	var vertex_index = 0
	for z in range(resolution + 1):
		for x in range(resolution + 1):
			var local_x = (x * step.x) - half_size.x
			var local_z = (z * step.y) - half_size.y
			
			var cache_index = z * (resolution + 1) + x
			var height = _height_cache[cache_index]
			
			vertices[vertex_index] = Vector3(local_x, height, local_z)
			uvs[vertex_index] = Vector2(x / float(resolution), z / float(resolution))
			vertex_index += 1
	
	# Generate indices
	indices.resize(resolution * resolution * 6)
	var idx = 0
	for z in range(resolution):
		for x in range(resolution):
			var i = z * (resolution + 1) + x
			
			indices[idx] = i
			indices[idx + 1] = i + 1
			indices[idx + 2] = i + resolution + 1
			indices[idx + 3] = i + 1
			indices[idx + 4] = i + resolution + 2
			indices[idx + 5] = i + resolution + 1
			idx += 6
	
	# Fast normal calculation without yielding
	var vertex_time = Time.get_ticks_msec() - start_time
	if show_optimization_stats:
		print("[TerrainComposer] Vertices built in %d ms, calculating normals..." % vertex_time)
	
	# Initialize normals to zero
	for i in range(normals.size()):
		normals[i] = Vector3.ZERO
	
	# Accumulate normals from triangles
	for i in range(0, indices.size(), 3):
		var i0 = indices[i]
		var i1 = indices[i + 1]
		var i2 = indices[i + 2]
		
		var v0 = vertices[i0]
		var v1 = vertices[i1]
		var v2 = vertices[i2]
		
		var edge1 = v1 - v0
		var edge2 = v2 - v0
		var normal = edge1.cross(edge2)
		
		normals[i0] += normal
		normals[i1] += normal
		normals[i2] += normal
	
	# Normalize all normals
	for i in range(normals.size()):
		normals[i] = normals[i].normalized()
	
	# Create mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var array_mesh = ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	if show_optimization_stats:
		var elapsed = Time.get_ticks_msec() - start_time
		print("[TerrainComposer] Fast mesh built in %d ms (normals: %d ms)" % [elapsed, elapsed - vertex_time])
	
	return array_mesh

## Generate mesh from the height cache
func _generate_terrain_mesh_from_cache() -> ArrayMesh:
	if not _height_cache_valid or _height_cache.is_empty():
		# Fallback to regular generation
		return await _generate_terrain_mesh()
	
	var start_time = Time.get_ticks_msec()
	
	var vertices: PackedVector3Array = []
	var normals: PackedVector3Array = []
	var uvs: PackedVector2Array = []
	var indices: PackedInt32Array = []
	
	var step = terrain_size / float(resolution)
	var half_size = terrain_size / 2.0
	var total_vertices = (resolution + 1) * (resolution + 1)
	
	# Pre-allocate arrays
	vertices.resize(total_vertices)
	uvs.resize(total_vertices)
	
	# Build vertices from cache (this is fast - just copying from cache)
	var vertex_index = 0
	for z in range(resolution + 1):
		for x in range(resolution + 1):
			var local_x = (x * step.x) - half_size.x
			var local_z = (z * step.y) - half_size.y
			
			var cache_index = z * (resolution + 1) + x
			var height = _height_cache[cache_index]
			
			vertices[vertex_index] = Vector3(local_x, height, local_z)
			uvs[vertex_index] = Vector2(x / float(resolution), z / float(resolution))
			vertex_index += 1
	
	# Generate indices (always the same, could be cached too)
	for z in range(resolution):
		for x in range(resolution):
			var i = z * (resolution + 1) + x
			
			indices.append(i)
			indices.append(i + 1)
			indices.append(i + resolution + 1)
			
			indices.append(i + 1)
			indices.append(i + resolution + 2)
			indices.append(i + resolution + 1)
	
	# Calculate normals (this is the slow part)
	normals = await TerrainMeshGenerator.calculate_normals_batched(vertices, indices, batch_size, get_tree())
	
	# Create mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var array_mesh = ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	if show_optimization_stats:
		var elapsed = Time.get_ticks_msec() - start_time
		print("[TerrainComposer] Mesh built from cache in %d ms" % elapsed)
	
	return array_mesh

func _calculate_height_at(world_pos: Vector3) -> float:
	var final_height = base_height
	var total_weight = 0.0
	var weighted_heights: Array[Dictionary] = []
	
	# Collect all feature contributions with early rejection
	for feature in _feature_nodes:
		if not is_instance_valid(feature) or not feature.is_inside_tree() or not feature.visible:
			continue
		
		# Quick distance check before expensive influence calculation
		var feature_pos = feature.global_position
		var dist_sq = world_pos.distance_squared_to(feature_pos)
		var max_influence = max(feature.influence_size.x, feature.influence_size.y)
		var max_influence_sq = max_influence * max_influence * 1.5  # Add margin
		
		# Skip if definitely outside influence range
		if dist_sq > max_influence_sq:
			continue
		
		var weight = feature.get_influence_weight(world_pos)
		if weight > 0.001:
			var height = feature.get_height_at(world_pos)
			# Apply modifiers to the height
			if feature.has_method("_apply_modifiers"):
				height = feature._apply_modifiers(world_pos, height)
			weighted_heights.append({
				"height": height,
				"weight": weight * feature.strength,
				"mode": feature.blend_mode
			})
			total_weight += weight * feature.strength
	
	# Blend all features
	if weighted_heights.is_empty():
		return final_height
	
	# Sort by blend mode for proper layering
	# For now, simple blending
	for data in weighted_heights:
		match data.mode:
			0: # Add
				final_height += data.height * data.weight
			1: # Max
				final_height = max(final_height, data.height * data.weight)
			2: # Min
				final_height = min(final_height, data.height * data.weight)
			3: # Multiply
				final_height *= (1.0 + data.height * data.weight)
			4: # Average
				final_height += data.height * data.weight
	
	return final_height

## Fast height calculation with pre-filtered features (avoids repeated filtering)
func _calculate_height_at_fast(world_pos: Vector3, active_features: Array) -> float:
	var final_height = base_height
	
	# Quick path for no features
	if active_features.is_empty():
		return final_height
	
	var weighted_heights: Array[Dictionary] = []
	
	# Check only active features with spatial culling
	for feature in active_features:
		# Quick distance check before expensive influence calculation
		var feature_pos = feature.global_position
		var dist_sq = world_pos.distance_squared_to(feature_pos)
		var max_influence = max(feature.influence_size.x, feature.influence_size.y)
		var max_influence_sq = max_influence * max_influence * 1.5
		
		# Skip if definitely outside influence range
		if dist_sq > max_influence_sq:
			continue
		
		var weight = feature.get_influence_weight(world_pos)
		if weight > 0.001:
			var height = feature.get_height_at(world_pos)
			if feature.has_method("_apply_modifiers"):
				height = feature._apply_modifiers(world_pos, height)
			weighted_heights.append({
				"height": height,
				"weight": weight * feature.strength,
				"mode": feature.blend_mode
			})
	
	# Blend all features
	if weighted_heights.is_empty():
		return final_height
	
	for data in weighted_heights:
		match data.mode:
			0: # Add
				final_height += data.height * data.weight
			1: # Max
				final_height = max(final_height, data.height * data.weight)
			2: # Min
				final_height = min(final_height, data.height * data.weight)
			3: # Multiply
				final_height *= (1.0 + data.height * data.weight)
			4: # Average
				final_height += data.height * data.weight
	
	return final_height

## Ultra-fast height calculation with pre-cached feature data
func _calculate_height_at_cached(world_pos: Vector3, feature_data: Array[Dictionary]) -> float:
	var final_height = base_height
	
	# Quick path for no features
	if feature_data.is_empty():
		return final_height
	
	# Optimized loop with minimal allocations
	for data in feature_data:
		# Spatial culling with cached values - no property lookups
		var dist_sq = world_pos.distance_squared_to(data.position)
		if dist_sq > data.max_influence_sq:
			continue
		
		var feature = data.feature
		var weight = feature.get_influence_weight(world_pos)
		if weight <= 0.001:
			continue
		
		var height = feature.get_height_at(world_pos)
		if feature.has_method("_apply_modifiers"):
			height = feature._apply_modifiers(world_pos, height)
		
		var weighted_height = height * weight * data.strength
		
		# Inline blending for speed (avoid dictionary allocation)
		match data.blend_mode:
			0: # Add
				final_height += weighted_height
			1: # Max
				final_height = max(final_height, weighted_height)
			2: # Min
				final_height = min(final_height, weighted_height)
			3: # Multiply
				final_height *= (1.0 + weighted_height)
			4: # Average
				final_height += weighted_height
	
	return final_height

## Update or create the terrain material with texture layers
func _update_material() -> void:
	if not _mesh_instance:
		return
	
	# Use custom material if terrain_material is set, otherwise create shader material
	if terrain_material:
		_mesh_instance.material_override = terrain_material
		return
	
	# Create shader material if not exists
	if not _shader_material:
		_shader_material = ShaderMaterial.new()
		var shader = load("res://addons/terrainy/shaders/terrain_material.gdshader")
		_shader_material.shader = shader
	
	_mesh_instance.material_override = _shader_material
	
	# Update shader parameters with texture layers
	if texture_layers.is_empty():
		_shader_material.set_shader_parameter("layer_count", 0)
		return
	
	# Build texture arrays and update shader parameters
	_build_texture_arrays()

## Build Texture2DArray resources from texture layers
func _build_texture_arrays() -> void:
	if texture_layers.is_empty():
		return
	
	var layer_count = min(texture_layers.size(), 32)
	_shader_material.set_shader_parameter("layer_count", layer_count)
	
	# Determine the texture size (find the largest texture to preserve quality)
	var texture_size: Vector2i = Vector2i(2048, 2048)  # Default to 2K for quality
	for layer in texture_layers:
		for tex in [layer.albedo_texture, layer.normal_texture, layer.roughness_texture, layer.metallic_texture, layer.ao_texture]:
			if tex:
				var size = tex.get_size()
				texture_size.x = max(texture_size.x, size.x)
				texture_size.y = max(texture_size.y, size.y)
	
	# Create arrays for layer parameters
	var height_slope_params: Array[Vector4] = []
	var blend_params: Array[Vector4] = []
	var uv_params: Array[Vector4] = []
	var color_normal: Array[Vector4] = []
	var pbr_params: Array[Vector4] = []
	var texture_flags: Array[Vector4] = []
	var extra_flags: Array[Vector4] = []
	
	# Arrays to collect textures for Texture2DArray
	var albedo_images: Array[Image] = []
	var normal_images: Array[Image] = []
	var roughness_images: Array[Image] = []
	var metallic_images: Array[Image] = []
	var ao_images: Array[Image] = []
	
	for i in range(layer_count):
		var layer = texture_layers[i]
		if layer == null:
			continue
		
		# Pack layer parameters
		var slope_min_rad = deg_to_rad(layer.slope_min)
		var slope_max_rad = deg_to_rad(layer.slope_max)
		var slope_falloff_rad = deg_to_rad(layer.slope_falloff)
		
		height_slope_params.append(Vector4(
			layer.height_min,
			layer.height_max,
			layer.height_falloff,
			slope_min_rad
		))
		
		blend_params.append(Vector4(
			slope_max_rad,
			slope_falloff_rad,
			layer.layer_strength,
			float(layer.blend_mode)
		))
		
		uv_params.append(Vector4(
			layer.uv_scale.x,
			layer.uv_scale.y,
			layer.uv_offset.x,
			layer.uv_offset.y
		))
		
		color_normal.append(Vector4(
			layer.albedo_color.r,
			layer.albedo_color.g,
			layer.albedo_color.b,
			layer.normal_strength
		))
		
		pbr_params.append(Vector4(
			layer.roughness,
			layer.metallic,
			layer.ao_strength,
			0.0
		))
		
		texture_flags.append(Vector4(
			1.0 if layer.albedo_texture else 0.0,
			1.0 if layer.normal_texture else 0.0,
			1.0 if layer.roughness_texture else 0.0,
			1.0 if layer.metallic_texture else 0.0
		))
		
		extra_flags.append(Vector4(
			1.0 if layer.ao_texture else 0.0,
			1.0 if layer.height_blend_curve else 0.0,
			1.0 if layer.slope_blend_curve else 0.0,
			0.0
		))
		
		# Collect texture images
		albedo_images.append(_get_or_create_image(layer.albedo_texture, texture_size, Color.WHITE))
		normal_images.append(_get_or_create_image(layer.normal_texture, texture_size, Color(0.5, 0.5, 1.0, 1.0)))
		roughness_images.append(_get_or_create_image(layer.roughness_texture, texture_size, Color.WHITE))
	
	# Set shader parameters
	_shader_material.set_shader_parameter("layer_height_slope_params", height_slope_params)
	_shader_material.set_shader_parameter("layer_blend_params", blend_params)
	_shader_material.set_shader_parameter("layer_uv_params", uv_params)
	_shader_material.set_shader_parameter("layer_color_normal", color_normal)
	_shader_material.set_shader_parameter("layer_pbr_params", pbr_params)
	_shader_material.set_shader_parameter("layer_texture_flags", texture_flags)
	_shader_material.set_shader_parameter("layer_extra_flags", extra_flags)
	_shader_material.set_shader_parameter("world_height_offset", 0.0)
	
	# Create Texture2DArray resources
	var albedo_array = _create_texture_array(albedo_images)
	var normal_array = _create_texture_array(normal_images)
	var roughness_array = _create_texture_array(roughness_images)
	var metallic_array = _create_texture_array(metallic_images)
	var ao_array = _create_texture_array(ao_images)
	
	# Set texture arrays to shader
	if albedo_array:
		_shader_material.set_shader_parameter("albedo_textures", albedo_array)
	if normal_array:
		_shader_material.set_shader_parameter("normal_textures", normal_array)
	if roughness_array:
		_shader_material.set_shader_parameter("roughness_textures", roughness_array)
	if metallic_array:
		_shader_material.set_shader_parameter("metallic_textures", metallic_array)
	if ao_array:
		_shader_material.set_shader_parameter("ao_textures", ao_array)

## Get image from texture or create a default one
func _get_or_create_image(texture: Texture2D, size: Vector2i, default_color: Color) -> Image:
	var img: Image
	
	if texture:
		# Get the image data from the texture
		img = texture.get_image()
		
		if img:
			img = img.duplicate()
			
			# Decompress if needed to preserve quality
			if img.is_compressed():
				img.decompress()
			
			# Convert to RGBA8 format for consistency
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			
			# Resize if needed (Texture2DArray requires all textures to be the same size)
			if img.get_size() != size:
				img.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
		else:
			# Fallback if image can't be retrieved
			img = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
			img.fill(default_color)
	else:
		# Create default colored image
		img = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
		img.fill(default_color)
	
	return img

## Create Texture2DArray from array of images
func _create_texture_array(images: Array[Image]) -> Texture2DArray:
	if images.is_empty():
		return null
	
	# Ensure all images have the same format and size
	var size = images[0].get_size()
	var format = Image.FORMAT_RGBA8
	
	for i in range(images.size()):
		if images[i].get_format() != format:
			images[i].convert(format)
		if images[i].get_size() != size:
			images[i].resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
		
		# Generate mipmaps to prevent texture aliasing/moiré patterns
		if not images[i].has_mipmaps():
			images[i].generate_mipmaps()
	
	var texture_array = Texture2DArray.new()
	
	# Create the texture array with all layers
	texture_array.create_from_images(images)
	
	return texture_array
