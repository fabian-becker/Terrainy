class_name GpuHeightmapBlender
extends RefCounted

## GPU-accelerated heightmap blender using compute shaders
## Handles composition of multiple heightmaps with influence maps on the GPU

var _rd: RenderingDevice
var _compositor_shader: RID
var _compositor_pipeline: RID
var _influence_shader: RID
var _influence_pipeline: RID
var _initialized: bool = false

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")

func _init() -> void:
	print("[GpuHeightmapBlender] Initializing GPU blender...")
	if not RenderingServer.get_rendering_device():
		push_warning("[GpuHeightmapBlender] Compatibility renderer detected, GPU composition disabled")
		return
	_rd = RenderingServer.create_local_rendering_device()
	if not _rd:
		push_warning("[GpuHeightmapBlender] Failed to create RenderingDevice, GPU composition unavailable")
		return
	
	print("[GpuHeightmapBlender] RenderingDevice created successfully")
	_load_shaders()

func _load_shaders() -> void:
	# Load compositor shader
	print("[GpuHeightmapBlender] Loading compositor shader...")
	var compositor_file = load("res://addons/terrainy/shaders/heightmap_compositor.glsl")
	if not compositor_file:
		push_error("[GpuHeightmapBlender] Failed to load compositor shader file")
		return
	
	print("[GpuHeightmapBlender] Compositor shader file loaded, compiling...")
	var compositor_spirv: RDShaderSPIRV = compositor_file.get_spirv()
	if not compositor_spirv:
		push_error("[GpuHeightmapBlender] Compositor shader compilation failed - could not get SPIRV")
		return
	
	var compile_error = compositor_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_error != "":
		push_error("[GpuHeightmapBlender] Compositor shader compilation error: %s" % compile_error)
		return
	
	_compositor_shader = _rd.shader_create_from_spirv(compositor_spirv)
	_compositor_pipeline = _rd.compute_pipeline_create(_compositor_shader)
	
	# Load influence generator shader
	print("[GpuHeightmapBlender] Loading influence generator shader...")
	var influence_file = load("res://addons/terrainy/shaders/influence_generator.glsl")
	if not influence_file:
		push_error("[GpuHeightmapBlender] Failed to load influence generator shader file")
		return
	
	print("[GpuHeightmapBlender] Influence shader file loaded, compiling...")
	var influence_spirv: RDShaderSPIRV = influence_file.get_spirv()
	if not influence_spirv:
		push_error("[GpuHeightmapBlender] Influence shader compilation failed - could not get SPIRV")
		return
	
	compile_error = influence_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_error != "":
		push_error("[GpuHeightmapBlender] Influence shader compilation error: %s" % compile_error)
		return
	
	_influence_shader = _rd.shader_create_from_spirv(influence_spirv)
	_influence_pipeline = _rd.compute_pipeline_create(_influence_shader)
	_initialized = true
	print("[GpuHeightmapBlender] GPU blender initialized")

func is_available() -> bool:
	return _initialized

## Clean up GPU resources
func cleanup() -> void:
	if not _initialized or not _rd:
		return
	
	if _compositor_pipeline.is_valid():
		_rd.free_rid(_compositor_pipeline)
	if _compositor_shader.is_valid():
		_rd.free_rid(_compositor_shader)
	if _influence_pipeline.is_valid():
		_rd.free_rid(_influence_pipeline)
	if _influence_shader.is_valid():
		_rd.free_rid(_influence_shader)
	
	_initialized = false
	print("[GpuHeightmapBlender] GPU resources cleaned up")

