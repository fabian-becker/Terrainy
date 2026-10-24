@tool
extends RefCounted

## Minimal compute-kernel runner on the shared Terrainy 2 RenderingDevice.
##
## Every binding is a std430 storage buffer (set 0, binding = index). [method run] uploads the
## inputs, dispatches once and reads back the requested buffers. Main thread only: the shared
## device returns null on worker threads, which makes every caller fall back to the CPU twin.

const GpuDevice = preload("res://addons/terrainy/gen/build/gpu/gpu_device.gd")

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipeline: RID = RID()
var _ok: bool = false

func _init(shader_path: String) -> void:
	_rd = GpuDevice.get_device()
	if _rd == null:
		return
	var file = load(shader_path)
	if not (file is RDShaderFile):
		push_warning("[terrainy] compute shader missing or not imported: %s" % shader_path)
		return
	var spirv: RDShaderSPIRV = file.get_spirv()
	if spirv == null or not spirv.compile_error_compute.is_empty():
		push_warning("[terrainy] compute shader failed to compile: %s %s" % [shader_path, spirv.compile_error_compute if spirv else ""])
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	_ok = _pipeline.is_valid()

func is_ok() -> bool:
	return _ok

## Run the kernel. [param buffers]: one PackedByteArray per binding (never empty: pass at least
## 4 bytes). Returns the bytes of the bindings listed in [param read_back], in that order.
func run(buffers: Array, groups: Vector3i, read_back: PackedInt32Array) -> Array:
	var out: Array = []
	if not _ok:
		return out
	var rids: Array[RID] = []
	var uniforms: Array[RDUniform] = []
	for i in buffers.size():
		var bytes: PackedByteArray = buffers[i]
		if bytes.is_empty():
			bytes = PackedByteArray([0, 0, 0, 0])
		var rid := _rd.storage_buffer_create(bytes.size(), bytes)
		rids.append(rid)
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = i
		u.add_id(rid)
		uniforms.append(u)
	var uniform_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_dispatch(list, maxi(groups.x, 1), maxi(groups.y, 1), maxi(groups.z, 1))
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	for index in read_back:
		out.append(_rd.buffer_get_data(rids[index]))
	_rd.free_rid(uniform_set)
	for rid in rids:
		_rd.free_rid(rid)
	return out

func cleanup() -> void:
	if _rd == null:
		return
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_ok = false

static func ints(values: Array) -> PackedByteArray:
	return PackedInt32Array(values).to_byte_array()

static func floats(values: Array) -> PackedByteArray:
	return PackedFloat32Array(values).to_byte_array()
