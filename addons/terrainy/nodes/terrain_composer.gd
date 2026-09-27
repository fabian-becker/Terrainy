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
const TerrainCollisionBuilder = preload("res://addons/terrainy/helpers/terrain_collision_builder.gd")
const TerrainChunkPipeline = preload("res://addons/terrainy/helpers/terrain_chunk_pipeline.gd")
const TerrainDiagnostics = preload("res://addons/terrainy/helpers/terrain_diagnostics.gd")
const TerrainNavigationBuilder = preload("res://addons/terrainy/helpers/terrain_navigation_builder.gd")


## Simple terrain composer - generates mesh from TerrainFeatureNodes

signal terrain_updated
signal texture_layers_changed
## Emitted when a navigation bake finished; [param navigation_mesh] is the baked resource.
signal navigation_mesh_baked(navigation_mesh: NavigationMesh)

# Constants
const MAX_TERRAIN_RESOLUTION = 4096
const MAX_FEATURE_COUNT = 64
const MAX_CHUNK_SIZE = 8192
const REBUILD_DEBOUNCE_SEC = 0.3  # Debounce rapid changes (e.g., gizmo manipulation)

## Collision detail presets; see [member collision_quality].
enum CollisionQuality { EXACT, BALANCED, FAST }

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

## Evaluate feature heightmaps with the GPU compute kernels when possible. Feature types
## whose kernels do not use noise (hills, craters, volcanoes, shapes, gradients,
## heightmaps) are guaranteed to match the CPU result.
@export var use_gpu_feature_evaluation: bool = true

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
## Main-thread milliseconds a single frame may spend applying finished chunk meshes and collision
## shapes. Worker results are queued and drained over several frames, so a rebuild of a large
## terrain no longer blocks the editor in one long frame. 0 applies every finished result in the
## frame it arrives (the behaviour before frame budgeting, useful for baking and tests).
@export_range(0, 100, 1) var chunk_apply_budget_ms: int = 8

@export_group("LOD")
## Enable Level of Detail (LOD) for terrain chunks
@export var enable_lod: bool = true:
	set(value):
		enable_lod = value
		if enable_lod and is_inside_tree() and _chunk_manager and _chunk_manager.get_chunks().size() > 0:
			set_process(true)
		if auto_update and is_inside_tree():
			_request_rebuild()

## Distances at which LOD levels switch (in world units)
@export var lod_distances: Array[float] = [500.0, 1000.0, 2000.0]
## Scale factors for each LOD level (1.0 = full res, 0.5 = half res, etc.)
@export var lod_scale_factors: Array[float] = [1.0, 0.5, 0.25, 0.125]

@export_group("Material")
## Material to use for the terrain chunks
@export var terrain_material: Material

## Edge length of the Texture2DArray used for the terrain texture layers. Sources that
## are larger than this are downscaled (never upscaled).
@export_range(256, 8192, 1) var texture_array_size: int = 2048:
	set(value):
		texture_array_size = value
		_update_material()

## Print pipeline timings and cache statistics to the console. Also enables the one-line
## per-rebuild report emitted by TerrainDiagnostics.
@export var debug_logging: bool = false:
	set(value):
		debug_logging = value
		if _diagnostics:
			_diagnostics.set_report_enabled(value)
		if _heightmap_composer:
			_heightmap_composer.debug_logging = value

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
## Create collision shapes for the terrain chunks.
## Collision is applied by the rebuild pipeline, so toggling it never blocks the editor: the
## affected chunks are queued and updated over the following frames.
@export var generate_collision: bool = true:
	set(value):
		if generate_collision == value:
			return
		generate_collision = value
		_mark_collision_dirty()

## Collision detail for the chunks that need a triangle mesh (the ones whose hole carving removed
## triangles - a HeightMapShape3D would fill the hole back in).
##
## Physics shape updates cost roughly 2 us per triangle and a 513x513 chunk carries over 500k of
## them, so the preset is expressed as a triangle budget per chunk:
##
## - **Exact**: every visual triangle (also the LOD-independent choice, since it is a budget of 0)
## - **Balanced**: aims for 65 536 triangles
## - **Fast**: aims for 8 192 triangles
##
## The sample step has to divide the chunk resolution evenly (otherwise neighbouring chunks would
## not line up), so a preset can overshoot its budget but never undershoot it: on a 513x513 chunk
## Balanced lands on a step of 2 (131 072 triangles) and Fast on 8 (8 192).
##
## Chunks without holes always use an exact HeightMapShape3D and ignore this setting.
@export var collision_quality: CollisionQuality = CollisionQuality.EXACT:
	set(value):
		if collision_quality == value:
			return
		collision_quality = value
		_mark_collision_dirty()

## Optional triangle budget per collision chunk; 0 uses the budget of [member collision_quality].
## Ignored by the Exact preset unless it is set to a positive value.
@export_range(0, 2000000, 1) var collision_triangle_budget: int = 0:
	set(value):
		var clamped := maxi(value, 0)
		if collision_triangle_budget == clamped:
			return
		collision_triangle_budget = clamped
		_mark_collision_dirty()

@export_flags_3d_physics var collision_layer: int = 1:
	set(value):
		if collision_layer == value:
			return
		collision_layer = value
		_mark_collision_layer_dirty()

@export_flags_3d_physics var collision_mask: int = 1:
	set(value):
		if collision_mask == value:
			return
		collision_mask = value
		_mark_collision_layer_dirty()

