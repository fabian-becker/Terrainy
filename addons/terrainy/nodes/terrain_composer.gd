@tool
class_name TerrainComposer
extends Node3D

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")
const TerrainTextureLayer = preload("res://addons/terrainy/resources/terrain_texture_layer.gd")
const TerrainMeshGenerator = preload("res://addons/terrainy/helpers/terrain_mesh_generator.gd")
const TerrainHeightmapBuilder = preload("res://addons/terrainy/helpers/terrain_heightmap_builder.gd")
const TerrainMaterialBuilder = preload("res://addons/terrainy/helpers/terrain_material_builder.gd")
const EvaluationContext = preload("res://addons/terrainy/helpers/evaluation_context.gd")

## Simple terrain composer - generates mesh from TerrainFeatureNodes

signal terrain_updated
signal texture_layers_changed

# Constants
const MAX_TERRAIN_RESOLUTION = 1024
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
		if auto_update and is_inside_tree():
			rebuild_terrain()

@export var base_height: float = 0.0:
	set(value):
		base_height = value
		if auto_update and is_inside_tree():
			rebuild_terrain()

@export var auto_update: bool = true

@export_group("Performance")
@export var use_gpu_composition: bool = true:
	set(value):
		use_gpu_composition = value
		if is_inside_tree() and auto_update:
			rebuild_terrain()

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
		_update_collision()

# Internal
var _mesh_instance: MeshInstance3D
var _static_body: StaticBody3D
var _collision_shape: CollisionShape3D
var _feature_nodes: Array[TerrainFeatureNode] = []
var _is_generating: bool = false

# Helpers
var _heightmap_composer: TerrainHeightmapBuilder = null
var _material_builder: TerrainMaterialBuilder = null

# Threading
var _mesh_thread: Thread = null
var _pending_mesh: ArrayMesh = null
var _pending_heightmap: Image = null

# Terrain state
var _final_heightmap: Image
var _terrain_bounds: Rect2

# Rebuild timing
var _rebuild_start_msec: int = 0
var _rebuild_id: int = 0

# Rebuild debouncing
var _rebuild_timer: Timer = null
var _pending_rebuild: bool = false

func _ready() -> void:
	set_process(false)  # Only enable when mesh generation is running
	
	# Initialize helpers
	_heightmap_composer = TerrainHeightmapBuilder.new()
	_material_builder = TerrainMaterialBuilder.new()
	
	# Setup mesh instance
	if not _mesh_instance:
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance, false, Node.INTERNAL_MODE_BACK)
	
	# Setup collision
	if not _static_body:
		_static_body = StaticBody3D.new()
		add_child(_static_body, false, Node.INTERNAL_MODE_BACK)
		_static_body.name = "CollisionBody"
	
	if not _collision_shape:
		_collision_shape = CollisionShape3D.new()
		_static_body.add_child(_collision_shape, false, Node.INTERNAL_MODE_BACK)
		_collision_shape.name = "CollisionShape"
	
	# Watch for child changes in editor
	if Engine.is_editor_hint():
		child_entered_tree.connect(_on_child_changed)
		child_exiting_tree.connect(_on_child_changed)
		_setup_rebuild_debounce_timer()
	
	# Initial generation
	_scan_features()
	rebuild_terrain()

func _process(_delta: float) -> void:
	# Check if mesh generation thread completed
	if _mesh_thread and not _mesh_thread.is_alive():
		_mesh_thread.wait_to_finish()
		_mesh_thread = null
		
		if _pending_mesh and _mesh_instance:
			_mesh_instance.mesh = _pending_mesh
			_update_material()
			_update_collision(_pending_heightmap)
			terrain_updated.emit()
			if _rebuild_start_msec > 0:
				var total_elapsed = Time.get_ticks_msec() - _rebuild_start_msec
				print("[TerrainComposer] Rebuild #%d total time: %d ms" % [_rebuild_id, total_elapsed])
			_pending_mesh = null
			_pending_heightmap = null
		
		_is_generating = false
		set_process(false)

func _exit_tree() -> void:
	if _mesh_thread and _mesh_thread.is_alive():
		# Wait with timeout to prevent editor hang (max 5 seconds)
		var wait_start = Time.get_ticks_msec()
		while _mesh_thread.is_alive():
			if Time.get_ticks_msec() - wait_start > 5000:
				push_warning("[TerrainComposer] Mesh thread did not finish in time, forcing exit")
				break
			OS.delay_msec(10)
		if not _mesh_thread.is_alive():
			_mesh_thread.wait_to_finish()
	
	# Clean up helpers
	if _heightmap_composer:
		_heightmap_composer.cleanup()
		_heightmap_composer = null

