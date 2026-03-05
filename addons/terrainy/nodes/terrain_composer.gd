@tool
class_name TerrainComposer
extends Node3D

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")
const TerrainTextureLayer = preload("res://addons/terrainy/resources/terrain_texture_layer.gd")
const TerrainMeshGenerator = preload("res://addons/terrainy/helpers/terrain_mesh_generator.gd")
const TerrainHeightmapBuilder = preload("res://addons/terrainy/helpers/terrain_heightmap_builder.gd")
const TerrainMaterialBuilder = preload("res://addons/terrainy/helpers/terrain_material_builder.gd")
const EvaluationContext = preload("res://addons/terrainy/nodes/evaluation_context.gd")
const TerrainBakeMetadata = preload("res://addons/terrainy/resources/terrain_bake_metadata.gd")

## Simple terrain composer - generates mesh from TerrainFeatureNodes

signal terrain_updated
signal texture_layers_changed

# Constants
const MAX_TERRAIN_RESOLUTION = 4096
const MAX_FEATURE_COUNT = 64
const MAX_CHUNK_SIZE = 8192
const REBUILD_DEBOUNCE_SEC = 0.3  # Debounce rapid changes (e.g., gizmo manipulation)
const TERRAIN_BAKE_VERSION = 2
const TERRAIN_BAKE_ROOT_DIR = "res://.terrainy_bakes"

## Size of the terrain in world units (X,Z)
@export var terrain_size: Vector2 = Vector2(100, 100):
	set(value):
		terrain_size = value
		_maybe_invalidate_bake("terrain_size changed")
		if _heightmap_composer:
			_heightmap_composer.clear_all_caches()
		if auto_update and is_inside_tree():
			rebuild_terrain()

## Resolution of the terrain heightmap (number of vertices along one axis)
@export var resolution: int = 128:
	set(value):
		resolution = clamp(value, 16, MAX_TERRAIN_RESOLUTION)
		_maybe_invalidate_bake("resolution changed")
		if _heightmap_composer:
			_heightmap_composer.clear_all_caches()
		_mark_all_chunks_dirty()
		if auto_update and is_inside_tree():
			rebuild_terrain()

## Base height offset for the terrain
@export var base_height: float = 0.0:
	set(value):
		base_height = value
		_maybe_invalidate_bake("base_height changed")
		_mark_all_chunks_dirty()
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
		_maybe_invalidate_bake("chunk_size changed")
		_mark_all_chunks_dirty()
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
		_maybe_invalidate_bake("enable_lod changed")
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

@export_group("Baking")

## Enable baked terrain loading on startup (skips procedural rebuild when valid)
@export var bake_enabled: bool = false

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
	var hole_mask: Image = null

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

# Baking state
var _pending_bake_write: bool = false
var _is_loading_bake: bool = false

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
	var should_try_baked_load = bake_enabled or _has_baked_metadata()
	if should_try_baked_load and _try_load_baked_terrain():
		_initial_rebuild_pending = false
		_update_material()
		_update_all_chunk_collision_properties()
		terrain_updated.emit()
		set_process(enable_lod)
		return
	elif should_try_baked_load:
		print("[TerrainComposer] Bake enabled but no valid baked cache found, running procedural rebuild")

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
	if enable_lod and _chunks.size() > 0 and _final_heightmap:
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
	var previous_features = _feature_nodes.duplicate()
	# Disconnect old signals
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.parameters_changed.is_connected(_on_feature_changed):
			feature.parameters_changed.disconnect(_on_feature_changed)
	
	_feature_nodes.clear()
	_scan_recursive(self)

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
			_mark_chunks_dirty_for_bounds(previous_bounds)
		if _heightmap_composer:
			_heightmap_composer.invalidate_heightmap(removed_feature)
			_heightmap_composer.invalidate_influence(removed_feature)
		_feature_bounds_cache.erase(removed_feature)
		_heightmap_dirty_pending = true

	if features_changed:
		_mark_all_chunks_dirty()
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
	_maybe_invalidate_bake("feature tree changed")
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
	_maybe_invalidate_bake("feature parameters changed")

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

