@tool
class_name TerrainComposer
extends Node3D

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")
const ScatterNode = preload("res://addons/terrainy/nodes/scatter/scatter_node.gd")
const TerrainTextureLayer = preload("res://addons/terrainy/resources/terrain_texture_layer.gd")
const TerrainMeshGenerator = preload("res://addons/terrainy/helpers/terrain_mesh_generator.gd")
const TerrainHeightmapBuilder = preload("res://addons/terrainy/helpers/terrain_heightmap_builder.gd")
const TerrainMaterialBuilder = preload("res://addons/terrainy/helpers/terrain_material_builder.gd")
const EvaluationContext = preload("res://addons/terrainy/nodes/evaluation_context.gd")
const ChunkManager = preload("res://addons/terrainy/helpers/chunk_manager.gd")
const ScatterManager = preload("res://addons/terrainy/helpers/scatter_manager.gd")
const BakeExporter = preload("res://addons/terrainy/helpers/bake_exporter.gd")


## Simple terrain composer - generates mesh from TerrainFeatureNodes

signal terrain_updated
signal texture_layers_changed

# Constants
const MAX_TERRAIN_RESOLUTION = 4096
const MAX_FEATURE_COUNT = 64
const MAX_CHUNK_SIZE = 8192
const REBUILD_DEBOUNCE_SEC = 0.3  # Debounce rapid changes (e.g., gizmo manipulation)


const HOLE_DEPTH_SENTINEL := -1000000.0  # Named constant for hole value

## Size of the terrain in world units (X,Z)
@export var terrain_size: Vector2 = Vector2(100, 100):
	set(value):
		terrain_size = value
		if _heightmap_composer:
			_heightmap_composer.clear_all_caches()
		if auto_update and is_inside_tree():
			rebuild_terrain()

## Resolution of the terrain heightmap (number of vertices along one axis)
@export var resolution: int = 128:
	set(value):
		resolution = clamp(value, 16, MAX_TERRAIN_RESOLUTION)
		if _heightmap_composer:
			_heightmap_composer.clear_all_caches()
		if _chunk_manager:
			_chunk_manager.mark_all_dirty()
		if auto_update and is_inside_tree():
			rebuild_terrain()

## Base height offset for the terrain
@export var base_height: float = 0.0:
	set(value):
		base_height = value
		if _chunk_manager:
			_chunk_manager.mark_all_dirty()
		if auto_update and is_inside_tree():
			rebuild_terrain()

## Automatically update terrain on feature/parameter changes
@export var auto_update: bool = true

@export_group("Performance")
## Use GPU for heightmap composition (faster, requires compatible GPU)
@export var use_gpu_composition: bool = true:
	set(value):
		use_gpu_composition = value
		if _initial_rebuild_pending:
			return
		if is_inside_tree() and auto_update:
			rebuild_terrain()

@export_group("Chunking")
## Size of each terrain chunk (in world units)
@export_range(1, MAX_CHUNK_SIZE, 1) var chunk_size: int = 512:
	set(value):
		chunk_size = clamp(value, 1, MAX_CHUNK_SIZE)
		if _chunk_manager:
			_chunk_manager.mark_all_dirty()
		if auto_update and is_inside_tree():
			rebuild_terrain()

@export_group("Threading")
## Enable multithreaded generation (heightmaps + chunk meshes)
@export var use_multithreading: bool = true
## Max concurrent worker tasks for heightmap generation (1 = effectively single-threaded)
@export_range(1, 32, 1) var max_worker_threads: int = 4

@export_group("LOD")
## Enable Level of Detail (LOD) for terrain chunks
@export var enable_lod: bool = true:
	set(value):
		enable_lod = value
		if auto_update and is_inside_tree():
			_request_rebuild()

## Distances at which LOD levels switch (in world units)
@export var lod_distances: Array[float] = [500.0, 1000.0, 2000.0]
## Scale factors for each LOD level (1.0 = full res, 0.5 = half res, etc.)
@export var lod_scale_factors: Array[float] = [1.0, 0.5, 0.25, 0.125]

@export_group("Material")
## Material to use for the terrain chunks
@export var terrain_material: Material

@export_group("Texture Layers")
## Texture layers for terrain material
@export var texture_layers: Array[TerrainTextureLayer] = []:
	set(value):
		for layer in texture_layers:
			if is_instance_valid(layer) and layer.layer_changed.is_connected(_on_texture_layer_changed):
				layer.layer_changed.disconnect(_on_texture_layer_changed)
		
		texture_layers = value
		
		for layer in texture_layers:
			if is_instance_valid(layer) and not layer.layer_changed.is_connected(_on_texture_layer_changed):
				layer.layer_changed.connect(_on_texture_layer_changed)
		
		_update_material()
		texture_layers_changed.emit()

