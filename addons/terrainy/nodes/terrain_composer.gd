@tool
class_name TerrainComposer
extends Node3D

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")
const TerrainTextureLayer = preload("res://addons/terrainy/resources/terrain_texture_layer.gd")
const TerrainMeshGenerator = preload("res://addons/terrainy/helpers/terrain_mesh_generator.gd")
const TerrainHeightmapBuilder = preload("res://addons/terrainy/helpers/terrain_heightmap_builder.gd")
const TerrainMaterialBuilder = preload("res://addons/terrainy/helpers/terrain_material_builder.gd")
const EvaluationContext = preload("res://addons/terrainy/nodes/evaluation_context.gd")

## Simple terrain composer - generates mesh from TerrainFeatureNodes

signal terrain_updated
signal texture_layers_changed

# Constants
const MAX_TERRAIN_RESOLUTION = 4096
const MAX_FEATURE_COUNT = 64
const REBUILD_DEBOUNCE_SEC = 0.3  # Debounce rapid changes (e.g., gizmo manipulation)

@export var terrain_size: Vector2 = Vector2(100, 100):
	set(value):
		terrain_size = value
		if _heightmap_composer:
			_heightmap_composer.clear_all_caches()
		if auto_update and is_inside_tree():
			rebuild_terrain()

@export var resolution: int = 128:
	set(value):
		resolution = clamp(value, 16, MAX_TERRAIN_RESOLUTION)
		if _heightmap_composer:
			_heightmap_composer.clear_all_caches()
		_mark_all_chunks_dirty()
		if auto_update and is_inside_tree():
			rebuild_terrain()

@export var base_height: float = 0.0:
	set(value):
		base_height = value
		_mark_all_chunks_dirty()
		if auto_update and is_inside_tree():
			rebuild_terrain()

@export var auto_update: bool = true

@export_group("Performance")
@export var use_gpu_composition: bool = true:
	set(value):
		use_gpu_composition = value
		if is_inside_tree() and auto_update:
			rebuild_terrain()

@export_group("Chunking")
@export var chunk_size: int = 512:
	set(value):
		chunk_size = max(1, value)
		_mark_all_chunks_dirty()
		if auto_update and is_inside_tree():
			rebuild_terrain()

@export_group("LOD")
@export var enable_lod: bool = true:
	set(value):
		enable_lod = value
		if auto_update and is_inside_tree():
			_request_rebuild()

@export var lod_distances: Array[float] = [500.0, 1000.0, 2000.0]
@export var lod_scale_factors: Array[float] = [1.0, 0.5, 0.25, 0.125]

@export_group("Material")
@export var terrain_material: Material

@export_group("Texture Layers")
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

class TerrainChunk:
	var position: Vector2i
	var world_bounds: Rect2
	var root: Node3D
	var mesh_instance: MeshInstance3D
	var static_body: StaticBody3D
	var collision_shape: CollisionShape3D
	var lod_level: int = 0
	var is_dirty: bool = true
	var heightmap: Image = null

# Internal
var _feature_nodes: Array[TerrainFeatureNode] = []
var _is_generating: bool = false

# Chunking
var _chunks: Dictionary = {}  # Vector2i -> TerrainChunk
var _chunk_grid_size: Vector2i = Vector2i.ZERO
var _chunk_root: Node3D = null
var _feature_bounds_cache: Dictionary = {}  # feature -> Rect2

# Helpers
var _heightmap_composer: TerrainHeightmapBuilder = null
var _material_builder: TerrainMaterialBuilder = null

# Threading
var _chunk_thread: Thread = null
var _pending_chunk_results: Array = []
var _pending_chunk_rebuild_id: int = 0
var _chunk_thread_started: bool = false
var _chunk_thread_seen_alive: bool = false
const CHUNK_LOG_THRESHOLD_MS = 10