@export_group("Navigation")
## Bake a navigation mesh for the terrain surface and expose it on an internal
## [NavigationRegion3D] child, so Godot's navigation agents can path over the terrain without the
## project having to bake it from the chunk meshes itself.
##
## The bake runs after a rebuild has landed (never inside the rebuild) and follows
## [member use_multithreading]: on a worker thread when it is on, blocking when it is off.
@export var generate_navigation_mesh: bool = false:
	set(value):
		if generate_navigation_mesh == value:
			return
		generate_navigation_mesh = value
		_mark_navigation_dirty()

## Settings template for the bakes (cell size, agent radius and height, max slope, ...). Every
## bake copies these onto a fresh [NavigationMesh], so the baked result is always a new resource
## and the navigation server is always told about it. Leave empty for the engine defaults.
@export var navigation_mesh_template: NavigationMesh:
	set(value):
		if navigation_mesh_template == value:
			return
		navigation_mesh_template = value
		_mark_navigation_dirty()

## Triangle budget per chunk for the navigation bake; 0 uses
## [constant TerrainNavigationBuilder.DEFAULT_BUDGET]. The bake rasterises into cells, so a
## budget far below the number of visual triangles costs no quality (see the class comment of
## [TerrainNavigationBuilder]).
@export_range(0, 2000000, 1) var navigation_triangle_budget: int = 0:
	set(value):
		var clamped := maxi(value, 0)
		if navigation_triangle_budget == clamped:
			return
		navigation_triangle_budget = clamped
		_mark_navigation_dirty()

var _is_generating: bool = false

# Subsystem helpers
var _chunk_manager: ChunkManager = null
var _scatter_manager: ScatterManager = null
var _bake_exporter: BakeExporter = null
var _heightmap_composer: TerrainHeightmapBuilder = null
var _material_builder: TerrainMaterialBuilder = null
var _diagnostics: TerrainDiagnostics = null

# Feature tracking
var _feature_nodes: Array[TerrainFeatureNode] = []
var _height_feature_nodes: Array[TerrainFeatureNode] = []
var _scatter_nodes: Array[ScatterNode] = []
var _feature_bounds_cache: Dictionary = {}  # feature -> Rect2

# Chunk mesh generation and collision refreshes are dispatched through _pipeline, which owns the
# worker pool group tasks and the result queues. The composer drains the queues under a per-frame
# time budget, so the main-thread cost of a rebuild is spread over several frames.
var _pipeline: TerrainChunkPipeline = null
var _pending_chunk_rebuild_id: int = 0

# Collision and navigation changes are coalesced: assigning several properties (inspector, scene
# load, tool script) used to run one full refresh each. The setters only record the intent and
# _process() runs the work once per frame instead.
var _collision_refresh_pending: bool = false
var _collision_layer_pending: bool = false

# Navigation bake state. A bake is only started once the rebuild has landed and the source
# geometry is built from the chunk heightmaps (see TerrainNavigationBuilder).
var _navigation_region: NavigationRegion3D = null
var _navigation_mesh: NavigationMesh = null
var _navigation_dirty: bool = false
var _navigation_baking: bool = false

# Terrain state
var _final_heightmap: Image
var _final_hole_mask: Image
var _terrain_bounds: Rect2

# Cached evaluation contexts from last rebuild (for public query APIs)
var _cached_feature_contexts: Dictionary = {}

# Rebuild timing
var _rebuild_start_msec: int = 0
var _rebuild_id: int = 0
var _coordinator_rebuild_pending: bool = false
var _heightmap_dirty_pending: bool = false

## Set whenever the composed heightmap content may have changed; consumed by the next
## scatter refresh so unchanged scatters keep their instances.
var _heightmap_content_dirty: bool = true

## Signature of the inputs that shape the composed heightmap (bounds/resolution/base
## height). Used to detect content changes without hashing the composed image.
var _last_compose_signature: String = ""

# Rebuild debouncing
var _rebuild_timer: Timer = null
var _pending_rebuild: bool = false
var _rebuild_after_current: bool = false
var _initial_rebuild_pending: bool = true

# LOD camera position cache (skip per-frame iteration when camera is static)
var _lod_last_camera_pos: Vector3 = Vector3.ZERO
var _lod_last_camera_valid: bool = false

func _ready() -> void:
	set_process(false)  # Only enable when mesh generation is running
	_initial_rebuild_pending = true
	
	# Initialize helpers
	_heightmap_composer = TerrainHeightmapBuilder.new()
	_heightmap_composer.debug_logging = debug_logging
	_material_builder = TerrainMaterialBuilder.new()
	_chunk_manager = ChunkManager.new(self)
	_scatter_manager = ScatterManager.new(self)
	_bake_exporter = BakeExporter.new()
	_diagnostics = TerrainDiagnostics.new()
	_diagnostics.set_report_enabled(debug_logging)
	_pipeline = TerrainChunkPipeline.new()
	_pipeline.diagnostics = _diagnostics
	_setup_pipeline_options()
	
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
	# Move finished worker results into the queues, then drain them under a frame budget so a
	# rebuild never blocks the main thread for a whole second.
	if _pipeline:
		_pipeline.poll()
		if _pipeline.has_mesh_results():
			_apply_pending_chunk_results(true)
		if _pipeline.has_collision_results():
			_apply_pending_collision_results(true)

	# Property setters (which may be called many times while a scene loads or an inspector edit
	# is being made) only queue this work; it runs here, at most once per frame, and only once
	# the mesh and collision queues above are empty so a refresh never interleaves with a rebuild.
	if not _has_worker_work() and _collision_layer_pending:
		_collision_layer_pending = false
		_update_all_chunk_collision_properties()
	if not _has_worker_work() and _collision_refresh_pending:
		_collision_refresh_pending = false
		_update_all_chunk_collisions()

	# Update LODs if enabled
	if enable_lod and _chunk_manager and _chunk_manager.get_chunks().size() > 0 and _final_heightmap:
		_update_chunk_lod()
		if not _heightmap_dirty_pending and _chunk_manager.has_dirty_chunks() and not _is_generating:
			_rebuild_chunks(false)

	if not is_rebuilding():
		_maybe_bake_navigation_mesh()
		if not enable_lod and not _navigation_dirty:
			set_process(false)