@export_group("Collision")
@export var generate_collision: bool = true:
	set(value):
		generate_collision = value
		_update_all_chunk_collisions()

@export_flags_3d_physics var collision_layer: int = 1:
	set(value):
		collision_layer = value
		_update_all_chunk_collision_properties()

@export_flags_3d_physics var collision_mask: int = 1:
	set(value):
		collision_mask = value
		_update_all_chunk_collision_properties()

var _is_generating: bool = false

# Subsystem helpers
var _chunk_manager: ChunkManager = null
var _scatter_manager: ScatterManager = null
var _bake_exporter: BakeExporter = null
var _heightmap_composer: TerrainHeightmapBuilder = null
var _material_builder: TerrainMaterialBuilder = null

# Feature tracking
var _feature_nodes: Array[TerrainFeatureNode] = []
var _height_feature_nodes: Array[TerrainFeatureNode] = []
var _scatter_nodes: Array[ScatterNode] = []
var _feature_bounds_cache: Dictionary = {}  # feature -> Rect2

# Threading
var _chunk_thread: Thread = null
var _pending_chunk_results: Array = []
var _pending_chunk_rebuild_id: int = 0
var _chunk_thread_started: bool = false
var _chunk_thread_seen_alive: bool = false
const CHUNK_LOG_THRESHOLD_MS = 100

# Terrain state
var _final_heightmap: Image
var _final_hole_mask: Image
var _terrain_bounds: Rect2

# Rebuild timing
var _rebuild_start_msec: int = 0
var _rebuild_id: int = 0
var _coordinator_rebuild_pending: bool = false
var _heightmap_dirty_pending: bool = false

# Rebuild debouncing
var _rebuild_timer: Timer = null
var _pending_rebuild: bool = false
var _rebuild_after_current: bool = false
var _initial_rebuild_pending: bool = true

func _ready() -> void:
	set_process(false)  # Only enable when mesh generation is running
	_initial_rebuild_pending = true
	
	# Initialize helpers
	_heightmap_composer = TerrainHeightmapBuilder.new()
	_material_builder = TerrainMaterialBuilder.new()
	_chunk_manager = ChunkManager.new(self)
	_scatter_manager = ScatterManager.new(self)
	_bake_exporter = BakeExporter.new()
	
	# Compatibility renderer guard: disable GPU composition to avoid editor freezes
	if not RenderingServer.get_rendering_device():
		if use_gpu_composition:
			push_warning("[TerrainComposer] Compatibility renderer detected, disabling GPU composition")
		use_gpu_composition = false
	
	# Watch for child changes in editor
	if Engine.is_editor_hint():
		child_entered_tree.connect(_on_child_changed)
		child_exiting_tree.connect(_on_child_changed)
		_setup_rebuild_debounce_timer()
	
	# Initial generation
	_scan_features()
	_request_rebuild()

func _process(_delta: float) -> void:
	# Check if chunk generation thread completed
	if _chunk_thread:
		if _chunk_thread.is_alive():
			_chunk_thread_seen_alive = true
		elif _chunk_thread_started:
			if _chunk_thread_seen_alive or not _pending_chunk_results.is_empty():
				_chunk_thread.wait_to_finish()
				_chunk_thread = null
				_chunk_thread_started = false
				_chunk_thread_seen_alive = false
				_on_chunk_generation_completed()
		elif not _chunk_thread_started:
			# Defensive cleanup if thread was never started
			_chunk_thread = null

	# Update LODs if enabled
	if enable_lod and _chunk_manager and _chunk_manager.get_chunks().size() > 0 and _final_heightmap:
		_update_chunk_lod()
		if not _heightmap_dirty_pending and _chunk_manager.has_dirty_chunks() and not _is_generating:
			_rebuild_chunks(false)

	if not _chunk_thread and not enable_lod:
		set_process(false)