func bake_terrain_to_disk() -> void:
	if _is_generating:
		push_warning("[TerrainComposer] Bake requested while terrain is still generating")
		return

	bake_enabled = true
	_pending_bake_write = true
	force_rebuild()

func clear_baked_terrain() -> void:
	_invalidate_bake_cache("manual clear")

func _maybe_invalidate_bake(reason: String) -> void:
	if not bake_enabled:
		return
	if not is_inside_tree():
		return
	if _is_loading_bake:
		return
	_invalidate_bake_cache(reason)

func _get_bake_cache_dir() -> String:
	var scene_hint = _get_scene_hint_path()
	var node_hint = _get_scene_relative_node_path()
	var stable_id = (scene_hint + "::" + node_hint).sha256_text().substr(0, 16)
	return "%s/%s" % [TERRAIN_BAKE_ROOT_DIR, stable_id]

func _get_scene_hint_path() -> String:
	if Engine.is_editor_hint():
		var edited_scene = get_tree().edited_scene_root
		if edited_scene and not edited_scene.scene_file_path.is_empty():
			return edited_scene.scene_file_path

	if get_tree().current_scene and not get_tree().current_scene.scene_file_path.is_empty():
		return get_tree().current_scene.scene_file_path

	# Unsaved scenes still get a deterministic fallback in the current session.
	return "unsaved_scene"

func _get_scene_relative_node_path() -> String:
	var scene_root: Node = null
	if Engine.is_editor_hint():
		scene_root = get_tree().edited_scene_root
	if not scene_root:
		scene_root = get_tree().current_scene

	if scene_root and scene_root == self:
		return "."
	if scene_root and scene_root.is_ancestor_of(self):
		return str(scene_root.get_path_to(self))

	# Fallback if scene root cannot be resolved yet.
	return name

func _get_bake_metadata_path() -> String:
	return "%s/terrain_bake_metadata.res" % _get_bake_cache_dir()

func _has_baked_metadata() -> bool:
	return ResourceLoader.exists(_get_bake_metadata_path())

func _ensure_bake_directory(path: String) -> bool:
	var absolute_path = ProjectSettings.globalize_path(path)
	var error = DirAccess.make_dir_recursive_absolute(absolute_path)
	return error == OK or error == ERR_ALREADY_EXISTS

func _remove_resource_file(res_path: String) -> void:
	if res_path.is_empty() or not ResourceLoader.exists(res_path):
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(res_path))

func _collect_bake_paths(metadata: TerrainBakeMetadata) -> Dictionary:
	var paths := {}
	if not metadata:
		return paths

	for entry in metadata.chunk_entries:
		if not (entry is Dictionary):
			continue
		var mesh_path = str(entry.get("mesh_path", ""))
		var collision_path = str(entry.get("collision_path", ""))
		if not mesh_path.is_empty():
			paths[mesh_path] = true
		if not collision_path.is_empty():
			paths[collision_path] = true
	return paths

func _load_bake_metadata() -> TerrainBakeMetadata:
	var metadata_path = _get_bake_metadata_path()
	if not ResourceLoader.exists(metadata_path):
		return null
	return load(metadata_path) as TerrainBakeMetadata

func _cleanup_stale_bake_files(previous_metadata: TerrainBakeMetadata, keep_paths: Dictionary) -> void:
	if not previous_metadata:
		return
	var previous_paths = _collect_bake_paths(previous_metadata)
	for path in previous_paths.keys():
		if not keep_paths.has(path):
			_remove_resource_file(path)