# Terrain state
var _final_heightmap: Image
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
	
	# Compatibility renderer guard: disable GPU composition to avoid editor freezes
	if not RenderingServer.get_rendering_device():
		if use_gpu_composition:
			push_warning("[TerrainComposer] Compatibility renderer detected, disabling GPU composition")
		use_gpu_composition = false
	
	# Setup chunk root
	if not _chunk_root:
		_chunk_root = Node3D.new()
		_chunk_root.name = "TerrainChunks"
		add_child(_chunk_root, false, Node.INTERNAL_MODE_BACK)
	
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
	if enable_lod and _chunks.size() > 0:
		_update_chunk_lod()
		if not _heightmap_dirty_pending and _has_dirty_chunks() and not _is_generating:
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
	
	# Clean up helpers
	if _heightmap_composer:
		_heightmap_composer.cleanup()
		_heightmap_composer = null
	
	# Clean up chunks
	for chunk in _chunks.values():
		_free_chunk(chunk)
	_chunks.clear()
	_feature_bounds_cache.clear()

func _scan_features() -> void:
	# Disconnect old signals
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.parameters_changed.is_connected(_on_feature_changed):
			feature.parameters_changed.disconnect(_on_feature_changed)
	
	_feature_nodes.clear()
	_scan_recursive(self)
	
	# Drop cached bounds for removed features
	var removed_features: Array = []
	for cached_feature in _feature_bounds_cache.keys():
		if not _feature_nodes.has(cached_feature):
			removed_features.append(cached_feature)
	
	for removed_feature in removed_features:
		var previous_bounds: Rect2 = _feature_bounds_cache.get(removed_feature, Rect2())
		if previous_bounds != Rect2():
			_mark_chunks_dirty_for_bounds(previous_bounds)
		if _heightmap_composer:
			_heightmap_composer.invalidate_heightmap(removed_feature)
			_heightmap_composer.invalidate_influence(removed_feature)
		_feature_bounds_cache.erase(removed_feature)
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
	_scan_features()
	if auto_update and is_inside_tree():
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
	# Invalidate caches via helper
	if _heightmap_composer:
		_heightmap_composer.invalidate_heightmap(feature)
		
		# Only invalidate influence if influence-related properties changed
		_heightmap_composer.invalidate_influence(feature)
	
	# Mark affected chunks dirty (both previous and current bounds)
	var previous_bounds: Rect2 = _feature_bounds_cache.get(feature, Rect2())
	var current_bounds: Rect2 = _get_feature_world_bounds(feature)
	if previous_bounds != Rect2():
		_mark_chunks_dirty_for_bounds(previous_bounds)
	_mark_chunks_dirty_for_bounds(current_bounds)
	_feature_bounds_cache[feature] = current_bounds
	_heightmap_dirty_pending = true
	
	if auto_update:
		_request_rebuild()

func _on_texture_layer_changed() -> void:
	_update_material()

## Force a complete rebuild with all caches cleared
func force_rebuild() -> void:
	print("[TerrainComposer] Force rebuild - clearing all caches")
	# Clear all caches for a completely fresh rebuild
	if _heightmap_composer:
		_heightmap_composer.clear_all_caches()
	
	# Mark all features as dirty
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.has_method("mark_dirty"):
			feature.mark_dirty()
	
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
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.is_inside_tree() and feature.visible:
			feature_contexts[feature] = feature.prepare_evaluation_context()
	var context_elapsed = Time.get_ticks_msec() - context_start
	print("[TerrainComposer] Rebuild #%d prepared %d contexts in %d ms" % [_rebuild_id, feature_contexts.size(), context_elapsed])
	
	# Compose heightmaps using helper with contexts
	var compose_start = Time.get_ticks_msec()
	_final_heightmap = _heightmap_composer.compose(
		_feature_nodes,
		feature_contexts,
		heightmap_resolution,
		_terrain_bounds,
		base_height,
		use_gpu_composition
	)
	var compose_elapsed = Time.get_ticks_msec() - compose_start
	print("[TerrainComposer] Rebuild #%d compose time: %d ms" % [_rebuild_id, compose_elapsed])
	
	# Step 3: Generate chunk meshes from final heightmap
	var grid_changed = _calculate_chunk_grid()
	if grid_changed:
		_mark_all_chunks_dirty()
	_heightmap_dirty_pending = false
	
	_rebuild_chunks(grid_changed)
	
	# Check for completion in process
	set_process(true)