func _exit_tree() -> void:
	# Cancel any queued rebuild
	if Engine.has_singleton("TerrainRebuildCoordinator"):
		TerrainRebuildCoordinator.cancel_rebuild(self)
	
	if _chunk_thread and _chunk_thread_started and _chunk_thread.is_alive():
		# Wait with timeout to prevent editor hang (max 5 seconds)
		var wait_start = Time.get_ticks_msec()
		while _chunk_thread.is_alive():
			if Time.get_ticks_msec() - wait_start > 5000:
				push_warning("[TerrainComposer] Mesh thread did not finish in time, forcing exit")
				break
			OS.delay_msec(10)
		if not _chunk_thread.is_alive() and _chunk_thread_seen_alive:
			_chunk_thread.wait_to_finish()
	
	# Disconnect feature signals to prevent transform notifications during teardown
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.parameters_changed.is_connected(_on_feature_changed):
			feature.parameters_changed.disconnect(_on_feature_changed)
	
	# Clean up helpers
	if _heightmap_composer:
		_heightmap_composer.cleanup()
		_heightmap_composer = null
	
	# Clean up scatter instances
	if _scatter_manager:
		_scatter_manager.clear_scatter(_scatter_nodes)
		_scatter_manager = null
	
	# Chunk manager cleanup happens automatically via scene tree (child nodes freed)
	_chunk_manager = null
	_bake_exporter = null
	_feature_bounds_cache.clear()

func _scan_features() -> void:
	var previous_features = _feature_nodes.duplicate()
	# Disconnect old signals
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.parameters_changed.is_connected(_on_feature_changed):
			feature.parameters_changed.disconnect(_on_feature_changed)
	
	_feature_nodes.clear()
	_height_feature_nodes.clear()
	_scatter_nodes.clear()
	_scan_recursive(self)

	for feature in _feature_nodes:
		if feature is ScatterNode:
			_scatter_nodes.append(feature)
		elif feature.affects_heightmap():
			_height_feature_nodes.append(feature)

	var features_changed = false
	if previous_features.size() != _feature_nodes.size():
		features_changed = true
	else:
		for feature in previous_features:
			if not _feature_nodes.has(feature):
				features_changed = true
				break
	
	# Drop cached bounds for removed features
	var removed_features: Array = []
	for cached_feature in _feature_bounds_cache.keys():
		if not _feature_nodes.has(cached_feature):
			removed_features.append(cached_feature)
	
	for removed_feature in removed_features:
		var previous_bounds: Rect2 = _feature_bounds_cache.get(removed_feature, Rect2())
		if previous_bounds != Rect2():
			if _chunk_manager:
				_chunk_manager.mark_dirty_for_bounds(previous_bounds)
		if _heightmap_composer:
			_heightmap_composer.invalidate_heightmap(removed_feature)
			_heightmap_composer.invalidate_influence(removed_feature)
		_feature_bounds_cache.erase(removed_feature)
		_heightmap_dirty_pending = true
	
	# Cache bounds for new features and mark their chunks dirty
	for feature in _feature_nodes:
		if not _feature_bounds_cache.has(feature) and is_instance_valid(feature) and feature.is_inside_tree():
			var bounds = _get_feature_world_bounds(feature)
			_feature_bounds_cache[feature] = bounds
			if _chunk_manager:
				_chunk_manager.mark_dirty_for_bounds(bounds)
			_heightmap_dirty_pending = true

	if features_changed:
		if _chunk_manager:
			_chunk_manager.mark_all_dirty()
		_heightmap_dirty_pending = true
	
	# Connect new signals
	for feature in _feature_nodes:
		if is_instance_valid(feature):
			feature.parameters_changed.connect(_on_feature_changed.bind(feature))

func _scan_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is TerrainFeatureNode:
			if _feature_nodes.size() >= MAX_FEATURE_COUNT:
				push_warning("[TerrainComposer] Maximum feature count (%d) reached, ignoring '%s'" % [MAX_FEATURE_COUNT, child.name])
				break
			_feature_nodes.append(child)
			_scan_recursive(child)
		elif not (child is MeshInstance3D or child is StaticBody3D or child is CollisionShape3D):
			_scan_recursive(child)

func _on_child_changed(_node: Node) -> void:
	if _initial_rebuild_pending:
		return
	call_deferred("_rescan_and_rebuild")

func _rescan_and_rebuild() -> void:
	if not is_inside_tree():
		return
	_scan_features()
	if auto_update:
		rebuild_terrain()

func _setup_rebuild_debounce_timer() -> void:
	if not _rebuild_timer:
		_rebuild_timer = Timer.new()
		_rebuild_timer.one_shot = true
		_rebuild_timer.wait_time = REBUILD_DEBOUNCE_SEC
		_rebuild_timer.timeout.connect(_on_rebuild_timer_timeout)
		add_child(_rebuild_timer)

