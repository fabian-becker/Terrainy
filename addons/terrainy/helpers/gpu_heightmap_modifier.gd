class_name GpuHeightmapModifier
extends RefCounted

const GpuDevice = preload("res://addons/terrainy/helpers/gpu_device.gd")

## GPU-accelerated heightmap modifier using compute shaders
## Handles smoothing, terracing, and clamping operations on heightmaps

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _initialized: bool = false
var _init_failed: bool = false

static var _unavailable_warned: bool = false

func _init() -> void:
	# Initialization is deferred to the first actual use: creating a RenderingDevice and
	# compiling the compute shader for every feature node that owns a modifier pipeline
	# is expensive and usually unnecessary.
	pass

## Create the RenderingDevice and compile the shader on first use.
func _ensure_initialized() -> bool:
	if _initialized:
		return true
	if _init_failed:
		return false
	_rd = GpuDevice.get_device()
	if not _rd:
		_init_failed = true
		if not _unavailable_warned:
			_unavailable_warned = true
			push_warning("[GpuHeightmapModifier] No RenderingDevice available (compatibility renderer?), GPU modifiers disabled")
		return false

	_load_shader()
	if not _initialized:
		_init_failed = true
	return _initialized

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
	return _ensure_initialized()

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

## Apply modifiers to a single heightmap on GPU
func apply_modifiers(
	input_heightmap: Image,
	terrain_bounds: Rect2,
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
	var results := apply_modifiers_batch([{
		"heightmap": input_heightmap,
		"bounds": terrain_bounds,
		"smoothing": smoothing_mode,
		"smoothing_radius": smoothing_radius,
		"enable_terracing": enable_terracing,
		"terrace_levels": terrace_levels,
		"terrace_smoothness": terrace_smoothness,
		"enable_min_clamp": enable_min_clamp,
		"min_height": min_height,
		"enable_max_clamp": enable_max_clamp,
		"max_height": max_height
	}])
	if results.size() > 0 and results[0] != null:
		return results[0]
	return null

## Apply modifiers to several heightmaps. All dispatches are recorded into a single
## compute list and submitted once, which removes the per-heightmap submit+sync stall.
## Returns an Array parallel to `items`; entries are null when that item could not be
## dispatched (the caller falls back to the CPU implementation).
func apply_modifiers_batch(items: Array) -> Array:
	var results: Array = []
	results.resize(items.size())
	if items.is_empty():
		return results
	if not _ensure_initialized():
		return results

	var start_time = Time.get_ticks_msec()

	# Texture creation and uploads must happen *before* a compute list is opened: the
	# rendering device rejects texture updates while a compute list is being recorded.
	# So every item is prepared first, then all dispatches are recorded into one list.
	var dispatches: Array = []
	for i in items.size():
		var dispatch := _prepare_dispatch(items[i])
		if dispatch.is_empty():
			continue
		dispatch["index"] = i
		dispatches.append(dispatch)

	if dispatches.is_empty():
		return results

	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	for dispatch in dispatches:
		_rd.compute_list_bind_uniform_set(compute_list, dispatch["uniform_set"], 0)
		_rd.compute_list_dispatch(compute_list, dispatch["dispatch_x"], dispatch["dispatch_y"], 1)
	_rd.compute_list_end()

	# Submit and sync once for all heightmaps
	_rd.submit()
	_rd.sync()

	for dispatch in dispatches:
		var resolution: Vector2i = dispatch["resolution"]
		var output_bytes := _rd.texture_get_data(dispatch["output_texture"], 0)
		results[dispatch["index"]] = Image.create_from_data(
			resolution.x, resolution.y, false, Image.FORMAT_RF, output_bytes
		)
		_release_dispatch(dispatch)

	print("[GpuHeightmapModifier] Applied modifiers to %d heightmap(s) in %d ms" % [
		dispatches.size(), Time.get_ticks_msec() - start_time
	])

	return results

## Create the GPU resources required to dispatch one heightmap. Returns an empty
## Dictionary when the item cannot be processed (then nothing has to be released).
func _prepare_dispatch(item: Dictionary) -> Dictionary:
	var input_heightmap: Image = item.get("heightmap")
	if input_heightmap == null:
		return {}

	var resolution := Vector2i(input_heightmap.get_width(), input_heightmap.get_height())
	if resolution.x <= 0 or resolution.y <= 0:
		return {}

	# Decompress and convert to RF if needed (never mutate the caller's image)
	var source := input_heightmap
	if source.is_compressed() or source.get_format() != Image.FORMAT_RF:
		source = source.duplicate()
		if source.is_compressed():
			source.decompress()
		if source.get_format() != Image.FORMAT_RF:
			source.convert(Image.FORMAT_RF)
	var height_bytes := source.get_data()

	var enable_terracing: bool = item.get("enable_terracing", false)
	var terrace_levels: int = item.get("terrace_levels", 5)
	var max_abs_height := 0.0
	if enable_terracing:
		var height_data := height_bytes.to_float32_array()
		for h in height_data:
			max_abs_height = max(max_abs_height, abs(h))
		if max_abs_height < 0.001:
			enable_terracing = false

	# Compute step size (world units per pixel) for smoothing radius conversion
	var terrain_bounds: Rect2 = item.get("bounds", Rect2())
	var step_x := terrain_bounds.size.x / float(max(resolution.x - 1, 1))
	var step_y := terrain_bounds.size.y / float(max(resolution.y - 1, 1))

	var input_texture := _create_texture(resolution, true)
	if not input_texture.is_valid():
		push_error("[GpuHeightmapModifier] Failed to create input texture")
		return {}
	var update_error := _rd.texture_update(input_texture, 0, height_bytes)
	if update_error != OK:
		push_error("[GpuHeightmapModifier] Failed to upload input heightmap data")
		_rd.free_rid(input_texture)
		return {}

	var output_texture := _create_texture(resolution, false)
	if not output_texture.is_valid():
		push_error("[GpuHeightmapModifier] Failed to create output texture")
		_rd.free_rid(input_texture)
		return {}

	var params_bytes := PackedByteArray()
	params_bytes.resize(64)  # 15 fields + 1 padding (std140 requires 16-byte alignment)
	params_bytes.encode_s32(0, item.get("smoothing", 0))
	params_bytes.encode_float(4, item.get("smoothing_radius", 2.0))
	params_bytes.encode_s32(8, 1 if enable_terracing else 0)
	params_bytes.encode_s32(12, terrace_levels)
	params_bytes.encode_float(16, item.get("terrace_smoothness", 0.2))
	params_bytes.encode_s32(20, 1 if item.get("enable_min_clamp", false) else 0)
	params_bytes.encode_float(24, item.get("min_height", 0.0))
	params_bytes.encode_s32(28, 1 if item.get("enable_max_clamp", false) else 0)
	params_bytes.encode_float(32, item.get("max_height", 100.0))
	params_bytes.encode_s32(36, resolution.x)
	params_bytes.encode_s32(40, resolution.y)
	params_bytes.encode_float(44, step_x)       # world units per pixel (X)
	params_bytes.encode_float(48, step_y)       # world units per pixel (Y)
	params_bytes.encode_float(52, max_abs_height)  # actual height range for terracing
	params_bytes.encode_s32(56, 0)  # padding
	params_bytes.encode_s32(60, 0)  # padding

	var params_buffer := _rd.uniform_buffer_create(params_bytes.size(), params_bytes)

	var uniforms: Array[RDUniform] = []

	var input_uniform := RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	input_uniform.binding = 0
	input_uniform.add_id(input_texture)
	uniforms.append(input_uniform)

	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 1
	output_uniform.add_id(output_texture)
	uniforms.append(output_uniform)

	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 2
	params_uniform.add_id(params_buffer)
	uniforms.append(params_uniform)

	var uniform_set := _rd.uniform_set_create(uniforms, _shader, 0)

	return {
		"resolution": resolution,
		"input_texture": input_texture,
		"output_texture": output_texture,
		"params_buffer": params_buffer,
		"uniform_set": uniform_set,
		"dispatch_x": ceili(resolution.x / 8.0),
		"dispatch_y": ceili(resolution.y / 8.0)
	}

func _create_texture(resolution: Vector2i, is_input: bool) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.width = resolution.x
	texture_format.height = resolution.y
	texture_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	if is_input:
		texture_format.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	else:
		texture_format.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(texture_format, RDTextureView.new())

func _release_dispatch(dispatch: Dictionary) -> void:
	var uniform_set: RID = dispatch["uniform_set"]
	var input_texture: RID = dispatch["input_texture"]
	var output_texture: RID = dispatch["output_texture"]
	var params_buffer: RID = dispatch["params_buffer"]
	if uniform_set.is_valid():
		_rd.free_rid(uniform_set)
	if input_texture.is_valid():
		_rd.free_rid(input_texture)
	if output_texture.is_valid():
		_rd.free_rid(output_texture)
	if params_buffer.is_valid():
		_rd.free_rid(params_buffer)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _initialized and _rd:
			if _pipeline.is_valid():
				_rd.free_rid(_pipeline)
			if _shader.is_valid():
				_rd.free_rid(_shader)
		_rd = null