## Generate influence map on GPU for a feature
func generate_influence_map_gpu(
	feature: TerrainFeatureNode,
	resolution: Vector2i,
	terrain_bounds: Rect2
) -> Image:
	if not _initialized:
		push_error("[GpuHeightmapBlender] GPU not initialized")
		return null
	
	# Create output texture
	var output_format := RDTextureFormat.new()
	output_format.width = resolution.x
	output_format.height = resolution.y
	output_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	output_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var output_texture := _rd.texture_create(output_format, RDTextureView.new())
	if not output_texture.is_valid():
		push_error("[GpuHeightmapBlender] Failed to create output texture for influence map")
		return null
	
	# Get feature transform
	var global_transform = feature.global_transform
	var inverse_transform = global_transform.affine_inverse()
	
	# Create parameters buffer
	var params_bytes := PackedByteArray()
	params_bytes.resize(16 + 16 + 16 + 16 + 64)  # 4 vec4s + mat4
	
	# Feature position (vec4)
	var pos = global_transform.origin
	params_bytes.encode_float(0, pos.x)
	params_bytes.encode_float(4, pos.y)
	params_bytes.encode_float(8, pos.z)
	params_bytes.encode_float(12, 0.0)
	
	# Terrain bounds (vec4)
	params_bytes.encode_float(16, terrain_bounds.position.x)
	params_bytes.encode_float(20, terrain_bounds.position.y)
	params_bytes.encode_float(24, terrain_bounds.size.x)
	params_bytes.encode_float(28, terrain_bounds.size.y)
	
	# Influence parameters (vec4)
	params_bytes.encode_float(32, feature.influence_size.x)
	params_bytes.encode_float(36, feature.influence_size.y)
	params_bytes.encode_float(40, float(feature.influence_shape))
	params_bytes.encode_float(44, feature.edge_falloff)
	
	# Resolution (ivec4)
	params_bytes.encode_s32(48, resolution.x)
	params_bytes.encode_s32(52, resolution.y)
	params_bytes.encode_s32(56, 0)
	params_bytes.encode_s32(60, 0)
	
	# Inverse transform matrix (mat4 - 16 floats)
	var basis = inverse_transform.basis
	var origin = inverse_transform.origin
	params_bytes.encode_float(64, basis.x.x)
	params_bytes.encode_float(68, basis.x.y)
	params_bytes.encode_float(72, basis.x.z)
	params_bytes.encode_float(76, 0.0)
	params_bytes.encode_float(80, basis.y.x)
	params_bytes.encode_float(84, basis.y.y)
	params_bytes.encode_float(88, basis.y.z)
	params_bytes.encode_float(92, 0.0)
	params_bytes.encode_float(96, basis.z.x)
	params_bytes.encode_float(100, basis.z.y)
	params_bytes.encode_float(104, basis.z.z)
	params_bytes.encode_float(108, 0.0)
	params_bytes.encode_float(112, origin.x)
	params_bytes.encode_float(116, origin.y)
	params_bytes.encode_float(120, origin.z)
	params_bytes.encode_float(124, 1.0)
	
	var params_buffer := _rd.uniform_buffer_create(params_bytes.size(), params_bytes)
	
	# Create uniforms
	var uniforms: Array[RDUniform] = []
	
	# Output texture
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 0
	output_uniform.add_id(output_texture)
	uniforms.append(output_uniform)
	
	# Parameters
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 1
	params_uniform.add_id(params_buffer)
	uniforms.append(params_uniform)
	
	# Create uniform set
	var uniform_set := _rd.uniform_set_create(uniforms, _influence_shader, 0)
	
	# Dispatch compute shader
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _influence_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	var dispatch_x := ceili(resolution.x / 8.0)
	var dispatch_y := ceili(resolution.y / 8.0)
	_rd.compute_list_dispatch(compute_list, dispatch_x, dispatch_y, 1)
	_rd.compute_list_end()
	
	# Submit and sync
	_rd.submit()
	_rd.sync()
	
	# Read back result
	var output_bytes := _rd.texture_get_data(output_texture, 0)
	var influence_map := Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, output_bytes)
	
	# Cleanup
	_rd.free_rid(output_texture)
	_rd.free_rid(params_buffer)
	
	return influence_map