func _request_rebuild() -> void:
	if _is_generating:
		_rebuild_after_current = true
		return
	
	_pending_rebuild = true
	if _rebuild_timer:
		_rebuild_timer.start()
	else:
		# Fallback if no timer (non-editor mode)
		rebuild_terrain()

func _on_rebuild_timer_timeout() -> void:
	if _pending_rebuild:
		if _is_generating:
			_rebuild_after_current = true
			_pending_rebuild = false
			return
		_pending_rebuild = false
		rebuild_terrain()

func _on_feature_changed(feature: TerrainFeatureNode) -> void:
	if not is_inside_tree() or not is_instance_valid(feature) or not feature.is_inside_tree():
		return

	# Invalidate caches via helper
	if _heightmap_composer and not (feature is ScatterNode):
		_heightmap_composer.invalidate_heightmap(feature)
		
		# Only invalidate influence if influence-related properties changed
		_heightmap_composer.invalidate_influence(feature)
	
	# Mark affected chunks dirty (both previous and current bounds)
	var previous_bounds: Rect2 = _feature_bounds_cache.get(feature, Rect2())
	var current_bounds: Rect2 = _get_feature_world_bounds(feature)
	if previous_bounds != Rect2():
		if _chunk_manager:
			_chunk_manager.mark_dirty_for_bounds(previous_bounds)
	if _chunk_manager:
		_chunk_manager.mark_dirty_for_bounds(current_bounds)
	_feature_bounds_cache[feature] = current_bounds
	_heightmap_dirty_pending = true
	
	if auto_update:
		_request_rebuild()

func _on_texture_layer_changed() -> void:
	_update_material()

func bake_to_scene(output_path: String) -> bool:
	if not _chunk_manager or _chunk_manager.get_chunks().is_empty():
		push_warning("[TerrainComposer] Cannot bake to scene because no chunks are available")
		return false

	var packed_scene := _bake_exporter.export_terrain(
		_chunk_manager.get_chunks(),
		_feature_nodes,
		_scatter_nodes,
		collision_layer,
		collision_mask,
		generate_collision,
		terrain_material
	)
	if packed_scene == null:
		return false

	var error := ResourceSaver.save(packed_scene, output_path)
	if error != OK:
		push_error("[TerrainComposer] Failed to save baked scene: %s (error %d)" % [output_path, error])
		return false

	print("[TerrainComposer] Baked terrain saved to %s" % output_path)
	return true

## Force a complete rebuild with all caches cleared
func force_rebuild() -> void:
	print("[TerrainComposer] Force rebuild - clearing all caches")
	# Clear all caches for a completely fresh rebuild
	if _heightmap_composer:
		_heightmap_composer.clear_all_caches()

	# Rescan features to refresh list and signals
	_scan_features()

	# Reset bounds cache to current feature bounds
	_feature_bounds_cache.clear()
	for feature in _feature_nodes:
		if is_instance_valid(feature):
			_feature_bounds_cache[feature] = _get_feature_world_bounds(feature)
	
	# Mark all features as dirty
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.has_method("mark_dirty"):
			feature.mark_dirty()

	# Force all chunks to rebuild from the new heightmap
	if _chunk_manager:
		_chunk_manager.mark_all_dirty()
	_heightmap_dirty_pending = true
	
	# Trigger regular rebuild
	rebuild_terrain()

