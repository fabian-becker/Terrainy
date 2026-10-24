extends RefCounted

## Base class for the dependency-free Terrainy 2 headless tests (ported harness).
##
## Subclasses add `test_<name>()` methods; the runner (tests/run_tests.gd) instantiates the
## case, sets [member t] and [member tree], runs every `test_*` method and then calls
## [method after_all] to release the nodes created through [method spawn].

const HMap = preload("res://addons/terrainy/gen/eval/hmap.gd")
const BrushStamp = preload("res://addons/terrainy/gen/paint/brush_stamp.gd")

## Test runner providing the assertion helpers.
var t = null
## Active scene tree, used to put nodes into the tree so that `_ready()` runs.
var tree: SceneTree = null

var _spawned: Array[Node] = []

func before_all() -> void:
	pass

func after_all() -> void:
	for node in _spawned:
		if is_instance_valid(node):
			node.queue_free()
	_spawned.clear()

## Add a node to the scene tree (runs `_ready()`), tracked for cleanup in [method after_all].
func spawn(node: Node) -> Node:
	tree.root.add_child(node)
	_spawned.append(node)
	return node

## A generator with small, fast defaults (64 cells over 64 m = 1 m cells, 32 cell chunks,
## navigation off). [param configure] runs before it enters the tree.
func make_generator(resolution: int = 64, size: float = 64.0, configure: Callable = Callable()) -> TerrainGenerator:
	var gen := TerrainGenerator.new()
	gen.name = "Gen"
	# Fixed cell count: these tests set resolution and size independently on purpose, so they must not
	# get the scale-invariant "keep the meters per cell" derivation from resizing.
	gen.preserve_cell_size = false
	gen.terrain_resolution = resolution
	gen.terrain_size = size
	gen.chunk_size = 32
	gen.navigation_enabled = false
	gen.enable_lod = false
	gen.use_gpu_composition = false
	gen.use_gpu_feature_evaluation = false
	gen.use_gpu_paint = false
	gen.paint_layer_grid = 128
	if configure.is_valid():
		configure.call(gen)
	return gen

## Spawn [param gen] (after adding [param children]) and build it synchronously.
func build(gen: TerrainGenerator, children: Array = []) -> TerrainGenerator:
	for child in children:
		gen.add_child(child)
	if not gen.is_inside_tree():
		spawn(gen)
	gen.rebuild_now()
	return gen

## Region field helper.
func make_field(height: float = 10.0, size: Vector2 = Vector2(32, 32), pos: Vector3 = Vector3.ZERO) -> TerrainFieldNode:
	var f := TerrainFieldNode.new()
	f.profile_height = height
	f.region_size = size
	f.position = pos
	return f

## Drive a generator until no rebuild work is pending (cases run inside one frame, so the
## node's _process() has to be pumped by hand). Returns false when the budget ran out.
func settle(gen: TerrainGenerator, budget_ms: int = 30000) -> bool:
	var deadline := Time.get_ticks_msec() + budget_ms
	while Time.get_ticks_msec() < deadline:
		gen._process(0.0)
		if not gen.is_rebuilding():
			return true
		OS.delay_usec(500)
	return false

## Generator-local composed height at a world XZ.
func h_at(gen: TerrainGenerator, x: float, z: float) -> float:
	return gen.get_height_at(Vector3(x, 0, z)) - gen.global_position.y

## A brush stamp. Flat falloff by default (full strength up to the rim) so tests can assert
## exact values; pass flat = false for the smoothstep brush falloff.
func stamp(op: int, pos: Vector3, radius: float, strength: float, value: float = 0.0, flat: bool = true) -> RefCounted:
	var s := BrushStamp.new(op, pos, radius, strength)
	s.value = value
	if flat:
		s.falloff_lut = PackedFloat32Array([1.0, 1.0])
	return s

## Build an Image/FORMAT_RF image with a constant value.
func make_flat_image(size: Vector2i, value: float) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	image.fill(Color(value, 0.0, 0.0, 1.0))
	return image

func make_ramp_image(size: Vector2i, height: float) -> Image:
	var data := PackedFloat32Array()
	data.resize(size.x * size.y)
	for y in size.y:
		for x in size.x:
			var u := float(x) / maxf(float(size.x - 1), 1.0)
			var v := float(y) / maxf(float(size.y - 1), 1.0)
			data[y * size.x + x] = height * (u * 0.5 + v * 0.5)
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RF, data.to_byte_array())

## True when a RenderingDevice is available (GPU paths can only run in that case).
func has_rendering_device() -> bool:
	return RenderingServer.get_rendering_device() != null

func gpu_skip_reason() -> String:
	return "no RenderingDevice (headless/dummy renderer): GPU paths cannot be exercised"
