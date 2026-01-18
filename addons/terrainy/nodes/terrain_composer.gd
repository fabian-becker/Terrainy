@tool
class_name TerrainComposer
extends Node3D

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")
const TerrainTextureLayer = preload("res://addons/terrainy/resources/terrain_texture_layer.gd")
const TerrainMeshGenerator = preload("res://addons/terrainy/nodes/terrain_mesh_generator.gd")
const HeightmapCompositor = preload("res://addons/terrainy/nodes/heightmap_compositor.gd")

## Simple terrain composer - generates mesh from TerrainFeatureNodes

signal terrain_updated
signal texture_layers_changed

# Constants
const INFLUENCE_WEIGHT_THRESHOLD = 0.001
const CACHE_KEY_POSITION_PRECISION = 0.01  # Round positions to cm
const CACHE_KEY_FALLOFF_PRECISION = 0.01
const MAX_TERRAIN_RESOLUTION = 1024
const MAX_FEATURE_COUNT = 64

@export var terrain_size: Vector2 = Vector2(100, 100):
	set(value):
		terrain_size = value
		_heightmap_cache.clear()  # Resolution-dependent, must regenerate
		_influence_cache.clear()  # Also depends on bounds
		if auto_update and is_inside_tree():
			rebuild_terrain()

@export var resolution: int = 128:
	set(value):
		resolution = clamp(value, 16, MAX_TERRAIN_RESOLUTION)
		_heightmap_cache.clear()  # Resolution-dependent, must regenerate
		_influence_cache.clear()  # Also depends on resolution
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
		if value and not _gpu_compositor:
			_initialize_gpu_compositor()
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
var _shader_material: ShaderMaterial
var _is_generating: bool = false

# Threading
var _mesh_thread: Thread = null
var _pending_mesh: ArrayMesh = null
var _pending_heightmap: Image = null

# Heightmap composition cache
var _heightmap_cache: Dictionary = {}  # feature -> Image
var _influence_cache: Dictionary = {}  # feature -> Image
var _influence_cache_keys: Dictionary = {}  # feature -> cache key
var _final_heightmap: Image
var _terrain_bounds: Rect2
var _gpu_compositor: HeightmapCompositor
var _cached_resolution: Vector2i
var _cached_bounds: Rect2

func _ready() -> void:
	set_process(false)  # Only enable when mesh generation is running
	
	# Initialize GPU compositor if enabled
	_initialize_gpu_compositor()
	
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
	
	# Clean up GPU compositor if owned by this instance
	if _gpu_compositor:
		_gpu_compositor.cleanup()
		_gpu_compositor = null

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

func _initialize_gpu_compositor() -> void:
	if not use_gpu_composition or _gpu_compositor:
		return
	
	print("[TerrainComposer] Initializing GPU compositor...")
	_gpu_compositor = HeightmapCompositor.new()
	if not _gpu_compositor.is_available():
		push_warning("[TerrainComposer] GPU composition unavailable, will use CPU fallback")
		# Don't disable - just fall back when needed
	else:
		print("[TerrainComposer] GPU compositor ready")

func _on_feature_changed(feature: TerrainFeatureNode) -> void:
	# Invalidate heightmap cache when any parameter changes
	if _heightmap_cache.has(feature):
		_heightmap_cache.erase(feature)
	
	# Only invalidate influence if influence-related properties changed
	# (position, influence_size, influence_shape, edge_falloff)
	var current_key = _get_influence_cache_key(feature)
	if _influence_cache_keys.get(feature) != current_key:
		if _influence_cache.has(feature):
			_influence_cache.erase(feature)
		_influence_cache_keys[feature] = current_key
	
	if auto_update:
		rebuild_terrain()

## Generate cache key for influence map based on properties that affect it
func _get_influence_cache_key(feature: TerrainFeatureNode) -> String:
	# Only include properties that affect influence calculation
	# Round values to avoid floating-point precision issues
	var pos_rounded = (feature.global_position / CACHE_KEY_POSITION_PRECISION).round() * CACHE_KEY_POSITION_PRECISION
	var size_rounded = (feature.influence_size / CACHE_KEY_POSITION_PRECISION).round() * CACHE_KEY_POSITION_PRECISION
	var falloff_rounded = snappedf(feature.edge_falloff, CACHE_KEY_FALLOFF_PRECISION)
	return "%s_%s_%d_%f" % [
		pos_rounded,
		size_rounded,
		int(feature.influence_shape),
		falloff_rounded
	]