## Regenerate the entire terrain mesh
func rebuild_terrain() -> void:
	if _is_generating:
		_rebuild_after_current = true
		return

	# Ensure helpers exist (tool scripts can reload and clear references)
	if not _heightmap_composer:
		_heightmap_composer = TerrainHeightmapBuilder.new()
	if not _material_builder:
		_material_builder = TerrainMaterialBuilder.new()
	if not _chunk_manager:
		_chunk_manager = ChunkManager.new(self)
	if not _scatter_manager:
		_scatter_manager = ScatterManager.new(self)
	if not _bake_exporter:
		_bake_exporter = BakeExporter.new()
	
	# Check with rebuild coordinator if we can start
	if Engine.has_singleton("TerrainRebuildCoordinator"):
		if not TerrainRebuildCoordinator.request_rebuild(self):
			return  # Queued, will be called again when ready
		_coordinator_rebuild_pending = true
	
	_is_generating = true
	_rebuild_id += 1
	_rebuild_start_msec = Time.get_ticks_msec()
	
	# Calculate terrain bounds in WORLD SPACE
	# Features use global positions, so bounds must be global too
	var local_bounds = Rect2(-terrain_size / 2.0, terrain_size)
	_terrain_bounds = Rect2(
		global_position.x + local_bounds.position.x,
		global_position.z + local_bounds.position.y,
		local_bounds.size.x,
		local_bounds.size.y
	)
	
	# Resolution for heightmaps
	var heightmap_resolution = Vector2i(resolution + 1, resolution + 1)
	
	# Phase 4: Prepare all evaluation contexts on main thread
	var context_start = Time.get_ticks_msec()
	var feature_contexts = {}
	for feature in _height_feature_nodes:
		if is_instance_valid(feature) and feature.is_inside_tree() and feature.visible:
			feature_contexts[feature] = feature.prepare_evaluation_context()
	var context_elapsed = Time.get_ticks_msec() - context_start
	print("[TerrainComposer] Rebuild #%d prepared %d contexts in %d ms" % [_rebuild_id, feature_contexts.size(), context_elapsed])
	
	# Compose heightmaps using helper with contexts
	var compose_start = Time.get_ticks_msec()
	var compose_result = _heightmap_composer.compose(
		_height_feature_nodes,
		feature_contexts,
		heightmap_resolution,
		_terrain_bounds,
		base_height,
		use_gpu_composition,
		use_multithreading,
		max_worker_threads
	)
	if compose_result.is_empty() or not compose_result.has("heightmap"):
		push_error("[TerrainComposer] Heightmap composition failed; aborting rebuild")
		_is_generating = false
		if _coordinator_rebuild_pending and Engine.has_singleton("TerrainRebuildCoordinator"):
			TerrainRebuildCoordinator.rebuild_completed(self)
			_coordinator_rebuild_pending = false
		return
	
	_final_heightmap = compose_result["heightmap"]
	_final_hole_mask = compose_result.get("hole_mask", null)
	var compose_elapsed = Time.get_ticks_msec() - compose_start
	print("[TerrainComposer] Rebuild #%d compose time: %d ms" % [_rebuild_id, compose_elapsed])
	
	# Step 3: Generate chunk meshes from final heightmap
	var grid_changed = _chunk_manager.update_grid(terrain_size, chunk_size, _get_terrain_origin_world())
	if grid_changed:
		_chunk_manager.mark_all_dirty()
	_heightmap_dirty_pending = false
	
	_rebuild_chunks(grid_changed)
	
	# Check for completion in process
	set_process(true)

func _get_chunk_generation_lod(chunk) -> int:
	return chunk.lod_level


func _update_material() -> void:
	if _material_builder and _chunk_manager:
		var shared_material: Material = null
		for chunk in _chunk_manager.get_chunks().values():
			if not chunk.mesh_instance:
				continue
			if not shared_material:
				_material_builder.update_material(chunk.mesh_instance, texture_layers, terrain_material)
				shared_material = chunk.mesh_instance.material_override
			else:
				chunk.mesh_instance.material_override = shared_material

func _get_terrain_origin_world() -> Vector2:
	return Vector2(
		global_position.x - terrain_size.x * 0.5,
		global_position.z - terrain_size.y * 0.5
	)