func _build_feature_bake_signature(feature: TerrainFeatureNode) -> Dictionary:
	var relative_feature_path = ""
	if is_ancestor_of(feature):
		relative_feature_path = str(get_path_to(feature))
	else:
		relative_feature_path = feature.name

	var snapshot := {
		"path": relative_feature_path,
		"script": "",
		"transform": var_to_str(feature.transform)
	}

	if feature.get_script() and feature.get_script() is Script:
		snapshot["script"] = (feature.get_script() as Script).resource_path

	var property_names: Array[String] = []
	for property_info in feature.get_property_list():
		var usage = int(property_info.get("usage", 0))
		if (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var property_name = str(property_info.get("name", ""))
		if property_name.begins_with("_"):
			continue
		property_names.append(property_name)

	property_names.sort()
	var property_snapshot := {}
	for property_name in property_names:
		property_snapshot[property_name] = _serialize_bake_value(feature.get(property_name))

	snapshot["properties"] = property_snapshot
	return snapshot

func _serialize_bake_value(value: Variant) -> Variant:
	var value_type = typeof(value)

	if value_type == TYPE_ARRAY:
		var result: Array = []
		for item in value:
			result.append(_serialize_bake_value(item))
		return result

	if value_type == TYPE_DICTIONARY:
		var result := {}
		var keys: Array = value.keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool:
			return str(a) < str(b)
		)
		for key in keys:
			result[str(key)] = _serialize_bake_value(value[key])
		return result

	if value_type == TYPE_OBJECT:
		if value == null:
			return null

		if value is Resource:
			var resource = value as Resource
			if not resource.resource_path.is_empty():
				return {
					"__resource_path": resource.resource_path
				}
			return {
				"__resource_class": resource.get_class()
			}

		if value is Node:
			var node = value as Node
			if is_ancestor_of(node):
				return {
					"__node_path": str(get_path_to(node))
				}
			return {
				"__node_name": node.name,
				"__node_class": node.get_class()
			}

		return {
			"__object_class": value.get_class()
		}

	return value

func _build_bake_hash() -> String:
	var feature_payload: Array = []
	var payload := {
		"version": TERRAIN_BAKE_VERSION,
		"terrain_size": [terrain_size.x, terrain_size.y],
		"resolution": resolution,
		"base_height": base_height,
		"chunk_size": chunk_size,
		"enable_lod": enable_lod,
		"lod_distances": lod_distances,
		"lod_scale_factors": lod_scale_factors,
		"generate_collision": generate_collision,
		"features": feature_payload
	}

	var sorted_features: Array[TerrainFeatureNode] = []
	for feature in _feature_nodes:
		if is_instance_valid(feature):
			sorted_features.append(feature)

	sorted_features.sort_custom(func(a: TerrainFeatureNode, b: TerrainFeatureNode) -> bool:
		return str(a.get_path()) < str(b.get_path())
	)

	for feature in sorted_features:
		feature_payload.append(_build_feature_bake_signature(feature))

	return JSON.stringify(payload).sha256_text()

func _save_baked_terrain() -> bool:
	if _chunks.is_empty():
		push_warning("[TerrainComposer] Cannot bake terrain because no chunks are available")
		return false

	var cache_dir = _get_bake_cache_dir()
	if not _ensure_bake_directory(cache_dir):
		push_error("[TerrainComposer] Failed to create bake directory: %s" % cache_dir)
		return false

	var previous_metadata = _load_bake_metadata()
	var metadata = TerrainBakeMetadata.new()
	metadata.bake_version = TERRAIN_BAKE_VERSION
	metadata.terrain_hash = _build_bake_hash()

	var keep_paths := {}
	for chunk in _chunks.values():
		if not chunk.mesh_instance or not chunk.mesh_instance.mesh:
			push_error("[TerrainComposer] Chunk %s has no mesh, bake aborted" % str(chunk.position))
			return false

		var chunk_suffix = "%d_%d" % [chunk.position.x, chunk.position.y]
		var mesh_path = "%s/chunk_%s_mesh.res" % [cache_dir, chunk_suffix]
		var mesh_error = ResourceSaver.save(chunk.mesh_instance.mesh, mesh_path)
		if mesh_error != OK:
			push_error("[TerrainComposer] Failed to save baked mesh: %s (error %d)" % [mesh_path, mesh_error])
			return false

		keep_paths[mesh_path] = true
		var entry := {
			"x": chunk.position.x,
			"y": chunk.position.y,
			"mesh_path": mesh_path,
			"lod_level": chunk.lod_level
		}

		if generate_collision:
			var collision_shape: Shape3D = null
			if chunk.collision_shape and chunk.collision_shape.shape:
				collision_shape = chunk.collision_shape.shape
			elif chunk.mesh_instance.mesh:
				collision_shape = chunk.mesh_instance.mesh.create_trimesh_shape()

			if collision_shape:
				var collision_path = "%s/chunk_%s_collision.res" % [cache_dir, chunk_suffix]
				var collision_error = ResourceSaver.save(collision_shape, collision_path)
				if collision_error != OK:
					push_error("[TerrainComposer] Failed to save baked collision: %s (error %d)" % [collision_path, collision_error])
					return false
				entry["collision_path"] = collision_path
				entry["collision_scale"] = [chunk.collision_shape.scale.x, chunk.collision_shape.scale.y, chunk.collision_shape.scale.z]
				entry["collision_position"] = [chunk.collision_shape.position.x, chunk.collision_shape.position.y, chunk.collision_shape.position.z]
				keep_paths[collision_path] = true

		metadata.chunk_entries.append(entry)

	var metadata_path = _get_bake_metadata_path()
	var metadata_error = ResourceSaver.save(metadata, metadata_path)
	if metadata_error != OK:
		push_error("[TerrainComposer] Failed to save bake metadata: %s (error %d)" % [metadata_path, metadata_error])
		return false

	keep_paths[metadata_path] = true
	_cleanup_stale_bake_files(previous_metadata, keep_paths)
	print("[TerrainComposer] Baked terrain saved to %s" % cache_dir)
	return true