func _on_texture_layer_changed() -> void:
	_update_material()

## Force a complete rebuild with all caches cleared
func force_rebuild() -> void:
	print("[TerrainComposer] Force rebuild - clearing all caches")
	# Clear all caches for a completely fresh rebuild
	_heightmap_cache.clear()
	_influence_cache.clear()
	_influence_cache_keys.clear()
	
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
	
	# Calculate terrain bounds
	_terrain_bounds = Rect2(
		-terrain_size / 2.0,
		terrain_size
	)
	
	# Resolution for heightmaps
	var heightmap_resolution = Vector2i(resolution + 1, resolution + 1)
	
	# Check if resolution or bounds changed (invalidate influence cache)
	if _cached_resolution != heightmap_resolution or _cached_bounds != _terrain_bounds:
		_influence_cache.clear()
		_cached_resolution = heightmap_resolution
		_cached_bounds = _terrain_bounds
	
	# Step 1: Generate/update heightmaps for dirty features
	for feature in _feature_nodes:
		if not is_instance_valid(feature) or not feature.is_inside_tree() or not feature.visible:
			if _heightmap_cache.has(feature):
				_heightmap_cache.erase(feature)
			continue
		
		# Check if we need to regenerate this feature's heightmap
		if not _heightmap_cache.has(feature) or feature.is_dirty():
			_heightmap_cache[feature] = feature.generate_heightmap(heightmap_resolution, _terrain_bounds)
	
	# Step 2: Compose all heightmaps into final heightmap
	if use_gpu_composition and _gpu_compositor and _gpu_compositor.is_available():
		_final_heightmap = _compose_heightmaps_gpu(heightmap_resolution)
		# If GPU failed, fall back to CPU
		if not _final_heightmap:
			push_warning("[TerrainComposer] GPU composition failed, falling back to CPU")
			_final_heightmap = _compose_heightmaps_cpu(heightmap_resolution)
	else:
		_final_heightmap = _compose_heightmaps_cpu(heightmap_resolution)
	
	# Step 3: Generate mesh from final heightmap in background thread
	if _mesh_thread and _mesh_thread.is_alive():
		_mesh_thread.wait_to_finish()
	
	_mesh_thread = Thread.new()
	var thread_data = {
		"heightmap": _final_heightmap,
		"terrain_size": terrain_size
	}
	_mesh_thread.start(_generate_mesh_threaded.bind(thread_data))
	
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

## Compose all feature heightmaps into a single final heightmap (GPU)
func _compose_heightmaps_gpu(resolution: Vector2i) -> Image:
	var start_time = Time.get_ticks_msec()
	
	# Prepare data arrays
	var feature_heightmaps: Array[Image] = []
	var influence_maps: Array[Image] = []
	var blend_modes := PackedInt32Array()
	var strengths := PackedFloat32Array()
	
	# Collect valid features
	for feature in _feature_nodes:
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
		else:
			influence_map = _generate_influence_map(feature, resolution)
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
	print("[TerrainComposer] GPU composed %d features in %d ms (total with influence maps)" % [
		feature_heightmaps.size(), elapsed
	])
	
	return result

## Generate influence map for a feature
func _generate_influence_map(feature: TerrainFeatureNode, resolution: Vector2i) -> Image:
	var influence_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	
	var step = _terrain_bounds.size / Vector2(resolution - Vector2i.ONE)
	
	for y in range(resolution.y):
		var world_z = _terrain_bounds.position.y + (y * step.y)
		for x in range(resolution.x):
			var world_x = _terrain_bounds.position.x + (x * step.x)
			var world_pos = Vector3(world_x, 0, world_z)
			
			var weight = feature.get_influence_weight(world_pos)
			influence_map.set_pixel(x, y, Color(weight, 0, 0, 1))
	
	return influence_map