func _extract_chunk_heightmap(chunk, lod_level: int) -> Dictionary:
	if not _final_heightmap:
		return {}
	
	# Heightmap is created at resolution + 1 (see rebuild_terrain)
	# This means there are (resolution) intervals, with (resolution + 1) vertices/pixels
	var heightmap_res_x = resolution + 1
	var heightmap_res_y = resolution + 1
	var intervals_x = resolution
	var intervals_y = resolution
	
	# Calculate pixel positions from chunk grid indices using intervals
	# This ensures adjacent chunks share the exact same border pixel
	var grid_size = _chunk_manager.get_chunk_grid_size()
	var grid_x = max(1, grid_size.x)
	var grid_y = max(1, grid_size.y)
	
	var intervals_per_chunk_x = float(intervals_x) / float(grid_x)
	var intervals_per_chunk_y = float(intervals_y) / float(grid_y)
	
	var start_x = int(round(chunk.position.x * intervals_per_chunk_x))
	var start_y = int(round(chunk.position.y * intervals_per_chunk_y))
	var end_x = int(round((chunk.position.x + 1) * intervals_per_chunk_x))
	var end_y = int(round((chunk.position.y + 1) * intervals_per_chunk_y))
	
	start_x = clampi(start_x, 0, heightmap_res_x - 1)
	start_y = clampi(start_y, 0, heightmap_res_y - 1)
	end_x = clampi(end_x, 0, heightmap_res_x - 1)
	end_y = clampi(end_y, 0, heightmap_res_y - 1)
	
	var width = max(2, end_x - start_x + 1)
	var height = max(2, end_y - start_y + 1)
	
	var chunk_heightmap = Image.create(width, height, false, Image.FORMAT_RF)
	chunk_heightmap.blit_rect(_final_heightmap, Rect2i(start_x, start_y, width, height), Vector2i.ZERO)
	
	var chunk_hole_mask: Image = null
	if _final_hole_mask:
		chunk_hole_mask = Image.create(width, height, false, Image.FORMAT_RF)
		chunk_hole_mask.blit_rect(_final_hole_mask, Rect2i(start_x, start_y, width, height), Vector2i.ZERO)
	
	if lod_level > 0 and lod_level < lod_scale_factors.size():
		var scale = lod_scale_factors[lod_level]
		var target_w = max(2, int(round((width - 1) * scale)) + 1)
		var target_h = max(2, int(round((height - 1) * scale)) + 1)
		if target_w != width or target_h != height:
			chunk_heightmap.resize(target_w, target_h, Image.INTERPOLATE_BILINEAR)
			if chunk_hole_mask:
				chunk_hole_mask.resize(target_w, target_h, Image.INTERPOLATE_NEAREST)
	
	return {
		"heightmap": chunk_heightmap,
		"hole_mask": chunk_hole_mask
	}

func _get_feature_world_bounds(feature: TerrainFeatureNode) -> Rect2:
	var center = Vector2(feature.global_position.x, feature.global_position.z)
	var half_size: Vector2
	
	match feature.influence_shape:
		TerrainFeatureNode.InfluenceShape.CIRCLE:
			var radius = max(feature.influence_size.x, feature.influence_size.y) * 0.5
			half_size = Vector2(radius, radius)
		TerrainFeatureNode.InfluenceShape.ELLIPSE:
			half_size = feature.influence_size * 0.5
		_:
			half_size = feature.influence_size * 0.5
	
	var corners = [
		Vector3(-half_size.x, 0, -half_size.y),
		Vector3(half_size.x, 0, -half_size.y),
		Vector3(half_size.x, 0, half_size.y),
		Vector3(-half_size.x, 0, half_size.y)
	]
	
	var min_x = INF
	var min_z = INF
	var max_x = -INF
	var max_z = -INF
	
	for corner in corners:
		var world_corner = feature.global_transform * corner
		min_x = min(min_x, world_corner.x)
		min_z = min(min_z, world_corner.z)
		max_x = max(max_x, world_corner.x)
		max_z = max(max_z, world_corner.z)
	
	return Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))

func _get_chunks_affected_by_feature(feature: TerrainFeatureNode) -> Array:
	var bounds = _get_feature_world_bounds(feature)
	return _get_chunks_affected_by_bounds(bounds)

func _get_chunks_affected_by_bounds(bounds: Rect2) -> Array:
	var affected: Array = []
	if not _chunk_manager:
		return affected
	for chunk in _chunk_manager.get_chunks().values():
		if chunk.world_bounds.intersects(bounds):
			affected.append(chunk)
	return affected