func _scan_features() -> void:
	# Disconnect old signals
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.parameters_changed.is_connected(_on_feature_changed):
			feature.parameters_changed.disconnect(_on_feature_changed)
	
	_feature_nodes.clear()
	_scan_recursive(self)
	
	# Connect new signals
	for feature in _feature_nodes:
		if is_instance_valid(feature):
			feature.parameters_changed.connect(_on_feature_changed.bind(feature))

func _scan_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is TerrainFeatureNode and child != _mesh_instance and child != _static_body:
			if _feature_nodes.size() >= MAX_FEATURE_COUNT:
				push_warning("[TerrainComposer] Maximum feature count (%d) reached, ignoring '%s'" % [MAX_FEATURE_COUNT, child.name])
				break
			_feature_nodes.append(child)
			_scan_recursive(child)
		elif not (child is MeshInstance3D or child is StaticBody3D or child is CollisionShape3D):
			_scan_recursive(child)

func _on_child_changed(_node: Node) -> void:
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
	_pending_rebuild = true
	if _rebuild_timer:
		_rebuild_timer.start()
	else:
		# Fallback if no timer (non-editor mode)
		rebuild_terrain()

func _on_rebuild_timer_timeout() -> void:
	if _pending_rebuild:
		_pending_rebuild = false
		rebuild_terrain()

func _on_feature_changed(feature: TerrainFeatureNode) -> void:
	# Invalidate caches via helper
	if _heightmap_composer:
		_heightmap_composer.invalidate_heightmap(feature)
		
		# Only invalidate influence if influence-related properties changed
		_heightmap_composer.invalidate_influence(feature)
	
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
		return
	
	_is_generating = true
	_rebuild_id += 1
	_rebuild_start_msec = Time.get_ticks_msec()
	
	# Calculate terrain bounds
	_terrain_bounds = Rect2(
		-terrain_size / 2.0,
		terrain_size
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
	
	# Step 3: Generate mesh from final heightmap in background thread
	if _mesh_thread and _mesh_thread.is_alive():
		_mesh_thread.wait_to_finish()
	
	_mesh_thread = Thread.new()
	var thread_data = {
		"heightmap": _final_heightmap,
		"terrain_size": terrain_size
	}
	var mesh_start = Time.get_ticks_msec()
	_mesh_thread.start(_generate_mesh_threaded.bind(thread_data))
	print("[TerrainComposer] Rebuild #%d mesh thread start: %d ms" % [_rebuild_id, Time.get_ticks_msec() - mesh_start])
	
	# Check for completion in process
	set_process(true)

## Thread worker function for mesh generation
func _generate_mesh_threaded(data: Dictionary) -> void:
	var mesh = TerrainMeshGenerator.generate_from_heightmap(
		data["heightmap"],
		data["terrain_size"]
	)
	
	# Store results for main thread to pick up
	_pending_mesh = mesh
	_pending_heightmap = data["heightmap"]

func _update_collision(heightmap: Image = null) -> void:
	if not _collision_shape or not _mesh_instance:
		return
	
	var start_time = Time.get_ticks_msec()
	if generate_collision and heightmap:
		_static_body.visible = true
		
		# Use HeightMapShape3D for much better performance than trimesh
		var height_shape = HeightMapShape3D.new()
		var width = heightmap.get_width()
		var depth = heightmap.get_height()
		height_shape.map_width = width
		height_shape.map_depth = depth
		
		# Convert heightmap to float array
		var map_data: PackedFloat32Array = PackedFloat32Array()
		map_data.resize(width * depth)
		for z in range(depth):
			for x in range(width):
				map_data[z * width + x] = heightmap.get_pixel(x, z).r
		
		height_shape.map_data = map_data
		_collision_shape.shape = height_shape
		
		# Scale collision to match terrain size
		_collision_shape.scale = Vector3(
			terrain_size.x / (width - 1),
			1.0,
			terrain_size.y / (depth - 1)
		)
		# Center the collision shape
		_collision_shape.position = Vector3(-terrain_size.x / 2.0, 0, -terrain_size.y / 2.0)
		
		var elapsed = Time.get_ticks_msec() - start_time
		print("[TerrainComposer] Generated heightmap collision shape (%dx%d) in %d ms" % [width, depth, elapsed])
	elif generate_collision and _mesh_instance.mesh:
		# Fallback to trimesh if no heightmap is provided (legacy support)
		_static_body.visible = true
		_collision_shape.shape = _mesh_instance.mesh.create_trimesh_shape()
		var elapsed = Time.get_ticks_msec() - start_time
		print("[TerrainComposer] Generated trimesh collision shape in %d ms" % elapsed)
	else:
		_static_body.visible = false
		_collision_shape.shape = null
		var elapsed = Time.get_ticks_msec() - start_time
		print("[TerrainComposer] Disabled collision in %d ms" % elapsed)

func _update_material() -> void:
	if _material_builder:
		_material_builder.update_material(_mesh_instance, texture_layers, terrain_material)
