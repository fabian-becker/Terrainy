class_name GpuFeatureEvaluator
extends RefCounted

## GPU feature evaluator stub for upcoming GPU-first pipeline.
## This initializes a compute pipeline but does not yet implement kernels.

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _initialized: bool = false

const SUPPORTED_TYPES := {
	TerrainFeatureNode.FeatureType.PRIMITIVE_HILL: true,
	TerrainFeatureNode.FeatureType.PRIMITIVE_MOUNTAIN: true,
	TerrainFeatureNode.FeatureType.PRIMITIVE_CRATER: true,
	TerrainFeatureNode.FeatureType.PRIMITIVE_VOLCANO: true,
	TerrainFeatureNode.FeatureType.PRIMITIVE_ISLAND: true,
	TerrainFeatureNode.FeatureType.SHAPE: true,
	TerrainFeatureNode.FeatureType.HEIGHTMAP: true,
	TerrainFeatureNode.FeatureType.GRADIENT_LINEAR: true,
	TerrainFeatureNode.FeatureType.GRADIENT_RADIAL: true,
	TerrainFeatureNode.FeatureType.GRADIENT_CONE: true,
	TerrainFeatureNode.FeatureType.GRADIENT_HEMISPHERE: true,
	TerrainFeatureNode.FeatureType.LANDSCAPE_CANYON: true,
	TerrainFeatureNode.FeatureType.LANDSCAPE_MOUNTAIN_RANGE: true,
	TerrainFeatureNode.FeatureType.LANDSCAPE_DUNE_SEA: true,
	TerrainFeatureNode.FeatureType.NOISE_PERLIN: true,
	TerrainFeatureNode.FeatureType.NOISE_VORONOI: true
}

func _init() -> void:
	if not RenderingServer.get_rendering_device():
		push_warning("[GpuFeatureEvaluator] Compatibility renderer detected, GPU evaluation disabled")
		return
	_rd = RenderingServer.create_local_rendering_device()
	if not _rd:
		push_warning("[GpuFeatureEvaluator] Failed to create RenderingDevice")
		return
	_load_shader()

func _load_shader() -> void:
	var shader_file = load("res://addons/terrainy/shaders/feature_evaluator.glsl")
	if not shader_file:
		push_error("[GpuFeatureEvaluator] Failed to load feature evaluator shader")
		return
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if not shader_spirv:
		push_error("[GpuFeatureEvaluator] Shader compilation failed - no SPIRV")
		return
	var compile_error = shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_error != "":
		push_error("[GpuFeatureEvaluator] Shader error: %s" % compile_error)
		return
	_shader = _rd.shader_create_from_spirv(shader_spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_initialized = true
	print("[GpuFeatureEvaluator] GPU evaluator initialized")

func is_available() -> bool:
	return _initialized

func cleanup() -> void:
	if not _initialized or not _rd:
		return
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_initialized = false
	print("[GpuFeatureEvaluator] GPU resources cleaned up")

## Stub for future GPU feature evaluation
func evaluate_features_gpu(
	resolution: Vector2i,
	terrain_bounds: Rect2,
	param_packs: Array
) -> Image:
	if not _initialized:
		push_error("[GpuFeatureEvaluator] GPU evaluator not initialized")
		return null
	push_warning("[GpuFeatureEvaluator] evaluate_features_gpu is a stub (no kernels implemented)")
	return null

## Evaluate a single feature on GPU (initial support: PRIMITIVE_HILL)
func evaluate_single_feature_gpu(
	resolution: Vector2i,
	terrain_bounds: Rect2,
	param_pack: Dictionary
) -> Image:
	if not _initialized:
		push_error("[GpuFeatureEvaluator] GPU evaluator not initialized")
		return null
	if not param_pack.has("floats") or not param_pack.has("ints") or not param_pack.has("type"):
		push_error("[GpuFeatureEvaluator] Invalid parameter pack")
		return null

	var floats: PackedFloat32Array = param_pack["floats"]
	var ints: PackedInt32Array = param_pack["ints"]
	var feature_type: int = param_pack["type"]
	if not SUPPORTED_TYPES.has(feature_type):
		push_warning("[GpuFeatureEvaluator] Unsupported feature type %s" % feature_type)
		return null

	var output_format := RDTextureFormat.new()
	output_format.width = resolution.x
	output_format.height = resolution.y
	output_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	output_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

	var output_texture := _rd.texture_create(output_format, RDTextureView.new())
	if not output_texture.is_valid():
		push_error("[GpuFeatureEvaluator] Failed to create output texture")
		return null

	var float_bytes := floats.to_byte_array()
	var int_bytes := PackedByteArray()
	int_bytes.resize(ints.size() * 4)
	for i in ints.size():
		int_bytes.encode_s32(i * 4, ints[i])

	var float_buffer := _rd.storage_buffer_create(float_bytes.size(), float_bytes)
	var int_buffer := _rd.storage_buffer_create(int_bytes.size(), int_bytes)

	var params_bytes := PackedByteArray()
	params_bytes.resize(48)
	params_bytes.encode_s32(0, resolution.x)
	params_bytes.encode_s32(4, resolution.y)
	params_bytes.encode_s32(8, feature_type)
	params_bytes.encode_s32(12, floats.size())
	params_bytes.encode_s32(16, ints.size())
	params_bytes.encode_float(20, terrain_bounds.position.x)
	params_bytes.encode_float(24, terrain_bounds.position.y)
	params_bytes.encode_float(28, terrain_bounds.size.x)
	params_bytes.encode_float(32, terrain_bounds.size.y)
	# Padding
	params_bytes.encode_s32(36, 0)
	params_bytes.encode_s32(40, 0)
	params_bytes.encode_s32(44, 0)

	var params_buffer := _rd.uniform_buffer_create(params_bytes.size(), params_bytes)

	var uniforms: Array[RDUniform] = []

	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 0
	output_uniform.add_id(output_texture)
	uniforms.append(output_uniform)

	var float_uniform := RDUniform.new()
	float_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	float_uniform.binding = 1
	float_uniform.add_id(float_buffer)
	uniforms.append(float_uniform)

	var int_uniform := RDUniform.new()
	int_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	int_uniform.binding = 2
	int_uniform.add_id(int_buffer)
	uniforms.append(int_uniform)

	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 3
	params_uniform.add_id(params_buffer)
	uniforms.append(params_uniform)

	var uniform_set := _rd.uniform_set_create(uniforms, _shader, 0)

	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

	var dispatch_x := ceili(resolution.x / 8.0)
	var dispatch_y := ceili(resolution.y / 8.0)
	_rd.compute_list_dispatch(compute_list, dispatch_x, dispatch_y, 1)
	_rd.compute_list_end()

	_rd.submit()
	_rd.sync()

	var output_bytes := _rd.texture_get_data(output_texture, 0)
	var result_image := Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, output_bytes)

	_rd.free_rid(output_texture)
	_rd.free_rid(float_buffer)
	_rd.free_rid(int_buffer)
	_rd.free_rid(params_buffer)

	return result_image