func _rebuild_chunks(full_rebuild: bool) -> void:
	if _chunk_thread and _chunk_thread_started and _chunk_thread.is_alive():
		_chunk_thread.wait_to_finish()
	
	var dirty_chunks: Array = []
	if _chunk_manager:
		for chunk in _chunk_manager.get_chunks().values():
			if full_rebuild or chunk.is_dirty:
				dirty_chunks.append(chunk)
	
	if dirty_chunks.is_empty():
		_is_generating = false
		_rebuild_start_msec = 0
		_initial_rebuild_pending = false
		if _scatter_manager:
			_scatter_manager.set_terrain_data(_final_heightmap, _terrain_bounds, base_height, resolution)
			_scatter_manager.refresh_scatter(_scatter_nodes, _feature_nodes)
		if _coordinator_rebuild_pending and Engine.has_singleton("TerrainRebuildCoordinator"):
			TerrainRebuildCoordinator.rebuild_completed(self)
			_coordinator_rebuild_pending = false
		terrain_updated.emit()
		return

	_is_generating = true
	
	var jobs: Array = []
	for chunk in dirty_chunks:
		var target_lod = _get_chunk_generation_lod(chunk)
		var chunk_data = _extract_chunk_heightmap(chunk, target_lod)
		if chunk_data.is_empty():
			continue
		jobs.append({
			"key": chunk.position,
			"heightmap": chunk_data["heightmap"],
			"hole_mask": chunk_data["hole_mask"],
			"size": Vector2(chunk.world_bounds.size.x, chunk.world_bounds.size.y),
			"lod_level": target_lod
		})
	
	_pending_chunk_results.clear()
	_pending_chunk_rebuild_id = _rebuild_id
	
	var thread_data = {
		"jobs": jobs,
		"rebuild_id": _rebuild_id
	}
	_chunk_thread = Thread.new()
	if use_multithreading:
		var start_error = _chunk_thread.start(_generate_chunk_meshes_threaded.bind(thread_data))
		if start_error == OK:
			_chunk_thread_started = true
			_chunk_thread_seen_alive = false
		else:
			push_error("[TerrainComposer] Failed to start chunk thread (%d), falling back to main thread" % start_error)
			_chunk_thread = null
			_chunk_thread_started = false
			_chunk_thread_seen_alive = false
			_generate_chunk_meshes_threaded(thread_data)
			_on_chunk_generation_completed()
	else:
		_chunk_thread = null
		_chunk_thread_started = false
		_chunk_thread_seen_alive = false
		_generate_chunk_meshes_threaded(thread_data)
		_on_chunk_generation_completed()

func _generate_chunk_meshes_threaded(data: Dictionary) -> void:
	var results: Array = []
	for job in data["jobs"]:
		var heightmap: Image = job["heightmap"]
		var hole_mask: Image = job.get("hole_mask", null)
		var size: Vector2 = job["size"]
		var mesh = TerrainMeshGenerator.generate_from_heightmap(heightmap, size, hole_mask)
		results.append({
			"key": job["key"],
			"mesh": mesh,
			"heightmap": heightmap,
			"hole_mask": hole_mask,
			"lod_level": job["lod_level"]
		})
	_pending_chunk_results = results
	_pending_chunk_rebuild_id = data["rebuild_id"]

func _apply_pending_chunk_results() -> void:
	if _pending_chunk_results.is_empty():
		return
	
	if not _chunk_manager:
		return
	
	for result in _pending_chunk_results:
		var key: Vector2i = result["key"]
		var chunk = _chunk_manager.get_chunks().get(key)
		if not chunk:
			continue
		chunk.mesh_instance.mesh = result["mesh"]
		chunk.mesh_instance.visible = true
		chunk.heightmap = result["heightmap"]
		chunk.hole_mask = result.get("hole_mask", null)
		chunk.lod_level = result["lod_level"]
		chunk.is_dirty = false
		_update_chunk_collision(chunk)
	
	_update_material()
	_pending_chunk_results.clear()

func _on_chunk_generation_completed() -> void:
	_apply_pending_chunk_results()
	if _scatter_manager:
		_scatter_manager.set_terrain_data(_final_heightmap, _terrain_bounds, base_height, resolution)
		_scatter_manager.refresh_scatter(_scatter_nodes, _feature_nodes)
	_is_generating = false
	_initial_rebuild_pending = false

	if _rebuild_start_msec > 0:
		var total_elapsed = Time.get_ticks_msec() - _rebuild_start_msec
		print("[TerrainComposer:%s] Rebuild #%d completed in %d ms" % [name, _rebuild_id, total_elapsed])
		_rebuild_start_msec = 0

	# Signal rebuild completion to coordinator
	if _coordinator_rebuild_pending and Engine.has_singleton("TerrainRebuildCoordinator"):
		TerrainRebuildCoordinator.rebuild_completed(self)
		_coordinator_rebuild_pending = false
	terrain_updated.emit()

	if _rebuild_after_current:
		_rebuild_after_current = false
		call_deferred("rebuild_terrain")