func _update_material() -> void:
	if _material_builder:
		var shared_material: Material = null
		for chunk in _chunks.values():
			if not chunk.mesh_instance:
				continue
			if not shared_material:
				_material_builder.update_material(chunk.mesh_instance, texture_layers, terrain_material)
				shared_material = chunk.mesh_instance.material_override
			else:
				chunk.mesh_instance.material_override = shared_material

func _calculate_chunk_grid() -> bool:
	if chunk_size <= 0:
		return false
	
	var new_grid = Vector2i(
		ceili(terrain_size.x / float(chunk_size)),
		ceili(terrain_size.y / float(chunk_size))
	)
	var grid_changed = new_grid != _chunk_grid_size
	_chunk_grid_size = new_grid
	
	var new_chunks: Dictionary = {}
	for y in range(_chunk_grid_size.y):
		for x in range(_chunk_grid_size.x):
			var chunk_pos = Vector2i(x, y)
			var chunk: TerrainChunk = _chunks.get(chunk_pos)
			if not chunk:
				chunk = _create_chunk(chunk_pos)
				grid_changed = true
			else:
				_update_chunk_bounds(chunk)
			new_chunks[chunk_pos] = chunk
	
	# Remove chunks no longer in grid
	for key in _chunks.keys():
		if not new_chunks.has(key):
			_free_chunk(_chunks[key])
			grid_changed = true
	
	_chunks = new_chunks
	return grid_changed

func _create_chunk(chunk_pos: Vector2i) -> TerrainChunk:
	var chunk = TerrainChunk.new()
	chunk.position = chunk_pos
	chunk.root = Node3D.new()
	chunk.root.name = "Chunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	if _chunk_root:
		_chunk_root.add_child(chunk.root, false, Node.INTERNAL_MODE_BACK)
	
	chunk.mesh_instance = MeshInstance3D.new()
	chunk.mesh_instance.name = "Mesh"
	chunk.mesh_instance.visible = true
	chunk.mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	chunk.root.add_child(chunk.mesh_instance, false, Node.INTERNAL_MODE_BACK)
	
	chunk.static_body = StaticBody3D.new()
	chunk.static_body.name = "CollisionBody"
	chunk.root.add_child(chunk.static_body, false, Node.INTERNAL_MODE_BACK)
	
	chunk.collision_shape = CollisionShape3D.new()
	chunk.collision_shape.name = "CollisionShape"
	chunk.static_body.add_child(chunk.collision_shape, false, Node.INTERNAL_MODE_BACK)
	
	_update_chunk_bounds(chunk)
	return chunk

func _free_chunk(chunk: TerrainChunk) -> void:
	if chunk and chunk.root and is_instance_valid(chunk.root):
		chunk.root.queue_free()

func _update_chunk_bounds(chunk: TerrainChunk) -> void:
	var origin = _get_terrain_origin_world()
	var chunk_world_pos = Vector2(
		origin.x + chunk.position.x * float(chunk_size),
		origin.y + chunk.position.y * float(chunk_size)
	)
	var size_x = min(chunk_size, terrain_size.x - chunk.position.x * chunk_size)
	var size_y = min(chunk_size, terrain_size.y - chunk.position.y * chunk_size)
	chunk.world_bounds = Rect2(chunk_world_pos, Vector2(size_x, size_y))
	
	# Position chunk root at center in local space
	var chunk_center = Vector3(
		chunk.world_bounds.position.x + chunk.world_bounds.size.x * 0.5,
		0,
		chunk.world_bounds.position.y + chunk.world_bounds.size.y * 0.5
	)
	chunk.root.position = Vector3(
		chunk_center.x - global_position.x,
		0,
		chunk_center.z - global_position.z
	)

func _get_terrain_origin_world() -> Vector2:
	return Vector2(
		global_position.x - terrain_size.x * 0.5,
		global_position.z - terrain_size.y * 0.5
	)