## Compose all feature heightmaps into a single final heightmap (CPU)
func _compose_heightmaps_cpu(resolution: Vector2i) -> Image:
	var start_time = Time.get_ticks_msec()
	
	# Create base heightmap
	var final_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	final_map.fill(Color(base_height, 0, 0, 1))
	
	# Hoist step calculation outside loops
	var step = _terrain_bounds.size / Vector2(resolution - Vector2i.ONE)
	
	# Blend each feature's heightmap
	for feature in _feature_nodes:
		if not _heightmap_cache.has(feature):
			continue
		
		var feature_map = _heightmap_cache[feature]
		
		# Validate resolution match
		if feature_map.get_width() != resolution.x or feature_map.get_height() != resolution.y:
			push_warning("[TerrainComposer] Feature '%s' heightmap size mismatch, skipping" % feature.name)
			continue
		
		# Blend feature into final heightmap
		for y in range(resolution.y):
			var world_z = _terrain_bounds.position.y + (y * step.y)
			for x in range(resolution.x):
				# Calculate world position for influence weight
				var world_x = _terrain_bounds.position.x + (x * step.x)
				var world_pos = Vector3(world_x, 0, world_z)
				
				# Get influence weight
				var weight = feature.get_influence_weight(world_pos)
				if weight <= INFLUENCE_WEIGHT_THRESHOLD:
					continue
				
				# Get heights
				var current_height = final_map.get_pixel(x, y).r
				var feature_height = feature_map.get_pixel(x, y).r
				var weighted_height = feature_height * weight * feature.strength
				
				# Apply blend mode
				var new_height: float
				match feature.blend_mode:
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
				
				final_map.set_pixel(x, y, Color(new_height, 0, 0, 1))
	
	var elapsed = Time.get_ticks_msec() - start_time
	print("[TerrainComposer] Composed %d feature heightmaps in %d ms" % [_heightmap_cache.size(), elapsed])
	
	return final_map

func _calculate_height_at(local_pos: Vector3) -> float:
	# Legacy callback - should not be used with heightmap approach
	# Kept for compatibility but not recommended
	var world_pos = to_global(local_pos)
	var final_height = base_height
	
	for feature in _feature_nodes:
		if not is_instance_valid(feature) or not feature.is_inside_tree() or not feature.visible:
			continue
		
		var weight = feature.get_influence_weight(world_pos)
		if weight <= INFLUENCE_WEIGHT_THRESHOLD:
			continue
		
		var height = feature.get_height_at(world_pos)
		var weighted_height = height * weight * feature.strength
		
		match feature.blend_mode:
			TerrainFeatureNode.BlendMode.ADD:
				final_height += weighted_height
			TerrainFeatureNode.BlendMode.SUBTRACT:
				final_height -= weighted_height
			TerrainFeatureNode.BlendMode.MULTIPLY:
				final_height *= (1.0 + weighted_height)
			TerrainFeatureNode.BlendMode.MAX:
				final_height = max(final_height, height * weight)
			TerrainFeatureNode.BlendMode.MIN:
				final_height = min(final_height, height * weight)
	
	return final_height

func _update_collision(heightmap: Image = null) -> void:
	if not _collision_shape or not _mesh_instance:
		return
	
	if generate_collision and heightmap:
		var start_time = Time.get_ticks_msec()
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
		print("[TerrainComposer] Generated collision shape in %d ms" % elapsed)
	elif generate_collision and _mesh_instance.mesh:
		# Fallback to trimesh if no heightmap is provided (legacy support)
		_static_body.visible = true
		_collision_shape.shape = _mesh_instance.mesh.create_trimesh_shape()
	else:
		_static_body.visible = false
		_collision_shape.shape = null

func _update_material() -> void:
	if not _mesh_instance:
		return
	
	# Use custom material if set
	if terrain_material:
		_mesh_instance.material_override = terrain_material
		return
	
	# Create shader material if needed
	if not _shader_material:
		_shader_material = ShaderMaterial.new()
		var shader = load("res://addons/terrainy/shaders/terrain_material.gdshader")
		_shader_material.shader = shader
	
	_mesh_instance.material_override = _shader_material
	
	# Update shader with texture layers
	if texture_layers.is_empty():
		_shader_material.set_shader_parameter("layer_count", 0)
		return
	
	_build_texture_arrays()