func _update_chunk_collision(chunk) -> void:
	if not chunk or not chunk.collision_shape:
		return

	var start_time = Time.get_ticks_msec()

	if not generate_collision:
		chunk.static_body.visible = false
		chunk.collision_shape.shape = null
		return

	if not chunk.mesh_instance or not chunk.mesh_instance.mesh:
		chunk.static_body.visible = false
		chunk.collision_shape.shape = null
		return

	chunk.static_body.visible = true

	if chunk.hole_mask != null and _mask_has_holes(chunk.hole_mask):
		# Chunk has actual hole pixels — use trimesh collision (respects hole geometry)
		if not (chunk.collision_shape.shape is ConcavePolygonShape3D):
			chunk.collision_shape.shape = chunk.mesh_instance.mesh.create_trimesh_shape()
		chunk.collision_shape.scale = Vector3.ONE
		chunk.collision_shape.position = Vector3.ZERO
		return

	if not chunk.heightmap:
		# No heightmap available — fallback to trimesh
		if not (chunk.collision_shape.shape is ConcavePolygonShape3D):
			chunk.collision_shape.shape = chunk.mesh_instance.mesh.create_trimesh_shape()
		chunk.collision_shape.scale = Vector3.ONE
		chunk.collision_shape.position = Vector3.ZERO
		return

	# Reuse or create HeightMapShape3D
	var height_shape: HeightMapShape3D
	if chunk.height_shape and is_instance_valid(chunk.height_shape):
		height_shape = chunk.height_shape
	else:
		height_shape = HeightMapShape3D.new()
		chunk.height_shape = height_shape
		chunk.collision_shape.shape = height_shape

	var w = chunk.heightmap.get_width()
	var d = chunk.heightmap.get_height()

	# Only update dimensions if changed
	if height_shape.map_width != w:
		height_shape.map_width = w
	if height_shape.map_depth != d:
		height_shape.map_depth = d

	# Reuse PackedFloat32Array if possible
	var map_data: PackedFloat32Array
	if chunk._collision_map_data and chunk._collision_map_data.size() == w * d:
		map_data = chunk._collision_map_data
	else:
		map_data = PackedFloat32Array()
		map_data.resize(w * d)
		chunk._collision_map_data = map_data

	var has_holes := chunk.hole_mask != null
	var hole_data: PackedFloat32Array
	if has_holes:
		hole_data = chunk.hole_mask.get_data().to_float32_array()

	# Fast bulk copy
	var height_data: PackedFloat32Array = chunk.heightmap.get_data().to_float32_array()
	for i in height_data.size():
		if has_holes and i < hole_data.size() and hole_data[i] >= 0.5:
			map_data[i] = HOLE_DEPTH_SENTINEL
		else:
			map_data[i] = height_data[i]

	# Assign data (this updates the physics server efficiently)
	height_shape.map_data = map_data

	# Update scale
	var new_scale = Vector3(
		chunk.world_bounds.size.x / float(w - 1),
		1.0,
		chunk.world_bounds.size.y / float(d - 1)
	)
	if not chunk.collision_shape.scale.is_equal_approx(new_scale):
		chunk.collision_shape.scale = new_scale

	chunk.collision_shape.position = Vector3.ZERO

	var elapsed = Time.get_ticks_msec() - start_time
	if elapsed >= CHUNK_LOG_THRESHOLD_MS:
		push_warning("[TerrainComposer] Slow chunk collision update: %dx%d in %d ms" % [w, d, elapsed])


static func _mask_has_holes(mask: Image) -> bool:
	if not mask:
		return false
	var data = mask.get_data()
	var bytes_per_pixel = 4
	for i in range(0, data.size(), bytes_per_pixel):
		if data.decode_float(i) > 0.5:
			return true
	return false


func _update_all_chunk_collisions() -> void:
	if not _chunk_manager:
		return
	for chunk in _chunk_manager.get_chunks().values():
		_update_chunk_collision(chunk)

func _update_all_chunk_collision_properties() -> void:
	if not _chunk_manager:
		return
	for chunk in _chunk_manager.get_chunks().values():
		if chunk and chunk.static_body:
			chunk.static_body.collision_layer = collision_layer
			chunk.static_body.collision_mask = collision_mask

func _update_chunk_lod() -> void:
	if not _chunk_manager:
		return
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return
	
	var camera_pos = camera.global_position
	for chunk in _chunk_manager.get_chunks().values():
		var center = Vector3(
			chunk.world_bounds.position.x + chunk.world_bounds.size.x * 0.5,
			0,
			chunk.world_bounds.position.y + chunk.world_bounds.size.y * 0.5
		)
		var distance = camera_pos.distance_to(center)
		var new_lod = _calculate_lod_level(distance)
		if new_lod != chunk.lod_level:
			chunk.lod_level = new_lod
			chunk.is_dirty = true

func _calculate_lod_level(distance: float) -> int:
	if lod_distances.is_empty() or lod_scale_factors.is_empty():
		return 0
	for i in range(lod_distances.size()):
		if distance < lod_distances[i]:
			return i
	return clampi(lod_distances.size(), 0, lod_scale_factors.size() - 1)