func _extract_chunk_heightmap(chunk: TerrainChunk, lod_level: int) -> Image:
	if not _final_heightmap:
		return null
	
	var res_x = resolution
	var res_y = resolution
	var pixels_per_unit_x = res_x / terrain_size.x
	var pixels_per_unit_y = res_y / terrain_size.y
	
	var start_x = int(round((chunk.world_bounds.position.x - _terrain_bounds.position.x) * pixels_per_unit_x))
	var start_y = int(round((chunk.world_bounds.position.y - _terrain_bounds.position.y) * pixels_per_unit_y))
	var end_x = int(round((chunk.world_bounds.position.x + chunk.world_bounds.size.x - _terrain_bounds.position.x) * pixels_per_unit_x))
	var end_y = int(round((chunk.world_bounds.position.y + chunk.world_bounds.size.y - _terrain_bounds.position.y) * pixels_per_unit_y))
	
	start_x = clampi(start_x, 0, res_x)
	start_y = clampi(start_y, 0, res_y)
	end_x = clampi(end_x, 0, res_x)
	end_y = clampi(end_y, 0, res_y)
	
	var width = max(2, end_x - start_x + 1)
	var height = max(2, end_y - start_y + 1)
	
	var chunk_heightmap = Image.create(width, height, false, Image.FORMAT_RF)
	chunk_heightmap.blit_rect(_final_heightmap, Rect2i(start_x, start_y, width, height), Vector2i.ZERO)
	
	if lod_level > 0 and lod_level < lod_scale_factors.size():
		var scale = lod_scale_factors[lod_level]
		var target_w = max(2, int(round((width - 1) * scale)) + 1)
		var target_h = max(2, int(round((height - 1) * scale)) + 1)
		if target_w != width or target_h != height:
			chunk_heightmap.resize(target_w, target_h, Image.INTERPOLATE_BILINEAR)
	
	return chunk_heightmap

func _get_feature_world_bounds(feature: TerrainFeatureNode) -> Rect2:
	var center = Vector2(feature.global_position.x, feature.global_position.z)
	var half_size: Vector2
	match feature.influence_shape:
		TerrainFeatureNode.InfluenceShape.CIRCLE:
			var radius = max(feature.influence_size.x, feature.influence_size.y)
			half_size = Vector2(radius, radius)
		_:
			half_size = feature.influence_size * 0.5
	return Rect2(center - half_size, half_size * 2.0)

func _get_chunks_affected_by_feature(feature: TerrainFeatureNode) -> Array[TerrainChunk]:
	var bounds = _get_feature_world_bounds(feature)
	return _get_chunks_affected_by_bounds(bounds)

func _get_chunks_affected_by_bounds(bounds: Rect2) -> Array[TerrainChunk]:
	var affected: Array[TerrainChunk] = []
	for chunk in _chunks.values():
		if chunk.world_bounds.intersects(bounds):
			affected.append(chunk)
	return affected

func _mark_chunks_dirty_for_bounds(bounds: Rect2) -> void:
	for chunk in _get_chunks_affected_by_bounds(bounds):
		chunk.is_dirty = true

func _mark_all_chunks_dirty() -> void:
	for chunk in _chunks.values():
		chunk.is_dirty = true

func _has_dirty_chunks() -> bool:
	for chunk in _chunks.values():
		if chunk.is_dirty:
			return true
	return false

func _rebuild_chunks(full_rebuild: bool) -> void:
	if _chunk_thread and _chunk_thread_started and _chunk_thread.is_alive():
		_chunk_thread.wait_to_finish()
	
	var dirty_chunks: Array = []
	for chunk in _chunks.values():
		if full_rebuild or chunk.is_dirty:
			dirty_chunks.append(chunk)
	
	if dirty_chunks.is_empty():
		_is_generating = false
		_rebuild_start_msec = 0
		_initial_rebuild_pending = false
		if _coordinator_rebuild_pending and Engine.has_singleton("TerrainRebuildCoordinator"):
			TerrainRebuildCoordinator.rebuild_completed(self)
			_coordinator_rebuild_pending = false
		terrain_updated.emit()
		return

	_is_generating = true
	
	var jobs: Array = []
	for chunk in dirty_chunks:
		var heightmap = _extract_chunk_heightmap(chunk, chunk.lod_level)
		if not heightmap:
			continue
		jobs.append({
			"key": chunk.position,
			"heightmap": heightmap,
			"size": Vector2(chunk.world_bounds.size.x, chunk.world_bounds.size.y),
			"lod_level": chunk.lod_level
		})
	
	_pending_chunk_results.clear()
	_pending_chunk_rebuild_id = _rebuild_id
	
	var thread_data = {
		"jobs": jobs,
		"rebuild_id": _rebuild_id
	}
	_chunk_thread = Thread.new()
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