func _exit_tree() -> void:
	# Cancel any queued rebuild
	var _coord = Engine.get_singleton("TerrainRebuildCoordinator") if Engine.has_singleton("TerrainRebuildCoordinator") else null
	if _coord:
		_coord.cancel_rebuild(self)
		# Release active rebuild slot if this composer was mid-rebuild
		if _coordinator_rebuild_pending:
			_coord.rebuild_completed(self)
			_coordinator_rebuild_pending = false
	
	if _pipeline and not _pipeline.wait_for_pending():
		# Workers never touch this node, so abandoning the tasks is safe - their holders outlive
		# them via the bound callable.
		push_warning("[TerrainComposer] Worker tasks did not finish in time, forcing exit")

	# A navigation bake in flight is owned by the navigation server; dropping the references keeps
	# the (static) completion callback from touching anything after teardown.
	_navigation_baking = false
	_navigation_dirty = false
	_navigation_region = null
	_navigation_mesh = null
	
	# Disconnect feature signals to prevent transform notifications during teardown
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.parameters_changed.is_connected(_feature_changed_callable(feature)):
			feature.parameters_changed.disconnect(_feature_changed_callable(feature))
	
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

## The bound callable used to subscribe to a feature's parameters_changed signal.
## Bound callables must be constructed identically for connect/disconnect/is_connected to
## match, so everything goes through this helper.
func _feature_changed_callable(feature: TerrainFeatureNode) -> Callable:
	return _on_feature_changed.bind(feature)

func _scan_features() -> void:
	var previous_features = _feature_nodes.duplicate()
	# Disconnect old signals
	for feature in _feature_nodes:
		var cb := _feature_changed_callable(feature)
		if is_instance_valid(feature) and feature.parameters_changed.is_connected(cb):
			feature.parameters_changed.disconnect(cb)
	
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
		if not is_instance_valid(feature) or not feature.is_inside_tree():
			continue
		if _feature_bounds_cache.has(feature):
			continue
		# Non-height features (scatter/mask nodes) never move terrain geometry
		if not feature.affects_heightmap():
			continue
		var bounds = _get_feature_world_bounds(feature)
		_feature_bounds_cache[feature] = bounds
		if _chunk_manager:
			_chunk_manager.mark_dirty_for_bounds(bounds)
		_heightmap_dirty_pending = true

	if features_changed:
		if _chunk_manager:
			_chunk_manager.mark_all_dirty()
		_heightmap_dirty_pending = true
	
	_heightmap_content_dirty = true
	
	# Connect new signals (guarded so repeated scans cannot stack duplicate connections)
	for feature in _feature_nodes:
		if not is_instance_valid(feature):
			continue
		var cb := _feature_changed_callable(feature)
		if not feature.parameters_changed.is_connected(cb):
			feature.parameters_changed.connect(cb)

func _scan_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is TerrainFeatureNode:
			if _feature_nodes.size() >= MAX_FEATURE_COUNT:
				push_warning("[TerrainComposer] Maximum feature count (%d) reached, ignoring '%s'" % [MAX_FEATURE_COUNT, child.name])
				continue
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

	# Non-height features (scatter/object placement) cannot change the heightmap or the
	# terrain mesh, so only their own instances need to be regenerated. This keeps
	# placement edits (density, seed, scene, ...) from triggering a full rebuild.
	if not feature.affects_heightmap():
		_refresh_single_feature_instances(feature)
		if auto_update:
			_request_rebuild()
		return

	# Invalidate caches via helper
	if _heightmap_composer:
		_heightmap_composer.invalidate_heightmap(feature)

		# Influence maps only depend on position/size/shape/falloff/rotation/mask, so keep
		# them cached for edits that cannot change them (height, strength, blend mode, ...).
		_heightmap_composer.invalidate_influence_if_changed(feature)
	
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
	_heightmap_content_dirty = true
	
	if auto_update:
		_request_rebuild()

