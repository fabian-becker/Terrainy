@tool
extends RefCounted

## GPU paint path: `paint_apply` (stamp lists -> layer rect) and `paint_control` (TEXTURE paint
## -> weight planes). Inputs are gathered exactly like the CPU twin (PaintStamper), so both
## paths consume identical buffers; only the stroke rect is read back (never per frame of the
## whole layer).

const GpuKernel = preload("res://addons/terrainy/gen/build/gpu/gpu_kernel.gd")
const GpuDevice = preload("res://addons/terrainy/gen/build/gpu/gpu_device.gd")
const PaintStamper = preload("res://addons/terrainy/gen/paint/paint_stamper.gd")
const APPLY_SHADER := "res://addons/terrainy/shaders/paint_apply.glsl"
const CONTROL_SHADER := "res://addons/terrainy/shaders/paint_control.glsl"

static var _apply = null
static var _control = null
static var _failed: bool = false

static func is_available() -> bool:
	if _failed:
		return false
	if _apply != null:
		return true
	if OS.get_thread_caller_id() != OS.get_main_thread_id() or not GpuDevice.is_available():
		return false
	_apply = GpuKernel.new(APPLY_SHADER)
	_control = GpuKernel.new(CONTROL_SHADER)
	if not _apply.is_ok() or not _control.is_ok():
		_apply = null
		_control = null
		_failed = true
		return false
	return true

## Run the stamp kernel over prepared buffers (same signature as PaintStamper.apply_buffers).
## Returns false when the GPU path is unavailable.
static func apply_buffers(kind: int, rect: Rect2i, world: Rect2, grid: int, opacity: float,
		value: PackedFloat32Array, coverage: PackedFloat32Array, surface: PackedFloat32Array,
		avg: PackedFloat32Array, noise: PackedFloat32Array, stamps: PackedFloat32Array, luts: PackedFloat32Array) -> bool:
	if not is_available():
		return false
	var n := rect.size.x * rect.size.y
	var cov := coverage if coverage.size() == n else _zeros(n)
	var ip := GpuKernel.ints([kind, rect.position.x, rect.position.y, rect.size.x, rect.size.y, grid,
		stamps.size() / PaintStamper.STAMP_STRIDE, PaintStamper.LUT_SIZE])
	var fp := GpuKernel.floats([world.position.x, world.position.y, world.size.x, opacity])
	var out: Array = _apply.run([value.to_byte_array(), cov.to_byte_array(), surface.to_byte_array(),
		avg.to_byte_array(), noise.to_byte_array(), stamps.to_byte_array(), luts.to_byte_array(), ip, fp],
		Vector3i(int(ceil(rect.size.x / 8.0)), int(ceil(rect.size.y / 8.0)), 1), PackedInt32Array([0, 1]))
	if out.size() < 2:
		return false
	var v := (out[0] as PackedByteArray).to_float32_array()
	var c := (out[1] as PackedByteArray).to_float32_array()
	for i in n:
		value[i] = v[i]
	if coverage.size() == n:
		for i in n:
			coverage[i] = c[i]
	return true

## GPU version of PaintStamper.apply_to_layer(). Returns an empty rect when unavailable.
func apply_to_layer(layer, stamps: Array, world: Rect2, height_at: Callable) -> Rect2i:
	if not is_available():
		return Rect2i()
	var image: Image = layer.get_data()
	var grid: int = image.get_width()
	var rect := PaintStamper.stamps_rect(stamps, world, grid)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return Rect2i()
	var bufs := PaintStamper.read_buffers(image, layer.kind, rect)
	var avg_r := 2.0
	for s in stamps:
		avg_r = maxf(avg_r, s.radius * 0.2)
	var inputs := PaintStamper.gather_inputs(rect, world, grid, stamps, height_at, avg_r)
	var packed := PaintStamper.pack(stamps)
	var cov: PackedFloat32Array = bufs["coverage"]
	if cov.is_empty():
		cov = _zeros((bufs["value"] as PackedFloat32Array).size())
	if not apply_buffers(layer.kind, rect, world, grid, layer.opacity, bufs["value"], cov,
			inputs["surface"], inputs["avg"], inputs["noise"], packed["stamps"], packed["luts"]):
		return Rect2i()
	PaintStamper.write_buffers(image, layer.kind, rect, bufs["value"], cov)
	layer.content_rect = rect if not layer.has_data() else layer.content_rect.merge(rect)
	return rect

## Fold one TEXTURE layer into claim buffers (layer-major). Returns false when unavailable.
static func combine_claims(claims: Array, paint: PackedFloat32Array, target_layer: int) -> bool:
	if not is_available() or claims.is_empty():
		return false
	var count := paint.size()
	var packed := PackedFloat32Array()
	for c in claims:
		packed.append_array(c)
	var out: Array = _control.run([packed.to_byte_array(), paint.to_byte_array(),
		GpuKernel.ints([count, claims.size(), target_layer])],
		Vector3i(int(ceil(count / 64.0)), 1, 1), PackedInt32Array([0]))
	if out.is_empty():
		return false
	var result := (out[0] as PackedByteArray).to_float32_array()
	for j in claims.size():
		var dst: PackedFloat32Array = claims[j]
		var part := result.slice(j * count, (j + 1) * count)
		for i in count:
			dst[i] = part[i]
	return true

static func _zeros(n: int) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(n)
	return z