func _build_texture_arrays() -> void:
	if texture_layers.is_empty():
		return
	
	var layer_count = min(texture_layers.size(), 32)
	_shader_material.set_shader_parameter("layer_count", layer_count)
	
	# Prepare layer parameter arrays
	var height_slope_params: Array[Vector4] = []
	var blend_params: Array[Vector4] = []
	var uv_params: Array[Vector4] = []
	var color_normal: Array[Vector4] = []
	var pbr_params: Array[Vector4] = []
	var texture_flags: Array[Vector4] = []
	var extra_flags: Array[Vector4] = []
	
	# Collect textures
	var albedo_images: Array[Image] = []
	var normal_images: Array[Image] = []
	var roughness_images: Array[Image] = []
	var metallic_images: Array[Image] = []
	var ao_images: Array[Image] = []
	
	var texture_size = Vector2i(2048, 2048)
	
	for i in range(layer_count):
		var layer = texture_layers[i]
		if not layer:
			continue
		
		# Pack parameters
		height_slope_params.append(Vector4(
			layer.height_min,
			layer.height_max,
			layer.height_falloff,
			deg_to_rad(layer.slope_min)
		))
		
		blend_params.append(Vector4(
			layer.layer_strength,
			deg_to_rad(layer.slope_max),
			deg_to_rad(layer.slope_falloff),
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
		
		# Texture flags: [has_albedo, has_normal, has_roughness, has_metallic]
		texture_flags.append(Vector4(
			1.0 if layer.albedo_texture else 0.0,
			1.0 if layer.normal_texture else 0.0,
			1.0 if layer.roughness_texture else 0.0,
			1.0 if layer.metallic_texture else 0.0
		))
		
		# Extra flags: [has_ao, use_height_curve, use_slope_curve, unused]
		extra_flags.append(Vector4(
			1.0 if layer.ao_texture else 0.0,
			0.0,
			0.0,
			0.0
		))
		
		# Get textures
		albedo_images.append(_get_or_create_image(layer.albedo_texture, texture_size, layer.albedo_color))
		normal_images.append(_get_or_create_image(layer.normal_texture, texture_size, Color(0.5, 0.5, 1.0)))
		roughness_images.append(_get_or_create_image(layer.roughness_texture, texture_size, Color(layer.roughness, layer.roughness, layer.roughness)))
		metallic_images.append(_get_or_create_image(layer.metallic_texture, texture_size, Color(layer.metallic, layer.metallic, layer.metallic)))
		ao_images.append(_get_or_create_image(layer.ao_texture, texture_size, Color(layer.ao_strength, layer.ao_strength, layer.ao_strength)))
	
	# Set shader parameters
	_shader_material.set_shader_parameter("layer_height_slope_params", height_slope_params)
	_shader_material.set_shader_parameter("layer_blend_params", blend_params)
	_shader_material.set_shader_parameter("layer_uv_params", uv_params)
	_shader_material.set_shader_parameter("layer_color_normal", color_normal)
	_shader_material.set_shader_parameter("layer_pbr_params", pbr_params)
	_shader_material.set_shader_parameter("layer_texture_flags", texture_flags)
	_shader_material.set_shader_parameter("layer_extra_flags", extra_flags)
	
	# Set texture index mapping (identity for now: layer i → texture slot i)
	var texture_indices: PackedInt32Array = []
	for i in range(layer_count):
		texture_indices.append(i)
	_shader_material.set_shader_parameter("layer_texture_index", texture_indices)
	
	# Create texture arrays
	var albedo_array = _create_texture_array(albedo_images)
	var normal_array = _create_texture_array(normal_images)
	var roughness_array = _create_texture_array(roughness_images)
	var metallic_array = _create_texture_array(metallic_images)
	var ao_array = _create_texture_array(ao_images)
	
	# Set to shader
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

func _get_or_create_image(texture: Texture2D, size: Vector2i, default_color: Color) -> Image:
	if texture:
		var img = texture.get_image()
		if img.get_size() != size:
			img.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		# Generate mipmaps for better filtering at distance
		if not img.has_mipmaps():
			img.generate_mipmaps()
		return img
	else:
		var img = Image.create(size.x, size.y, true, Image.FORMAT_RGBA8)
		img.fill(default_color)
		img.generate_mipmaps()
		return img

func _create_texture_array(images: Array[Image]) -> Texture2DArray:
	if images.is_empty():
		return null
	
	var size = images[0].get_size()
	var format = Image.FORMAT_RGBA8
	var has_mipmaps = images[0].has_mipmaps()
	
	# Ensure all images have consistent properties
	for i in range(images.size()):
		if images[i].get_size() != size:
			images[i].resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
		if images[i].get_format() != format:
			images[i].convert(format)
		# Ensure consistent mipmap state
		if has_mipmaps and not images[i].has_mipmaps():
			images[i].generate_mipmaps()
		elif not has_mipmaps and images[i].has_mipmaps():
			images[i].clear_mipmaps()
	
	var texture_array = Texture2DArray.new()
	texture_array.create_from_images(images)
	
	return texture_array