## Regenerate the placed instances of a single non-height feature (e.g. a scatter node).
func _refresh_single_feature_instances(feature: TerrainFeatureNode) -> void:
	if not _scatter_manager:
		return
	_scatter_manager.invalidate_scatter(feature)
	if not (feature is ScatterNode) or _final_heightmap == null:
		return
	if _terrain_bounds.size.x <= 0.0 or _terrain_bounds.size.y <= 0.0:
		return
	_scatter_manager.set_terrain_data(_final_heightmap, _terrain_bounds, base_height, resolution, false)
	_scatter_manager.refresh_scatter([feature])

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
	_heightmap_content_dirty = true
	
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
	_heightmap_composer.debug_logging = debug_logging
	if not _material_builder:
		_material_builder = TerrainMaterialBuilder.new()
	if not _chunk_manager:
		_chunk_manager = ChunkManager.new(self)
	if not _scatter_manager:
		_scatter_manager = ScatterManager.new(self)
	if not _bake_exporter:
		_bake_exporter = BakeExporter.new()
	if not _diagnostics:
		_diagnostics = TerrainDiagnostics.new()
		_diagnostics.set_report_enabled(debug_logging)
	if not _pipeline:
		_pipeline = TerrainChunkPipeline.new()
	_setup_pipeline_options()
	
	# Check with rebuild coordinator if we can start
	var _coord = Engine.get_singleton("TerrainRebuildCoordinator") if Engine.has_singleton("TerrainRebuildCoordinator") else null
	if _coord:
		if not _coord.request_rebuild(self):
			return  # Queued, will be called again when ready
		_coordinator_rebuild_pending = true
	
	_is_generating = true
	_rebuild_id += 1
	_rebuild_start_msec = Time.get_ticks_msec()
	_diagnostics.begin_rebuild(_rebuild_id)
	
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

	# The heightmap is recomposed every rebuild; only flag its content as changed when an
	# input that shapes it (bounds, resolution, base height) actually differs. Feature
	# edits set the flag directly, so unchanged inputs keep scatter instances alive.
	var compose_signature := "%s|%d|%f|%s|%s" % [
		_terrain_bounds,
		heightmap_resolution.x,
		base_height,
		use_gpu_composition,
		use_gpu_feature_evaluation,
	]
	if compose_signature != _last_compose_signature:
		_last_compose_signature = compose_signature
		_heightmap_content_dirty = true
	
	# Phase 4: Prepare all evaluation contexts on main thread
	var context_start = Time.get_ticks_msec()
	var feature_contexts = {}
	for feature in _height_feature_nodes:
		if is_instance_valid(feature) and feature.is_inside_tree() and feature.visible:
			feature_contexts[feature] = feature.prepare_evaluation_context()
	_cached_feature_contexts = feature_contexts  # Cache for public query APIs
	_diagnostics.record("contexts", Time.get_ticks_msec() - context_start)
	_diagnostics.count("contexts", feature_contexts.size())
	if debug_logging:
		print("[TerrainComposer] Rebuild #%d prepared %d contexts in %d ms" % [
			_rebuild_id, feature_contexts.size(), _diagnostics.phase_ms("contexts")
		])
	
	# Compose heightmaps using helper with contexts
	var compose_start = Time.get_ticks_msec()
	if _can_reuse_heightmap(compose_signature):
		# Composition is by far the most expensive phase, and most rebuild triggers (collision
		# settings, chunk size, LOD, a repeated rebuild) do not change its inputs at all.
		_diagnostics.count("compose_reused")
	else:
		var compose_result = _heightmap_composer.compose(
			_height_feature_nodes,
			feature_contexts,
			heightmap_resolution,
			_terrain_bounds,
			base_height,
			use_gpu_composition,
			use_multithreading,
			max_worker_threads,
			use_gpu_feature_evaluation
		)
		if compose_result.is_empty() or not compose_result.has("heightmap"):
			push_error("[TerrainComposer] Heightmap composition failed; aborting rebuild")
			_is_generating = false
			if _coordinator_rebuild_pending:
				if _coord:
					_coord.rebuild_completed(self)
				_coordinator_rebuild_pending = false
			return
		
		_final_heightmap = compose_result["heightmap"]
		_final_hole_mask = compose_result.get("hole_mask", null)
	_diagnostics.record("compose", Time.get_ticks_msec() - compose_start)
	if debug_logging:
		print("[TerrainComposer] Rebuild #%d compose time: %d ms" % [_rebuild_id, _diagnostics.phase_ms("compose")])
	
	# Step 3: Generate chunk meshes from final heightmap
	var grid_changed = _chunk_manager.update_grid(terrain_size, chunk_size, _get_terrain_origin_world())
	if grid_changed:
		_chunk_manager.mark_all_dirty()
		_heightmap_content_dirty = true
	_heightmap_dirty_pending = false
	
	_rebuild_chunks(grid_changed)
	
	# Check for completion in process
	set_process(true)

func _get_chunk_generation_lod(chunk) -> int:
	return chunk.lod_level


## True when the composed heightmap of the previous rebuild can be reused.
##
## Composition is the most expensive phase of a rebuild, and several rebuild triggers cannot
## change it at all: toggling collision, changing the collision budget, a chunk size or LOD
## change (the per-chunk extraction below copies out of the composed heightmap, so a different
## chunking still works), or a rebuild that was requested while one was already running.
## Feature edits always mark the heightmap as dirty.
func _can_reuse_heightmap(signature: String) -> bool:
	if _final_heightmap == null or _heightmap_dirty_pending:
		return false
	return signature == _last_compose_signature


func _update_material() -> void:
	if _material_builder and _chunk_manager:
		_material_builder.texture_array_size = texture_array_size
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
	# A hole is only "real" when the mask carves a pixel; the mask image is allocated for every
	# terrain. Computing it here, on the slice, keeps the collision update from rescanning the
	# full mask (its own scan used to cost a full-image pass per collision update).
	var has_holes := false
	if _final_hole_mask:
		chunk_hole_mask = Image.create(width, height, false, Image.FORMAT_RF)
		chunk_hole_mask.blit_rect(_final_hole_mask, Rect2i(start_x, start_y, width, height), Vector2i.ZERO)
		has_holes = TerrainCollisionBuilder.mask_has_holes_in_rect(
			_final_hole_mask, Rect2i(start_x, start_y, width, height)
		)
	
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
		"hole_mask": chunk_hole_mask,
		"has_holes": has_holes
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
	# A new rebuild supersedes whatever the previous one left in the queues: the meshes are
	# about to be regenerated anyway and stale collision soups would be applied to a heightmap
	# they were not built from.
	_cancel_pending_work()

	var dirty_chunks: Array = []
	if _chunk_manager:
		for chunk in _chunk_manager.get_chunks().values():
			if full_rebuild or chunk.is_dirty:
				dirty_chunks.append(chunk)
	
	if dirty_chunks.is_empty():
		_on_chunk_generation_completed()
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
			"has_holes": chunk_data["has_holes"],
			"size": _get_chunk_world_size(chunk),
			"lod_level": target_lod,
			"collision": generate_collision,
			"collision_budget": _collision_budget_for(chunk)
		})
	
	_pending_chunk_rebuild_id = _rebuild_id
	_setup_pipeline_options()
	_pipeline.dispatch_mesh_jobs(jobs, _rebuild_id)
	if not _pipeline.use_threads or jobs.size() <= 1:
		# Nothing to wait for: the results are already queued, so the rebuild can land now.
		_apply_pending_chunk_results(false)


