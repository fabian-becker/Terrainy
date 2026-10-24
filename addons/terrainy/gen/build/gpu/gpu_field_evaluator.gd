@tool
extends RefCounted

## GPU twin of FieldSnapshot.evaluate() for Region-domain fields without relief
## (shaders/field_evaluator.glsl). Noise-based relief always evaluates on the CPU, as in 0.7.

const GpuKernel = preload("res://addons/terrainy/gen/build/gpu/gpu_kernel.gd")
const GpuDevice = preload("res://addons/terrainy/gen/build/gpu/gpu_device.gd")
const HMap = preload("res://addons/terrainy/gen/eval/hmap.gd")
const FieldSnapshot = preload("res://addons/terrainy/gen/eval/field_snapshot.gd")
const SHADER := "res://addons/terrainy/shaders/field_evaluator.glsl"

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

## {"h": HMap, "w": HMap} or {} when the snapshot / device cannot use the kernel.
func evaluate(snap, grid) -> Dictionary:
	if not snap.is_gpu_capable() or not is_available():
		return {}
	var rect: Rect2i = snap.pixel_rect(grid)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return {"h": HMap.new(rect), "w": HMap.new(rect)}
	var b: Basis = snap.inv_xform.basis
	var o: Vector3 = snap.inv_xform.origin
	var base: float = snap.profile_offset
	if snap.elevation_origin == TerrainTypes.ElevationOrigin.WORLD:
		base -= snap.generator_y
	else:
		base += snap.node_rel_y
	var lut_size: int = snap.profile_lut.size()
	var falloff: PackedFloat32Array = snap.falloff_lut
	if falloff.size() != lut_size:
		falloff = PackedFloat32Array()
		falloff.resize(lut_size)
		falloff.fill(1.0)
	var count := rect.size.x * rect.size.y
	var zeros := PackedFloat32Array()
	zeros.resize(count)
	var zero_bytes := zeros.to_byte_array()
	var fp := GpuKernel.floats([
		b.x.x, b.y.x, b.z.x, b.x.y, b.y.y, b.z.y, b.x.z, b.y.z, b.z.z,
		o.x, o.y, o.z, snap.xform.origin.y, snap.half.x, snap.half.y,
		grid.origin.x, grid.origin.y, grid.cell, snap.profile_height, base, snap.strength,
	])
	var ip := GpuKernel.ints([rect.position.x, rect.position.y, rect.size.x, rect.size.y,
		snap.shape, 1 if snap.has_falloff else 0, lut_size])
	var out: Array = _kernel.run([zero_bytes, zero_bytes, snap.profile_lut.to_byte_array(),
		falloff.to_byte_array(), ip, fp],
		Vector3i(int(ceil(rect.size.x / 8.0)), int(ceil(rect.size.y / 8.0)), 1), PackedInt32Array([0, 1]))
	if out.size() < 2:
		return {}
	var h := HMap.new(Rect2i())
	h.rect = rect
	h.data = (out[0] as PackedByteArray).to_float32_array()
	var w := HMap.new(Rect2i())
	w.rect = rect
	w.data = (out[1] as PackedByteArray).to_float32_array()
	return {"h": h, "w": w}