func _generate_chunk_meshes_threaded(data: Dictionary) -> void:
	var results: Array = []
	for job in data["jobs"]:
		var heightmap: Image = job["heightmap"]
		var mesh = TerrainMeshGenerator.generate_from_heightmap(heightmap, job["size"])
		results.append({
			"key": job["key"],
			"mesh": mesh,
			"heightmap": heightmap,
			"lod_level": job["lod_level"]
		})
	_pending_chunk_results = results
	_pending_chunk_rebuild_id = data["rebuild_id"]

func _apply_pending_chunk_results() -> void:
	if _pending_chunk_results.is_empty():
		return
	
	for result in _pending_chunk_results:
		var key: Vector2i = result["key"]
		var chunk: TerrainChunk = _chunks.get(key)
		if not chunk:
			continue
		chunk.mesh_instance.mesh = result["mesh"]
		chunk.mesh_instance.visible = true
		chunk.heightmap = result["heightmap"]
		chunk.lod_level = result["lod_level"]
		chunk.is_dirty = false
		_update_chunk_collision(chunk)
	
	_update_material()
	_pending_chunk_results.clear()

func _on_chunk_generation_completed() -> void:
	_apply_pending_chunk_results()
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

func _update_chunk_collision(chunk: TerrainChunk) -> void:
	if not chunk or not chunk.collision_shape:
		return
	
	var start_time = Time.get_ticks_msec()
	if generate_collision and chunk.heightmap:
		chunk.static_body.visible = true
		var height_shape = HeightMapShape3D.new()
		var width = chunk.heightmap.get_width()
		var depth = chunk.heightmap.get_height()
		height_shape.map_width = width
		height_shape.map_depth = depth
		
		var map_data: PackedFloat32Array = PackedFloat32Array()
		map_data.resize(width * depth)
		for z in range(depth):
			for x in range(width):
				map_data[z * width + x] = chunk.heightmap.get_pixel(x, z).r
		height_shape.map_data = map_data
		chunk.collision_shape.shape = height_shape
		
		chunk.collision_shape.scale = Vector3(
			chunk.world_bounds.size.x / (width - 1),
			1.0,
			chunk.world_bounds.size.y / (depth - 1)
		)
		chunk.collision_shape.position = Vector3(
			-chunk.world_bounds.size.x * 0.5,
			0,
			-chunk.world_bounds.size.y * 0.5
		)
		var elapsed = Time.get_ticks_msec() - start_time
		if elapsed >= CHUNK_LOG_THRESHOLD_MS:
			push_warning("[TerrainComposer] Slow chunk collision: %dx%d in %d ms" % [width, depth, elapsed])
	elif generate_collision and chunk.mesh_instance.mesh:
		chunk.static_body.visible = true
		chunk.collision_shape.shape = chunk.mesh_instance.mesh.create_trimesh_shape()
		var elapsed = Time.get_ticks_msec() - start_time
		if elapsed >= CHUNK_LOG_THRESHOLD_MS:
			push_warning("[TerrainComposer] Slow chunk trimesh collision: %d ms" % elapsed)
	else:
		chunk.static_body.visible = false
		chunk.collision_shape.shape = null

func _update_all_chunk_collisions() -> void:
	for chunk in _chunks.values():
		_update_chunk_collision(chunk)

func _update_chunk_lod() -> void:
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return
	
	var camera_pos = camera.global_position
	for chunk in _chunks.values():
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