## Drops queued mesh results and abandons in-flight mesh tasks. The holders are referenced by the
## bound callables of the running tasks, so abandoning one is safe: the workers keep writing into
## memory that stays alive, and the results are simply never collected.
## A collision refresh in flight is left alone: the results carry the revision of the chunk data
## they were built from, so a rebuild that replaces a chunk heightmap makes them stale instead of
## wrong (see _apply_pending_collision_results).
func _cancel_pending_work() -> void:
	if _pipeline:
		_pipeline.cancel_mesh_jobs()

## Applies the finished chunk meshes to the scene.
## [param budgeted] spreads the work over several frames: applying a rebuild of a large terrain
## used to be a single frame that stalled the editor for several hundred milliseconds, because
## creating the meshes and handing the collision shapes to the physics server both happen here.
func _apply_pending_chunk_results(budgeted: bool = false) -> void:
	if not _pipeline or not _pipeline.has_mesh_results():
		_on_chunk_generation_completed()
		return
	
	# Discard stale results from a previous rebuild
	if _pending_chunk_rebuild_id != _rebuild_id or not _chunk_manager:
		_pipeline.cancel_mesh_jobs()
		_on_chunk_generation_completed()
		return

	var start_ms := Time.get_ticks_msec()
	var applied := 0
	while _pipeline.has_mesh_results():
		_apply_chunk_result(_pipeline.pop_mesh_result())
		applied += 1
		if budgeted and chunk_apply_budget_ms > 0 and Time.get_ticks_msec() - start_ms >= chunk_apply_budget_ms:
			break

	if _diagnostics:
		_diagnostics.count("chunks_applied", applied)

	if _pipeline.has_mesh_results():
		if _diagnostics:
			_diagnostics.count("apply_frames")
		return

	_update_material()
	_on_chunk_generation_completed()


func _apply_chunk_result(result: Dictionary) -> void:
	var key: Vector2i = result["key"]
	var chunk = _chunk_manager.get_chunks().get(key)
	if not chunk:
		return
	# Workers only produce the surface arrays; the renderer resource is built here, on the main
	# thread, because creating RIDs from a worker corrupts the renderer's RID table.
	chunk.mesh_instance.mesh = TerrainMeshGenerator.mesh_from_arrays(result["arrays"])
	chunk.mesh_instance.visible = true
	chunk.heightmap = result["heightmap"]
	chunk.hole_mask = result.get("hole_mask", null)
	chunk.has_holes = result.get("has_holes", false)
	chunk.lod_level = result["lod_level"]
	# The chunk data behind collision just changed, so a collision soup in flight was built from
	# the previous heightmap and must not be applied any more.
	chunk.collision_revision += 1
	_chunk_manager.mark_chunk_clean(chunk)
	_update_chunk_collision(chunk, result.get("collision_faces", PackedVector3Array()))

func _on_chunk_generation_completed() -> void:
	if _scatter_manager:
		_scatter_manager.set_terrain_data(_final_heightmap, _terrain_bounds, base_height, resolution, _heightmap_content_dirty)
		_heightmap_content_dirty = false
		_scatter_manager.refresh_scatter(_scatter_nodes)
	_is_generating = false
	_initial_rebuild_pending = false

	if _rebuild_start_msec > 0:
		_rebuild_start_msec = 0
		if _diagnostics:
			_diagnostics.end_rebuild()

	# Signal rebuild completion to coordinator
	if _coordinator_rebuild_pending:
		var _coord2 = Engine.get_singleton("TerrainRebuildCoordinator") if Engine.has_singleton("TerrainRebuildCoordinator") else null
		if _coord2:
			_coord2.rebuild_completed(self)
		_coordinator_rebuild_pending = false
	terrain_updated.emit()

	# The terrain surface changed, so any existing navigation mesh describes the previous terrain.
	# This only queues the bake; it runs from _process() once the queues are drained.
	if generate_navigation_mesh:
		_mark_navigation_dirty()

	if _rebuild_after_current:
		_rebuild_after_current = false
		call_deferred("rebuild_terrain")

func _get_chunk_world_size(chunk) -> Vector2:
	return TerrainCollisionBuilder.chunk_world_size(chunk)


