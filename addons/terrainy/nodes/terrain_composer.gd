@tool
class_name TerrainComposer
extends Node3D

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")
const TerrainTextureLayer = preload("res://addons/terrainy/resources/terrain_texture_layer.gd")
const TerrainMeshGenerator = preload("res://addons/terrainy/nodes/terrain_mesh_generator.gd")

## Main terrain composer that blends all TerrainFeatureNodes and generates final mesh

signal terrain_updated
signal texture_layers_changed
signal generation_progress(stage: String, progress: float)  # Progress updates during generation

@export var terrain_size: Vector2 = Vector2(100, 100):
	set(value):
		terrain_size = value
		_request_update()

@export var resolution: int = 128:
	set(value):
		resolution = clamp(value, 16, 512)
		_request_update()

@export var base_height: float = 0.0:
	set(value):
		base_height = value
		_request_update()

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
		if is_instance_valid(feature) and feature.parameters_changed.is_connected(_on_feature_changed):
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
		if is_instance_valid(feature) and not feature.parameters_changed.is_connected(_on_feature_changed):
			feature.parameters_changed.connect(_on_feature_changed)

func _on_child_changed(node: Node) -> void:
	# Defer to avoid issues during node deletion
	call_deferred("_rescan_features")

func _rescan_features() -> void:
	_scan_for_features()
	_connect_feature_signals()
	_request_update()

func _on_feature_changed() -> void:
	_request_update()

func _on_texture_layer_changed() -> void:
	_update_material()

func _request_update() -> void:
	if not auto_update:
		return
	
	if not _update_queued:
		_update_queued = true
		_debounce_timer = update_debounce_time
		set_process(true)

func _process(delta: float) -> void:
	if _update_queued:
		_debounce_timer -= delta
		if _debounce_timer <= 0.0:
			_update_queued = false
			_debounce_timer = 0.0
			_update_terrain()
	elif _is_generating:
		# Check if thread has finished
		if _generation_thread and not _generation_thread.is_alive():
			var mesh = _generation_thread.wait_to_finish()
			_generation_thread = null
			_is_generating = false
			
			if mesh:
				print("[TerrainComposer] Thread completed, applying mesh...")
				if _mesh_instance:
					_mesh_instance.mesh = mesh
					_update_material()
				
				# Defer collision to prevent blocking
				call_deferred("_update_collision")
				terrain_updated.emit()
				print("[TerrainComposer] Mesh applied successfully")
			else:
				set_process(false)
	else:
		set_process(false)

## Manually trigger terrain regeneration
func rebuild_terrain() -> void:
	_update_queued = false
	_debounce_timer = 0.0
	set_process(false)
	_update_terrain()

func _update_terrain() -> void:
	if use_threaded_generation:
		_update_terrain_threaded()
	else:
		_update_terrain_immediate()

func _update_terrain_immediate() -> void:
	var mesh = await _generate_terrain_mesh()
	if _mesh_instance:
		_mesh_instance.mesh = mesh
		_update_material()
	
	# Defer collision to next frame to keep responsive
	call_deferred("_update_collision")
	terrain_updated.emit()

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
			return feature_copy.get_height_at(world_pos)
		
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

func _calculate_height_at(world_pos: Vector3) -> float:
	var final_height = base_height
	var total_weight = 0.0
	var weighted_heights: Array[Dictionary] = []
	
	# Collect all feature contributions
	for feature in _feature_nodes:
		if not is_instance_valid(feature) or not feature.is_inside_tree():
			continue
		
		if not feature.visible:
			continue
		
		var weight = feature.get_influence_weight(world_pos)
		if weight > 0.001:
			var height = feature.get_height_at(world_pos)
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
	
	# Determine the texture size (use the first valid texture's size)
	var texture_size: Vector2i = Vector2i(1024, 1024)
	for layer in texture_layers:
		if layer.albedo_texture:
			texture_size = layer.albedo_texture.get_size()
			break
	
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
		roughness_images.append(_get_or_create_image(layer.roughness_texture, texture_size, Color(0.5, 0.5, 0.5, 1.0)))
		metallic_images.append(_get_or_create_image(layer.metallic_texture, texture_size, Color.BLACK))
		ao_images.append(_get_or_create_image(layer.ao_texture, texture_size, Color.WHITE))
	
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
	
	if texture and texture.get_image():
		img = texture.get_image().duplicate()
		
		# Convert to RGBA8 format for consistency
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		
		# Resize if needed (Texture2DArray requires all textures to be the same size)
		if img.get_size() != size:
			img.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
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
	
	var texture_array = Texture2DArray.new()
	
	# Create the texture array with all layers
	texture_array.create_from_images(images)
	
	return texture_array
