@tool
extends RefCounted

## GPU twin of Composer.blend() (shaders/blend.glsl). Used when composition runs on the main
## thread (use_multithreading off / rebuild_now) and use_gpu_composition is on; the threaded
## path composes on the CPU in a worker because local RenderingDevices are main-thread only.

const GpuKernel = preload("res://addons/terrainy/gen/build/gpu/gpu_kernel.gd")
const GpuDevice = preload("res://addons/terrainy/gen/build/gpu/gpu_device.gd")
const SHADER := "res://addons/terrainy/shaders/blend.glsl"

static var _kernel = null
static var _failed: bool = false

static func is_available() -> bool:
	if _failed:
		return false
	if _kernel != null:
		return true
	if OS.get_thread_caller_id() != OS.get_main_thread_id() or not GpuDevice.is_available():
		return false
	_kernel = GpuKernel.new(SHADER)
	if not _kernel.is_ok():
		_kernel = null
		_failed = true
		return false
	return true

## Blend src into target (both HMaps) on the GPU. Returns false when the GPU path is not
## available (the caller then uses the CPU twin).
static func blend(target, src, weights: PackedFloat32Array, mode: int, scale: float) -> bool:
	if not is_available():
		return false
	var rect: Rect2i = target.rect.intersection(src.rect)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return true
	var ip := GpuKernel.ints([target.rect.position.x, target.rect.position.y, target.rect.size.x,
		src.rect.position.x, src.rect.position.y, src.rect.size.x,
		rect.position.x, rect.position.y, rect.size.x, rect.size.y, mode])
	var out: Array = _kernel.run([
		target.data.to_byte_array(), src.data.to_byte_array(), weights.to_byte_array(),
		ip, GpuKernel.floats([scale]),
	], Vector3i(int(ceil(rect.size.x / 8.0)), int(ceil(rect.size.y / 8.0)), 1), PackedInt32Array([0]))
	if out.is_empty():
		return false
	target.data = (out[0] as PackedByteArray).to_float32_array()
	return true