## Update a chunk's collision shape.
## [param collision_faces] is the triangle soup the chunk mesh worker built for hole chunks (see
## _run_chunk_mesh_job): building it off the main thread keeps the hundreds of thousands of
## vertices of a large holed chunk out of the frame that applies the rebuild.
func _update_chunk_collision(chunk, collision_faces: PackedVector3Array = PackedVector3Array()) -> void:
	if not chunk or not chunk.collision_shape:
		return

	if not generate_collision or not chunk.mesh_instance or not chunk.mesh_instance.mesh:
		_clear_chunk_collision(chunk)
		return

	chunk.static_body.visible = true

	# Hole carving removes triangles from the visual mesh and a HeightMapShape3D would fill the
	# hole back in, so a chunk with actual hole pixels gets a triangle mesh instead. The flag is
	# computed once per chunk when its mask slice is extracted.
	var start_time = Time.get_ticks_msec()
	var summary: String
	if chunk.heightmap and not chunk.has_holes:
		summary = _apply_heightmap_collision(chunk)
	else:
		summary = _apply_trimesh_collision(chunk, collision_faces)

	var elapsed = Time.get_ticks_msec() - start_time
	if _diagnostics:
		_diagnostics.record("collision", elapsed)
		_diagnostics.warn("collision", "Slow chunk collision update: %s in %d ms" % [summary, elapsed], elapsed)


func _clear_chunk_collision(chunk) -> void:
	chunk.static_body.visible = false
	chunk.collision_shape.shape = null
	# Drop the cached trimesh as well, otherwise a disabled collision keeps its faces alive.
	chunk.collision_trimesh = null


## Exact collision from the (possibly LOD reduced) chunk heightmap.
## This is the cheap path: handing one PackedFloat32Array to HeightMapShape3D costs 1-2 ms even
## for a 513x513 chunk.
func _apply_heightmap_collision(chunk) -> String:
	chunk.collision_trimesh = null

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

	# This path only runs for chunks without hole pixels, so the heightmap can be handed over
	# as is: holes are expressed by *removing* triangles, and a sentinel depth would have needed
	# a full-image branch per pixel to encode them.
	var height_data: PackedFloat32Array = chunk.heightmap.get_data().to_float32_array()
	for i in mini(height_data.size(), map_data.size()):
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

	return "%dx%d heightmap" % [w, d]


## Trimesh collision for chunks whose mesh does not follow the heightmap grid (carved holes) or
## that have no heightmap at all.
## The shape is cached on the chunk and reused, so an LOD or hole update only pays for the faces
## themselves - the physics server rebuilds the BVH either way.
func _apply_trimesh_collision(chunk, collision_faces: PackedVector3Array) -> String:
	var budget := _collision_budget_for(chunk)
	if collision_faces.is_empty() and chunk.heightmap != null:
		# Collision re-apply without a worker result (collision setting change): build the soup
		# here. Only reached by the serial/unthreaded path, see _update_all_chunk_collisions().
		collision_faces = TerrainCollisionBuilder.build_faces(
			chunk.heightmap, _get_chunk_world_size(chunk), chunk.hole_mask, budget, chunk.lod_level
		)

	if collision_faces.is_empty():
		# Nothing to build the soup from (chunk without a heightmap, or an unthreaded caller):
		# let the engine build the shape from the visible mesh.
		chunk.collision_trimesh = null
		chunk.collision_shape.shape = chunk.mesh_instance.mesh.create_trimesh_shape()
		chunk.collision_shape.scale = Vector3.ONE
		chunk.collision_shape.position = Vector3.ZERO
		return "trimesh from mesh"

	var shape: ConcavePolygonShape3D = chunk.collision_trimesh
	if shape == null or not is_instance_valid(shape):
		shape = ConcavePolygonShape3D.new()
		chunk.collision_trimesh = shape
		chunk.collision_shape.shape = shape
	shape.set_faces(collision_faces)

	chunk.collision_shape.scale = Vector3.ONE
	chunk.collision_shape.position = Vector3.ZERO

	return "trimesh %d faces (budget %s)" % [collision_faces.size() / 3, budget if budget > 0 else "exact"]


## Triangle budget a chunk's collision soup may use: the explicit override when set, otherwise
## the preset of [member collision_quality]. The two enums share their order on purpose.
func _collision_budget_for(chunk) -> int:
	if collision_triangle_budget > 0:
		return collision_triangle_budget
	return TerrainCollisionBuilder.budget_for_quality(collision_quality)


func _update_all_chunk_collisions() -> void:
	if not _chunk_manager:
		return

	if not generate_collision:
		# Disabling collision only has to drop the shapes; nothing to compute off-thread.
		for chunk in _chunk_manager.get_chunks().values():
			_clear_chunk_collision(chunk)
		terrain_updated.emit()
		return

	# Rebuilding the soup for every chunk is worker work: a holed 513x513 chunk carries >500k
	# triangles, and building them on the main thread blocked the editor for ~1.7 s per change.
	var jobs: Array = []
	for chunk in _chunk_manager.get_chunks().values():
		if chunk.heightmap == null:
			continue
		jobs.append({
			"key": chunk.position,
			"heightmap": chunk.heightmap,
			"hole_mask": chunk.hole_mask,
			"size": _get_chunk_world_size(chunk),
			"budget": _collision_budget_for(chunk),
			"lod_level": chunk.lod_level,
			"revision": chunk.collision_revision
		})

	# The queue may still hold soups from an earlier collision refresh; they describe an older
	# revision and are dropped when they are popped, but clearing them here keeps the newest
	# refresh from waiting behind them.
	_setup_pipeline_options()
	_pipeline.cancel_collision_jobs()
	_pipeline.dispatch_collision_jobs(jobs)
	set_process(true)


