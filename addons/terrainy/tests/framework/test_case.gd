extends RefCounted

## Base class for the dependency-free Terrainy headless tests.
##
## Subclasses add `test_<name>()` methods; the runner (tests/run_tests.gd) instantiates the
## case, sets [member t] and [member tree], runs every `test_*` method and then calls
## [method after_all] to release the nodes created through [method spawn].

## Test runner providing the assertion helpers.
var t = null
## Active scene tree, used to put feature nodes into the tree so that `_ready()` runs.
var tree: SceneTree = null

var _spawned: Array[Node] = []

func before_all() -> void:
	pass

func after_all() -> void:
	# queue_free (not free) on purpose: node destruction is deferred to the end of the frame
	# so that the runner can keep instantiating cases without re-entering locked nodes.
	for node in _spawned:
		if is_instance_valid(node):
			node.queue_free()
	_spawned.clear()

## Add a node to the scene tree (runs `_ready()`), tracked for cleanup in [method after_all].
func spawn(node: Node) -> Node:
	tree.root.add_child(node)
	_spawned.append(node)
	return node

## Drive a composer's own completion logic until no chunk task is in flight.
## Test cases execute inside a single frame, so the node's _process() has to be pumped by hand
## instead of by the scene tree. Returns false when the budget ran out.
func settle(composer: TerrainComposer, budget_ms: int = 30000) -> bool:
	var deadline := Time.get_ticks_msec() + budget_ms
	while Time.get_ticks_msec() < deadline:
		composer._process(0.0)
		# is_rebuilding() also covers a collision-only refresh and the frame-budgeted queues, so
		# a settled composer has nothing left to apply.
		if not composer.is_rebuilding():
			return true
		OS.delay_usec(500)
	return false

## Build an Image/FORMAT_RF image with a constant value.
func make_flat_image(size: Vector2i, value: float) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	image.fill(Color(value, 0.0, 0.0, 1.0))
	return image

## Build an Image/FORMAT_RF image that ramps from 0 (top-left) to `height` (bottom-right).
func make_ramp_image(size: Vector2i, height: float) -> Image:
	var data := PackedFloat32Array()
	data.resize(size.x * size.y)
	for y in size.y:
		for x in size.x:
			var u := float(x) / maxf(float(size.x - 1), 1.0)
			var v := float(y) / maxf(float(size.y - 1), 1.0)
			data[y * size.x + x] = height * (u * 0.5 + v * 0.5)
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RF, data.to_byte_array())

## Build an Image/FORMAT_RGB8 image with a constant linear grey value (used for mask and
## texture layer fixtures).
func make_grey_texture_image(size: Vector2i, value: float) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
	image.fill(Color(value, value, value, 1.0))
	return image

## Evaluation contexts for a list of features, as expected by TerrainHeightmapBuilder.
func build_contexts(features: Array) -> Dictionary:
	var contexts: Dictionary = {}
	for feature in features:
		contexts[feature] = feature.prepare_evaluation_context()
	return contexts

## True when a RenderingDevice is available (GPU paths can only run in that case).
func has_rendering_device() -> bool:
	return RenderingServer.get_rendering_device() != null

## Skip reason used by every GPU dependent test.
func gpu_skip_reason() -> String:
	return "no RenderingDevice (headless/dummy renderer): GPU paths cannot be exercised"