## Compose heightmaps on GPU - returns final heightmap Image
func compose_gpu(
	resolution: Vector2i,
	base_height: float,
	feature_heightmaps: Array[Image],
	influence_maps: Array[Image],
	blend_modes: PackedInt32Array,
	strengths: PackedFloat32Array
) -> Image:
	if not _initialized:
		push_error("[HeightmapCompositor] GPU compositor not initialized")
		return null
	
	# Validate inputs
	if feature_heightmaps.size() != influence_maps.size():
		push_error("[HeightmapCompositor] Heightmap and influence map count mismatch")
		return null
	
	if feature_heightmaps.size() == 0:
		push_warning("[HeightmapCompositor] No features to compose")
		var base_map = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
		base_map.fill(Color(base_height, 0, 0, 1))
		return base_map
	
	var start_time = Time.get_ticks_msec()
	
	# Create output texture (R32F for 4x less bandwidth than RGBA32F)
	var output_format := RDTextureFormat.new()
	output_format.width = resolution.x
	output_format.height = resolution.y
	output_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	output_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var output_texture := _rd.texture_create(output_format, RDTextureView.new())
	if not output_texture.is_valid():
		push_error("[HeightmapCompositor] Failed to create output texture")
		return null
	
	# Clamp to 32 layers max (shader limitation)
	var layer_count := mini(feature_heightmaps.size(), 32)
	if feature_heightmaps.size() > 32:
		push_warning("[HeightmapCompositor] Too many layers (%d), clamping to 32" % feature_heightmaps.size())
	
	# Flatten heightmap data into single buffer using native array append
	var total_pixels := resolution.x * resolution.y
	var heightmap_buffer_data := PackedFloat32Array()
	heightmap_buffer_data.resize(total_pixels * layer_count)
	
	for layer_idx in layer_count:
		var layer_heights := feature_heightmaps[layer_idx].get_data().to_float32_array()
		var buffer_offset := layer_idx * total_pixels
		for i in total_pixels:
			heightmap_buffer_data[buffer_offset + i] = layer_heights[i]
	
	# Flatten influence data into single buffer
	var influence_buffer_data := PackedFloat32Array()
	influence_buffer_data.resize(total_pixels * layer_count)
	
	for layer_idx in layer_count:
		var layer_influence := influence_maps[layer_idx].get_data().to_float32_array()
		var buffer_offset := layer_idx * total_pixels
		for i in total_pixels:
			influence_buffer_data[buffer_offset + i] = layer_influence[i]
	
	# Create storage buffers
	var heightmap_buffer := _rd.storage_buffer_create(heightmap_buffer_data.size() * 4, heightmap_buffer_data.to_byte_array())
	if not heightmap_buffer.is_valid():
		push_error("[HeightmapCompositor] Failed to create heightmap buffer")
		_rd.free_rid(output_texture)
		return null
	
	var influence_buffer := _rd.storage_buffer_create(influence_buffer_data.size() * 4, influence_buffer_data.to_byte_array())
	if not influence_buffer.is_valid():
		push_error("[HeightmapCompositor] Failed to create influence buffer")
		_rd.free_rid(output_texture)
		_rd.free_rid(heightmap_buffer)
		return null
	
	# Create uniform set
	var uniforms: Array[RDUniform] = []
	
	# Output heightmap
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 0
	output_uniform.add_id(output_texture)
	uniforms.append(output_uniform)
	
	# Heightmap storage buffer
	var heightmap_uniform := RDUniform.new()
	heightmap_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	heightmap_uniform.binding = 1
	heightmap_uniform.add_id(heightmap_buffer)
	uniforms.append(heightmap_uniform)
	
	# Influence storage buffer
	var influence_uniform := RDUniform.new()
	influence_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	influence_uniform.binding = 2
	influence_uniform.add_id(influence_buffer)
	uniforms.append(influence_uniform)
	
	# Parameters buffer
	var params_data := PackedInt32Array([
		layer_count,
		0,  # padding
		resolution.x,
		resolution.y
	])
	var params_bytes := PackedByteArray()
	params_bytes.resize(16)  # 4 ints
	params_bytes.encode_s32(0, params_data[0])
	params_bytes.encode_float(4, base_height)
	params_bytes.encode_s32(8, params_data[2])
	params_bytes.encode_s32(12, params_data[3])
	
	var params_buffer := _rd.uniform_buffer_create(params_bytes.size(), params_bytes)
	
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 3
	params_uniform.add_id(params_buffer)
	uniforms.append(params_uniform)
	
	# Layer data buffer
	var layer_bytes := PackedByteArray()
	layer_bytes.resize(32 * 16)  # 32 vec4s
	for i in range(32):
		var offset = i * 16
		if i < blend_modes.size():
			layer_bytes.encode_float(offset, float(blend_modes[i]))
			layer_bytes.encode_float(offset + 4, strengths[i])
			layer_bytes.encode_float(offset + 8, 0.0)
			layer_bytes.encode_float(offset + 12, 0.0)
		else:
			layer_bytes.encode_float(offset, 0.0)
			layer_bytes.encode_float(offset + 4, 0.0)
			layer_bytes.encode_float(offset + 8, 0.0)
			layer_bytes.encode_float(offset + 12, 0.0)
	
	var layer_buffer := _rd.uniform_buffer_create(layer_bytes.size(), layer_bytes)
	
	var layer_uniform := RDUniform.new()
	layer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	layer_uniform.binding = 4
	layer_uniform.add_id(layer_buffer)
	uniforms.append(layer_uniform)
	
	# Create uniform set
	var uniform_set := _rd.uniform_set_create(uniforms, _compositor_shader, 0)
	
	# Dispatch compute shader
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _compositor_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Calculate dispatch size (8x8 work groups)
	var dispatch_x := ceili(resolution.x / 8.0)
	var dispatch_y := ceili(resolution.y / 8.0)
	_rd.compute_list_dispatch(compute_list, dispatch_x, dispatch_y, 1)
	_rd.compute_list_end()
	
	# Submit and sync - wrap in error handling
	_rd.submit()
	_rd.sync()
	
	# Read back result (already in R32F format, no conversion needed)
	var output_bytes := _rd.texture_get_data(output_texture, 0)
	var final_image := Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, output_bytes)
	
	# Cleanup
	_rd.free_rid(output_texture)
	_rd.free_rid(params_buffer)
	_rd.free_rid(layer_buffer)
	_rd.free_rid(heightmap_buffer)
	_rd.free_rid(influence_buffer)
	
	var elapsed: int = Time.get_ticks_msec() - start_time
	print("[HeightmapCompositor] GPU composition (%dx%d, %d layers) in %d ms" % [
		resolution.x, resolution.y, feature_heightmaps.size(), elapsed
	])
	
	return final_image

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _initialized and _rd:
			if _compositor_pipeline.is_valid():
				_rd.free_rid(_compositor_pipeline)
			if _compositor_shader.is_valid():
				_rd.free_rid(_compositor_shader)
			if _influence_pipeline.is_valid():
				_rd.free_rid(_influence_pipeline)
			if _influence_shader.is_valid():
				_rd.free_rid(_influence_shader)