## Applies the collision soups the workers built. Budgeted like the mesh queue: a holed chunk
## hands hundreds of thousands of triangles to the physics server, which would otherwise stall a
## single frame for well over a second.
## A soup whose chunk data was replaced since it was built (a rebuild won the race) is dropped:
## it describes the previous heightmap.
func _apply_pending_collision_results(budgeted: bool) -> void:
	if not _pipeline:
		return
	var start_ms := Time.get_ticks_msec()
	var applied := 0
	while _pipeline.has_collision_results():
		var result: Dictionary = _pipeline.pop_collision_result()
		if _chunk_manager:
			var chunk = _chunk_manager.get_chunks().get(result["key"])
			if chunk and generate_collision and result.get("revision", 0) == chunk.collision_revision:
				_update_chunk_collision(chunk, result.get("collision_faces", PackedVector3Array()))
		applied += 1
		if budgeted and chunk_apply_budget_ms > 0 and Time.get_ticks_msec() - start_ms >= chunk_apply_budget_ms:
			break
	if not _pipeline.has_collision_results():
		terrain_updated.emit()

## True while worker results are still being produced or applied, or a queued collision refresh is
## waiting for its frame. Rebuilds are asynchronous, so this is the public way for tools and tests
## to know that a rebuild has fully landed.
func is_rebuilding() -> bool:
	return _has_worker_work() or _collision_refresh_pending or _collision_layer_pending


## True while the chunk mesh or collision worker queues still hold work. Kept apart from
## [method is_rebuilding] because _process() drains the queues that the flags behind
## is_rebuilding() describe: testing them with is_rebuilding() there would never clear them.
func _has_worker_work() -> bool:
	return _is_generating or (_pipeline != null and _pipeline.has_pending_work())

## Pushes the threading exports into the pipeline. Called whenever the pipeline is (re)created and
## at the start of every dispatch, so changing the exports takes effect on the next rebuild.
func _setup_pipeline_options() -> void:
	if not _pipeline:
		return
	_pipeline.use_threads = use_multithreading
	_pipeline.worker_threads = max_worker_threads
	_pipeline.diagnostics = _diagnostics

func _update_all_chunk_collision_properties() -> void:
	if not _chunk_manager:
		return
	for chunk in _chunk_manager.get_chunks().values():
		if chunk and chunk.static_body:
			chunk.static_body.collision_layer = collision_layer
			chunk.static_body.collision_mask = collision_mask


## Records that a collision property changed. The setter never does the work itself: loading a
## scene or dragging a value in the inspector assigns several of these properties in a row, and
## each refresh rebuilds the triangle soup of every holed chunk.
func _mark_collision_dirty() -> void:
	_collision_refresh_pending = true
	set_process(true)


## Layer/mask changes are pure property writes on the existing bodies, so they queue separately
## and are applied before a full collision refresh would be.
func _mark_collision_layer_dirty() -> void:
	_collision_layer_pending = true
	set_process(true)


## Queue a navigation bake. Safe to call at any time, including from property setters: the bake
## only starts once the rebuild has landed (see _process).
func rebuild_navigation_mesh() -> void:
	_mark_navigation_dirty()


## The last baked navigation mesh, or null when no bake has finished yet.
func get_navigation_mesh() -> NavigationMesh:
	return _navigation_mesh


## True while a navigation bake is queued or in flight.
func is_baking_navigation_mesh() -> bool:
	return _navigation_dirty or _navigation_baking


func _mark_navigation_dirty() -> void:
	if not generate_navigation_mesh:
		# Turning the option off drops the region (and with it the server side polygons).
		_navigation_dirty = false
		_clear_navigation_region()
		return
	_navigation_dirty = true
	set_process(true)


func _maybe_bake_navigation_mesh() -> void:
	if not _navigation_dirty:
		return
	if not generate_navigation_mesh:
		_navigation_dirty = false
		return
	# A bake that is still in flight keeps the request queued instead of dropping it.
	if not is_inside_tree() or _navigation_baking:
		return
	if not _chunk_manager or _final_heightmap == null:
		return
	_navigation_dirty = false
	_start_navigation_bake()


## Builds the source geometry from the chunk heightmaps and hands it to the navigation server.
## The polygons are copied into a fresh NavigationMesh per bake, so the region always receives a
## new resource (assigning the same instance again would be ignored by the region and the server
## would keep the previous polygons).
func _start_navigation_bake() -> void:
	var mesh := NavigationMesh.new()
	if navigation_mesh_template:
		_copy_navigation_settings(navigation_mesh_template, mesh)

	var geometry := NavigationMeshSourceGeometryData3D.new()
	var budget := navigation_triangle_budget if navigation_triangle_budget > 0 else TerrainNavigationBuilder.DEFAULT_BUDGET
	var chunks := _chunk_manager.get_chunks().values()
	var added := TerrainNavigationBuilder.append_chunks(geometry, chunks, budget)
	if added == 0:
		push_warning("[TerrainComposer] No terrain surface to bake a navigation mesh from")
		return

	_navigation_mesh = mesh
	_navigation_baking = true
	if use_multithreading:
		# The callback runs on the main thread in a later frame (verified against the 4.7
		# navigation server), so only resources are touched here - and the trampoline keeps a
		# bake that outlives this node from calling into a freed instance.
		NavigationServer3D.bake_from_source_geometry_data_async(
			mesh, geometry, _navigation_bake_finished_trampoline.bind(self)
		)
	else:
		NavigationServer3D.bake_from_source_geometry_data(mesh, geometry)
		_on_navigation_bake_finished()


## Static entry point for the navigation server's bake callback (see _start_navigation_bake).
static func _navigation_bake_finished_trampoline(composer) -> void:
	if is_instance_valid(composer):
		composer._on_navigation_bake_finished()


## Called by the navigation server (on the main thread; the async bake defers the callback itself).
func _on_navigation_bake_finished() -> void:
	_navigation_baking = false
	if not generate_navigation_mesh or _navigation_mesh == null or not is_inside_tree():
		return
	# Assignment is what pushes the polygons to the navigation server, and it only happens for a
	# resource the region does not have yet - hence the fresh mesh per bake.
	_ensure_navigation_region().navigation_mesh = _navigation_mesh
	navigation_mesh_baked.emit(_navigation_mesh)