func _try_load_baked_terrain() -> bool:
	var metadata = _load_bake_metadata()
	if not metadata:
		return false

	if metadata.bake_version != TERRAIN_BAKE_VERSION:
		_invalidate_bake_cache("bake version mismatch")
		return false

	var expected_hash = _build_bake_hash()
	if metadata.terrain_hash != expected_hash:
		_invalidate_bake_cache("bake hash mismatch")
		return false

	_calculate_chunk_grid()

	var entries_by_key := {}
	for entry in metadata.chunk_entries:
		if not (entry is Dictionary):
			continue
		var key = Vector2i(int(entry.get("x", -1)), int(entry.get("y", -1)))
		entries_by_key[key] = entry

	if entries_by_key.size() != _chunks.size():
		_invalidate_bake_cache("chunk count mismatch")
		return false

	_is_loading_bake = true
	for chunk in _chunks.values():
		if not entries_by_key.has(chunk.position):
			_is_loading_bake = false
			_invalidate_bake_cache("missing baked chunk entry")
			return false

		var chunk_entry: Dictionary = entries_by_key[chunk.position]
		var mesh_path = str(chunk_entry.get("mesh_path", ""))
		if mesh_path.is_empty() or not ResourceLoader.exists(mesh_path):
			_is_loading_bake = false
			_invalidate_bake_cache("missing baked mesh resource")
			return false

		var mesh = load(mesh_path)
		if not (mesh is Mesh):
			_is_loading_bake = false
			_invalidate_bake_cache("invalid baked mesh resource")
			return false

		chunk.mesh_instance.mesh = mesh
		chunk.mesh_instance.visible = true
		chunk.heightmap = null
		chunk.hole_mask = null
		chunk.lod_level = int(chunk_entry.get("lod_level", 0))
		chunk.is_dirty = false

		if generate_collision:
			var collision_path = str(chunk_entry.get("collision_path", ""))
			if collision_path.is_empty() or not ResourceLoader.exists(collision_path):
				_is_loading_bake = false
				_invalidate_bake_cache("missing baked collision resource")
				return false

			var collision_shape = load(collision_path)
			if not (collision_shape is Shape3D):
				_is_loading_bake = false
				_invalidate_bake_cache("invalid baked collision resource")
				return false

			chunk.collision_shape.shape = collision_shape
			var collision_scale = chunk_entry.get("collision_scale", null)
			var collision_position = chunk_entry.get("collision_position", null)
			if collision_scale is Array and collision_scale.size() == 3:
				chunk.collision_shape.scale = Vector3(float(collision_scale[0]), float(collision_scale[1]), float(collision_scale[2]))
			else:
				# Older bake format had no collision transform; fallback to mesh-derived collision.
				chunk.collision_shape.shape = null
				_update_chunk_collision(chunk)
				continue

			if collision_position is Array and collision_position.size() == 3:
				chunk.collision_shape.position = Vector3(float(collision_position[0]), float(collision_position[1]), float(collision_position[2]))
			else:
				chunk.collision_shape.position = Vector3.ZERO
			chunk.static_body.visible = true
		else:
			chunk.collision_shape.shape = null
			chunk.static_body.visible = false

	_is_loading_bake = false
	print("[TerrainComposer] Loaded baked terrain from %s" % _get_bake_cache_dir())
	return true

