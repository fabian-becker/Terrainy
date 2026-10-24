@tool
class_name TerrainyAPI
extends Object

## Static integration API of Terrainy 2 (water systems, props, AI, gameplay).
##
## Every call takes the terrain explicitly, so several generators can coexist. Generators
## register themselves on _ready and unregister on _exit_tree. All queries read the last
## applied composition; they are main-thread calls and never trigger a rebuild.
## See docs/terrainy2/api.md.

## Signal hub: region_changed(terrain, aabb), terrain_added(terrain), terrain_removed(terrain).
static var signals: TerrainySignalHub = TerrainySignalHub.new()

static var _terrains: Array = []

## Register a generator (done automatically by TerrainGenerator._ready()).
static func register(terrain: TerrainGenerator) -> void:
	if terrain == null or _terrains.has(terrain):
		return
	_terrains.append(terrain)
	signals.terrain_added.emit(terrain)

static func unregister(terrain: TerrainGenerator) -> void:
	if not _terrains.has(terrain):
		return
	_terrains.erase(terrain)
	signals.terrain_removed.emit(terrain)

## Registered generators (freed ones are dropped).
static func get_terrains() -> Array[TerrainGenerator]:
	var out: Array[TerrainGenerator] = []
	for t in _terrains.duplicate():
		if is_instance_valid(t):
			out.append(t)
		else:
			_terrains.erase(t)
	return out

## First registered generator whose terrain rect contains [param world_pos] (XZ), or null.
static func find_terrain_at(world_pos: Vector3) -> TerrainGenerator:
	for t in get_terrains():
		if t.get_terrain_world_rect().grow(0.0001).has_point(Vector2(world_pos.x, world_pos.z)):
			return t
	return null

static func _valid(terrain: TerrainGenerator) -> bool:
	return terrain != null and is_instance_valid(terrain)

## World height (bilinear, base_height included). Outside the terrain: generator y + base_height.
static func get_height_at(terrain: TerrainGenerator, world_pos: Vector3) -> float:
	if not _valid(terrain):
		return NAN
	return terrain.get_height_at(world_pos)

## Surface normal from central differences of the terrain height, step [param eps] meters.
static func get_normal_at(terrain: TerrainGenerator, world_pos: Vector3, eps: float = 1.0) -> Vector3:
	if not _valid(terrain):
		return Vector3.UP
	return terrain.get_normal_at(world_pos, eps)

## True when [param world_pos] (XZ) lies in a hole.
static func get_hole_at(terrain: TerrainGenerator, world_pos: Vector3) -> bool:
	if not _valid(terrain):
		return false
	return terrain.get_hole_at(world_pos)

## Value of a paint layer at a world position (delta meters / pinned height / 0..1 weight).
static func get_paint_at(terrain: TerrainGenerator, layer: TerrainPaintLayer, world_pos: Vector3) -> float:
	if not _valid(terrain) or layer == null or layer.get_parent() != terrain:
		return 0.0
	return layer.sample_world(Vector2(world_pos.x, world_pos.z))

## Final material blend weights {palette index: weight} (CPU mirror of the auto material,
## without its cosmetic blend noise).
static func get_texture_blend_at(terrain: TerrainGenerator, world_pos: Vector3) -> Dictionary:
	if not _valid(terrain):
		return {}
	return terrain.get_texture_blend_at(world_pos)

## Fields (and heightmap nodes) acting at a world position (weight > 0 after masks).
static func get_fields_at(terrain: TerrainGenerator, world_pos: Vector3) -> Array[TerrainFieldNode]:
	if not _valid(terrain):
		return [] as Array[TerrainFieldNode]
	return terrain.get_fields_at(world_pos)

## Sample world heights over [param rect] (world XZ, inclusive corners) at [param resolution].
static func sample_region(terrain: TerrainGenerator, rect: Rect2, resolution: Vector2i) -> Heightfield2D:
	var field := Heightfield2D.new()
	field.rect = rect
	field.resolution = Vector2i(maxi(resolution.x, 1), maxi(resolution.y, 1))
	if not _valid(terrain):
		return field
	var n := field.resolution.x * field.resolution.y
	field.heights.resize(n)
	var has_holes: bool = terrain.get_hole_map() != null
	if has_holes:
		field.holes.resize(n)
	var step := rect.size / Vector2(maxi(field.resolution.x - 1, 1), maxi(field.resolution.y - 1, 1))
	for y in field.resolution.y:
		for x in field.resolution.x:
			var p := Vector3(rect.position.x + x * step.x, 0.0, rect.position.y + y * step.y)
			field.heights[y * field.resolution.x + x] = terrain.get_height_at(p)
			if has_holes:
				field.holes[y * field.resolution.x + x] = 1 if terrain.get_hole_at(p) else 0
	return field

## Awaitable variant of sample_region(): waits until the terrain settled first.
static func sample_region_async(terrain: TerrainGenerator, rect: Rect2, resolution: Vector2i) -> Heightfield2D:
	await wait_for_settle(terrain)
	return sample_region(terrain, rect, resolution)

## World AABB covering the painted content of [param layers] (all paint layers when empty).
static func get_painted_region_aabb(terrain: TerrainGenerator, layers: Array = []) -> AABB:
	if not _valid(terrain):
		return AABB()
	if layers.is_empty():
		layers = terrain.get_paint_layers()
	var rect := Rect2()
	var first := true
	for layer in layers:
		if layer == null or not layer.has_data():
			continue
		var r: Rect2 = layer.get_content_world_rect()
		rect = r if first else rect.merge(r)
		first = false
	if first:
		return AABB()
	# Exact over the built grid; the 9x9 probe is only a fallback for an unbuilt terrain, where
	# a narrow feature between samples could otherwise fall outside the returned bounds.
	var mm: Vector2 = terrain.height_range_in_rect(rect)
	if terrain.get_final_map() == null:
		mm = sample_region(terrain, rect, Vector2i(9, 9)).min_max()
	return AABB(Vector3(rect.position.x, mm.x, rect.position.y),
		Vector3(rect.size.x, maxf(mm.y - mm.x, 0.001), rect.size.y))

## True while a rebuild is queued, composing or being applied.
static func is_rebuilding(terrain: TerrainGenerator) -> bool:
	return _valid(terrain) and terrain.is_rebuilding()

## Await until the terrain settled (no rebuild in flight). Returns OK, or ERR_INVALID_PARAMETER
## for an invalid terrain / ERR_TIMEOUT after [param timeout_sec].
static func wait_for_settle(terrain: TerrainGenerator, timeout_sec: float = 60.0) -> Error:
	if not _valid(terrain) or not terrain.is_inside_tree():
		return ERR_INVALID_PARAMETER
	var tree := terrain.get_tree()
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while _valid(terrain) and terrain.is_rebuilding():
		if Time.get_ticks_msec() > deadline:
			return ERR_TIMEOUT
		await tree.process_frame
	return OK if _valid(terrain) else ERR_INVALID_PARAMETER

## Diagnostics snapshot: rebuild id/report, phase timings, counters, chunk and GPU state.
static func get_diagnostics(terrain: TerrainGenerator) -> Dictionary:
	if not _valid(terrain):
		return {}
	return terrain.get_diagnostics()
