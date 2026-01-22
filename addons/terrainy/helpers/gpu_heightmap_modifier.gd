class_name GpuHeightmapModifier
extends RefCounted

## GPU-accelerated heightmap modifier using compute shaders
## Handles smoothing, terracing, and clamping operations on heightmaps

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _initialized: bool = false

func _init() -> void:
	if not RenderingServer.get_rendering_device():
		push_warning("[GpuHeightmapModifier] Compatibility renderer detected, GPU modifiers disabled")
		return
	_rd = RenderingServer.create_local_rendering_device()
	if not _rd:
		push_warning("[GpuHeightmapModifier] Failed to create RenderingDevice")
		return
	
	_load_shader()

func _load_shader() -> void:
	var shader_file = load("res://addons/terrainy/shaders/heightmap_modifiers.glsl")
	if not shader_file:
		push_error("[GpuHeightmapModifier] Failed to load modifier shader")
		return
	
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if not shader_spirv:
		push_error("[GpuHeightmapModifier] Shader compilation failed")
		return
	
	var compile_error = shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_error != "":
		push_error("[GpuHeightmapModifier] Shader error: %s" % compile_error)
		return
	
	_shader = _rd.shader_create_from_spirv(shader_spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_initialized = true
	print("[GpuHeightmapModifier] GPU modifier initialized")

func is_available() -> bool:
	return _initialized

## Clean up GPU resources
func cleanup() -> void:
	if not _initialized or not _rd:
		return
	
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	
	_initialized = false
	print("[GpuHeightmapModifier] GPU resources cleaned up")

## Apply modifiers to heightmap on GPU
func apply_modifiers(
	input_heightmap: Image,
	smoothing_mode: int,
	smoothing_radius: float,
	enable_terracing: bool,
	terrace_levels: int,
	terrace_smoothness: float,
	enable_min_clamp: bool,
	min_height: float,
	enable_max_clamp: bool,
	max_height: float
) -> Image:
	if not _initialized:
		return null
	
	var start_time = Time.get_ticks_msec()
	var resolution = Vector2i(input_heightmap.get_width(), input_heightmap.get_height())
	
	# Create input texture from heightmap
	var input_format := RDTextureFormat.new()
	input_format.width = resolution.x
	input_format.height = resolution.y
	input_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	input_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	
	# Convert to RF if needed
	if input_heightmap.get_format() != Image.FORMAT_RF:
		input_heightmap = input_heightmap.duplicate()
		input_heightmap.convert(Image.FORMAT_RF)
	
	var input_texture := _rd.texture_create(input_format, RDTextureView.new(), [input_heightmap.get_data()])
	if not input_texture.is_valid():
		push_error("[GpuHeightmapModifier] Failed to create input texture")
		return null
	
	# Create output texture
	var output_format := RDTextureFormat.new()
	output_format.width = resolution.x
	output_format.height = resolution.y
	output_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	output_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var output_texture := _rd.texture_create(output_format, RDTextureView.new())
	if not output_texture.is_valid():
		push_error("[HeightmapModifierProcessor] Failed to create output texture")
		_rd.free_rid(input_texture)
		return null
	
	# Create uniforms
	var uniforms: Array[RDUniform] = []
	
	# Input heightmap
	var input_uniform := RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	input_uniform.binding = 0
	input_uniform.add_id(input_texture)
	uniforms.append(input_uniform)
	
	# Output heightmap
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 1
	output_uniform.add_id(output_texture)
	uniforms.append(output_uniform)
	
	# Parameters buffer
	var params_bytes := PackedByteArray()
	params_bytes.resize(48)  # 12 fields * 4 bytes
	params_bytes.encode_s32(0, smoothing_mode)
	params_bytes.encode_float(4, smoothing_radius)
	params_bytes.encode_s32(8, 1 if enable_terracing else 0)
	params_bytes.encode_s32(12, terrace_levels)
	params_bytes.encode_float(16, terrace_smoothness)
	params_bytes.encode_s32(20, 1 if enable_min_clamp else 0)
	params_bytes.encode_float(24, min_height)
	params_bytes.encode_s32(28, 1 if enable_max_clamp else 0)
	params_bytes.encode_float(32, max_height)
	params_bytes.encode_s32(36, resolution.x)
	params_bytes.encode_s32(40, resolution.y)
	params_bytes.encode_s32(44, 0)  # padding
	
	var params_buffer := _rd.uniform_buffer_create(params_bytes.size(), params_bytes)
	
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 2
	params_uniform.add_id(params_buffer)
	uniforms.append(params_uniform)
	
	# Create uniform set
	var uniform_set := _rd.uniform_set_create(uniforms, _shader, 0)
	
	# Dispatch compute shader
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
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
	var result_image := Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, output_bytes)
	
	# Cleanup
	_rd.free_rid(input_texture)
	_rd.free_rid(output_texture)
	_rd.free_rid(params_buffer)
	
	var elapsed: int = Time.get_ticks_msec() - start_time
	print("[GpuHeightmapModifier] Applied modifiers (%dx%d) in %d ms" % [
		resolution.x, resolution.y, elapsed
	])
	
	return result_image

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _initialized and _rd:
			if _pipeline.is_valid():
				_rd.free_rid(_pipeline)
			if _shader.is_valid():
				_rd.free_rid(_shader)