func _ensure_navigation_region() -> NavigationRegion3D:
	if _navigation_region and is_instance_valid(_navigation_region):
		return _navigation_region
	_navigation_region = NavigationRegion3D.new()
	_navigation_region.name = "TerrainNavigation"
	add_child(_navigation_region, false, Node.INTERNAL_MODE_BACK)
	return _navigation_region


func _clear_navigation_region() -> void:
	if _navigation_region and is_instance_valid(_navigation_region):
		_navigation_region.queue_free()
	_navigation_region = null
	_navigation_mesh = null


## Copies the stored properties of a template mesh (cell size, agent radius/height/slope, ...)
## onto a fresh mesh, so every bake can use a new resource without losing the user's settings.
static func _copy_navigation_settings(source: NavigationMesh, target: NavigationMesh) -> void:
	for property in source.get_property_list():
		var name: String = property["name"]
		if name.begins_with("resource_") or not (int(property["usage"]) & PROPERTY_USAGE_STORAGE):
			continue
		target.set(name, source.get(name))


func _update_chunk_lod() -> void:
	if not _chunk_manager:
		return
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return
	
	var camera_pos = camera.global_position
	
	# Skip per-frame iteration when camera hasn't moved meaningfully
	if _lod_last_camera_valid:
		var movement = camera_pos.distance_to(_lod_last_camera_pos)
		# Use 10% of the smallest LOD distance threshold as the movement threshold
		var min_lod = lod_distances[0] if not lod_distances.is_empty() else 500.0
		if movement < min_lod * 0.1:
			return
	
	_lod_last_camera_pos = camera_pos
	_lod_last_camera_valid = true
	
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
			_chunk_manager.mark_chunk_dirty(chunk)

func _calculate_lod_level(distance: float) -> int:
	if lod_distances.is_empty() or lod_scale_factors.is_empty():
		return 0
	for i in range(lod_distances.size()):
		if distance < lod_distances[i]:
			return i
	return clampi(lod_distances.size(), 0, lod_scale_factors.size() - 1)

# ---------------------------------------------------------------------------
# Public Query APIs
# ---------------------------------------------------------------------------

## Bilinearly samples a single-channel (FORMAT_RF) image at normalized coordinates.
func _sample_image_bilinear(img: Image, u: float, v: float) -> float:
	var img_w = img.get_width()
	var img_h = img.get_height()
	var px = clampf(u * (img_w - 1), 0.0, float(img_w - 1))
	var py = clampf(v * (img_h - 1), 0.0, float(img_h - 1))
	var x0 = int(floor(px))
	var y0 = int(floor(py))
	var x1 = mini(x0 + 1, img_w - 1)
	var y1 = mini(y0 + 1, img_h - 1)
	var dx = px - float(x0)
	var dy = py - float(y0)
	var h00 = img.get_pixel(x0, y0).r
	var h10 = img.get_pixel(x1, y0).r
	var h01 = img.get_pixel(x0, y1).r
	var h11 = img.get_pixel(x1, y1).r
	return lerp(lerp(h00, h10, dx), lerp(h01, h11, dx), dy)

## Returns the composed terrain height in world space at a world position (includes all
## height features). The composed heightmap already contains [member base_height], so the
## result is [code]global_position.y + composed height[/code].
## Returns [code]global_position.y + base_height[/code] if the terrain has not been built or
## the position is outside the terrain bounds.
func get_height_at_world_position(world_pos: Vector3) -> float:
	var fallback := global_position.y + base_height
	if not _final_heightmap:
		return fallback
	var u = (world_pos.x - _terrain_bounds.position.x) / _terrain_bounds.size.x
	var v = (world_pos.z - _terrain_bounds.position.y) / _terrain_bounds.size.y
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return fallback
	return _sample_image_bilinear(_final_heightmap, u, v) + global_position.y

## Returns [code]true[/code] if the world position is inside a hole.
## The hole mask is sampled bilinearly so that the answer stays consistent with the
## interpolated height query above.
func is_hole_at_world_position(world_pos: Vector3) -> bool:
	if not _final_hole_mask:
		return false
	var u = (world_pos.x - _terrain_bounds.position.x) / _terrain_bounds.size.x
	var v = (world_pos.z - _terrain_bounds.position.y) / _terrain_bounds.size.y
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return false
	return _sample_image_bilinear(_final_hole_mask, u, v) > 0.5

## Returns the highest water level among [WaterNode]s affecting this position.
## Returns [code]-INF[/code] if no water covers this position.
func get_water_level_at_world_position(world_pos: Vector3) -> float:
	var level = -INF
	for feature in _feature_nodes:
		if feature is WaterNode:
			var water = feature as WaterNode
			if water.is_point_under_water(world_pos):
				level = max(level, water.water_level)
	return level

## Returns an array of all features whose influence area contains the world position.
## Uses cached evaluation contexts from the last rebuild when available to avoid
## per-query context allocation overhead.
func get_features_at_world_position(world_pos: Vector3) -> Array[TerrainFeatureNode]:
	var result: Array[TerrainFeatureNode] = []
	for feature in _feature_nodes:
		var ctx = _cached_feature_contexts.get(feature)
		if ctx == null:
			ctx = feature.prepare_evaluation_context()
		if feature.get_influence_weight_safe(world_pos, ctx) > 0.0:
			result.append(feature)
	return result
