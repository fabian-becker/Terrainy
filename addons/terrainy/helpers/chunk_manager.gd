class_name ChunkManager
extends RefCounted

## Manages terrain chunk lifecycle, bounds, and dirty tracking

class Chunk:
	var position: Vector2i
	var world_bounds: Rect2
	var root: Node3D
	var mesh_instance: MeshInstance3D
	var static_body: StaticBody3D
	var collision_shape: CollisionShape3D
	var height_shape: HeightMapShape3D = null
	var _collision_map_data: PackedFloat32Array
	var lod_level: int = 0
	var is_dirty: bool = true
	var heightmap: Image = null
	var hole_mask: Image = null

var _chunks: Dictionary = {}  # Vector2i -> Chunk
var _chunk_grid_size: Vector2i = Vector2i.ZERO
var _chunk_root: Node3D = null
var _terrain_size: Vector2 = Vector2(100, 100)
var _chunk_size: int = 512
var _terrain_origin_world: Vector2 = Vector2.ZERO
var _dirty_count: int = 0  # O(1) dirty chunk tracking

func _init(parent: Node3D) -> void:
	_chunk_root = Node3D.new()
	_chunk_root.name = "TerrainChunks"
	parent.add_child(_chunk_root, false, Node.INTERNAL_MODE_BACK)

func update_grid(terrain_size: Vector2, chunk_size: int, terrain_origin_world: Vector2) -> bool:
	_terrain_size = terrain_size
	_chunk_size = chunk_size
	_terrain_origin_world = terrain_origin_world

	if chunk_size <= 0:
		return false

	var new_grid = Vector2i(
		ceili(terrain_size.x / float(chunk_size)),
		ceili(terrain_size.y / float(chunk_size))
	)
	var grid_changed = new_grid != _chunk_grid_size
	_chunk_grid_size = new_grid

	var new_chunks: Dictionary = {}
	for y in range(_chunk_grid_size.y):
		for x in range(_chunk_grid_size.x):
			var chunk_pos = Vector2i(x, y)
			var chunk: Chunk = _chunks.get(chunk_pos)
			if not chunk:
				chunk = _create_chunk(chunk_pos)
				grid_changed = true
			else:
				_update_chunk_bounds(chunk)
				if _chunk_root and chunk.root and not chunk.root.get_parent():
					_chunk_root.add_child(chunk.root, false, Node.INTERNAL_MODE_BACK)
			new_chunks[chunk_pos] = chunk

	# Remove obsolete chunks
	for key in _chunks.keys():
		if not new_chunks.has(key):
			_free_chunk(_chunks[key])
			grid_changed = true

	_chunks = new_chunks
	return grid_changed

func mark_all_dirty() -> void:
	_dirty_count = _chunks.size()
	for chunk in _chunks.values():
		chunk.is_dirty = true

func mark_dirty_for_bounds(bounds: Rect2) -> void:
	for chunk in _chunks.values():
		if chunk.world_bounds.intersects(bounds) and not chunk.is_dirty:
			chunk.is_dirty = true
			_dirty_count += 1

func get_chunks() -> Dictionary:
	return _chunks

func has_dirty_chunks() -> bool:
	return _dirty_count > 0

## Mark a single chunk as dirty (O(1), no-op if already dirty)
func mark_chunk_dirty(chunk) -> void:
	if not chunk.is_dirty:
		chunk.is_dirty = true
		_dirty_count += 1

## Mark a single chunk as clean (O(1), no-op if already clean)
func mark_chunk_clean(chunk) -> void:
	if chunk.is_dirty:
		chunk.is_dirty = false
		_dirty_count -= 1

func get_dirty_chunks() -> Array:
	var result: Array = []
	for chunk in _chunks.values():
		if chunk.is_dirty:
			result.append(chunk)
	_dirty_count = result.size()  # Recalibrate count
	return result

func get_chunk_grid_size() -> Vector2i:
	return _chunk_grid_size

func _create_chunk(chunk_pos: Vector2i) -> Chunk:
	var chunk = Chunk.new()
	chunk.position = chunk_pos
	chunk.root = Node3D.new()
	chunk.root.name = "Chunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	if _chunk_root:
		_chunk_root.add_child(chunk.root, false, Node.INTERNAL_MODE_BACK)

	chunk.mesh_instance = MeshInstance3D.new()
	chunk.mesh_instance.name = "Mesh"
	chunk.mesh_instance.visible = true
	chunk.mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	chunk.root.add_child(chunk.mesh_instance, false, Node.INTERNAL_MODE_BACK)

	chunk.static_body = StaticBody3D.new()
	chunk.static_body.name = "CollisionBody"
	chunk.root.add_child(chunk.static_body, false, Node.INTERNAL_MODE_BACK)

	chunk.collision_shape = CollisionShape3D.new()
	chunk.collision_shape.name = "CollisionShape"
	chunk.static_body.add_child(chunk.collision_shape, false, Node.INTERNAL_MODE_BACK)

	_update_chunk_bounds(chunk)
	return chunk

func _free_chunk(chunk: Chunk) -> void:
	if chunk and chunk.root and is_instance_valid(chunk.root):
		chunk.root.queue_free()

func _update_chunk_bounds(chunk: Chunk) -> void:
	var grid_x = max(1, _chunk_grid_size.x)
	var grid_y = max(1, _chunk_grid_size.y)
	# Distribute terrain extents evenly across the chunk grid to avoid a tiny remainder chunk.
	var step_x = _terrain_size.x / float(grid_x)
	var step_y = _terrain_size.y / float(grid_y)
	var start_x = chunk.position.x * step_x
	var start_y = chunk.position.y * step_y
	var end_x = (chunk.position.x + 1) * step_x
	var end_y = (chunk.position.y + 1) * step_y
	var chunk_world_pos = Vector2(
		_terrain_origin_world.x + start_x,
		_terrain_origin_world.y + start_y
	)
	var size_x = max(0.001, end_x - start_x)
	var size_y = max(0.001, end_y - start_y)
	chunk.world_bounds = Rect2(chunk_world_pos, Vector2(size_x, size_y))

	# Position chunk root at center in local space (relative to terrain composer)
	# Local position is independent of absolute world position since both bounds and
	# composer global_position shift together.
	var chunk_center_local = Vector3(
		start_x + size_x * 0.5 - _terrain_size.x * 0.5,
		0,
		start_y + size_y * 0.5 - _terrain_size.y * 0.5
	)
	chunk.root.position = chunk_center_local