func _invalidate_bake_cache(reason: String) -> void:
	var metadata_path = _get_bake_metadata_path()
	if not ResourceLoader.exists(metadata_path):
		return

	var metadata = _load_bake_metadata()
	if metadata:
		for resource_path in _collect_bake_paths(metadata).keys():
			_remove_resource_file(resource_path)

	_remove_resource_file(metadata_path)
	_pending_bake_write = false
	print("[TerrainComposer] Invalidated baked terrain (%s)" % reason)

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
	_mark_all_chunks_dirty()
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
	var compose_result = _heightmap_composer.compose(
		_feature_nodes,
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
	var grid_changed = _calculate_chunk_grid()
	if grid_changed:
		_mark_all_chunks_dirty()
	_heightmap_dirty_pending = false
	
	_rebuild_chunks(grid_changed)
	
	# Check for completion in process
	set_process(true)

func _get_chunk_generation_lod(chunk: TerrainChunk) -> int:
	if _pending_bake_write:
		# Bake always captures highest fidelity so every chunk matches.
		return 0
	return chunk.lod_level


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
				if _chunk_root and chunk.root and not chunk.root.get_parent():
					_chunk_root.add_child(chunk.root, false, Node.INTERNAL_MODE_BACK)
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
	chunk.static_body.collision_layer = collision_layer
	chunk.static_body.collision_mask = collision_mask
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
	var grid_x = max(1, _chunk_grid_size.x)
	var grid_y = max(1, _chunk_grid_size.y)
	# Distribute terrain extents evenly across the chunk grid to avoid a tiny remainder chunk.
	var step_x = terrain_size.x / float(grid_x)
	var step_y = terrain_size.y / float(grid_y)
	var start_x = chunk.position.x * step_x
	var start_y = chunk.position.y * step_y
	var end_x = (chunk.position.x + 1) * step_x
	var end_y = (chunk.position.y + 1) * step_y
	var chunk_world_pos = Vector2(
		origin.x + start_x,
		origin.y + start_y
	)
	var size_x = max(0.001, end_x - start_x)
	var size_y = max(0.001, end_y - start_y)
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

func _extract_chunk_heightmap(chunk: TerrainChunk, lod_level: int) -> Dictionary:
	if not _final_heightmap:
		return {}
	
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
			var radius = max(feature.influence_size.x, feature.influence_size.y)
			half_size = Vector2(radius, radius)
			return Rect2(center - half_size, half_size * 2.0)
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
	
	for result in _pending_chunk_results:
		var key: Vector2i = result["key"]
		var chunk: TerrainChunk = _chunks.get(key)
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

	if _pending_bake_write:
		_pending_bake_write = false
		_save_baked_terrain()

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
		
		var has_holes := chunk.hole_mask != null
		var hole_data: PackedFloat32Array
		if has_holes:
			hole_data = chunk.hole_mask.get_data().to_float32_array()
		
		for z in range(depth):
			for x in range(width):
				var idx = z * width + x
				if has_holes and hole_data[idx] >= 0.5:
					map_data[idx] = -1000000.0  # Very negative value for holes
				else:
					map_data[idx] = chunk.heightmap.get_pixel(x, z).r
		
		height_shape.map_data = map_data
		chunk.collision_shape.shape = height_shape
		
		chunk.collision_shape.scale = Vector3(
			chunk.world_bounds.size.x / float(width - 1),
			1.0,
			chunk.world_bounds.size.y / float(depth - 1)
		)
		chunk.collision_shape.position = Vector3.ZERO
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

func _update_all_chunk_collision_properties() -> void:
	for chunk in _chunks.values():
		if chunk and chunk.static_body:
			chunk.static_body.collision_layer = collision_layer
			chunk.static_body.collision_mask = collision_mask

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
