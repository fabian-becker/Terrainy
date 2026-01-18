class_name HeightmapCompositor
extends RefCounted

## GPU-accelerated heightmap compositor using compute shaders

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _initialized: bool = false

func _init() -> void:
	print("[HeightmapCompositor] Initializing GPU compositor...")
	_rd = RenderingServer.create_local_rendering_device()
	if not _rd:
		push_warning("[HeightmapCompositor] Failed to create RenderingDevice, GPU composition unavailable")
		return
	
	print("[HeightmapCompositor] RenderingDevice created successfully")
	_load_shader()

func _load_shader() -> void:
	print("[HeightmapCompositor] Loading compute shader...")
	var shader_file = load("res://addons/terrainy/shaders/heightmap_compositor.glsl")
	if not shader_file:
		push_error("[HeightmapCompositor] Failed to load compute shader file")
		return
	
	print("[HeightmapCompositor] Shader file loaded, compiling...")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if not shader_spirv:
		push_error("[HeightmapCompositor] Shader compilation failed - could not get SPIRV")
		return
	
	var compile_error = shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_error != "":
		push_error("[HeightmapCompositor] Shader compilation error: %s" % compile_error)
		return
	
	_shader = _rd.shader_create_from_spirv(shader_spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_initialized = true
	print("[HeightmapCompositor] GPU compositor initialized")

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
	print("[HeightmapCompositor] GPU resources cleaned up")

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
	var layer_count = mini(feature_heightmaps.size(), 32)
	if feature_heightmaps.size() > 32:
		push_warning("[HeightmapCompositor] Too many layers (%d), clamping to 32" % feature_heightmaps.size())
	
	# Flatten heightmap data into single buffer
	var total_pixels = resolution.x * resolution.y
	var heightmap_buffer_data := PackedFloat32Array()
	heightmap_buffer_data.resize(total_pixels * layer_count)
	
	for layer_idx in range(layer_count):
		var img = feature_heightmaps[layer_idx]
		for y in range(resolution.y):
			for x in range(resolution.x):
				var pixel = img.get_pixel(x, y)
				var buffer_index = layer_idx * total_pixels + y * resolution.x + x
				heightmap_buffer_data[buffer_index] = pixel.r
	
	# Flatten influence data into single buffer
	var influence_buffer_data := PackedFloat32Array()
	influence_buffer_data.resize(total_pixels * layer_count)
	
	for layer_idx in range(layer_count):
		var img = influence_maps[layer_idx]
		for y in range(resolution.y):
			for x in range(resolution.x):
				var pixel = img.get_pixel(x, y)
				var buffer_index = layer_idx * total_pixels + y * resolution.x + x
				influence_buffer_data[buffer_index] = pixel.r
	
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
	var uniform_set := _rd.uniform_set_create(uniforms, _shader, 0)
	
	# Dispatch compute shader
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
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
			if _pipeline.is_valid():
				_rd.free_rid(_pipeline)
			if _shader.is_valid():
				_rd.free_rid(_shader)
