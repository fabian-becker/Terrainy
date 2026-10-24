@tool
extends RefCounted

## Chunk grid of a generator: `chunk_size` cells per chunk (the stage-7 rebuild unit).
##
## Chunk (i, j) covers grid samples [i * chunk_size, min((i + 1) * chunk_size, resolution)] on
## both axes, so neighbours share their border samples. Every chunk owns internal nodes: mesh,
## static body + shape (collision is always maintained), an optional navigation region and the
## scatter MultiMeshInstance3Ds.

class Chunk:
	extends RefCounted
	var key: Vector2i
	## Grid sample rect (inclusive border samples).
	var sample_rect: Rect2i
	var world_bounds: Rect2
	var root: Node3D
	var mesh_instance: MeshInstance3D
	var static_body: StaticBody3D
	var collision_shape: CollisionShape3D
	var height_shape: HeightMapShape3D = null
	var collision_trimesh: ConcavePolygonShape3D = null
	var nav_region: NavigationRegion3D = null
	var scatter: Dictionary = {}  # scatter node id -> MultiMeshInstance3D
	## scatter node id -> Array[Transform3D] (chunk-local). Kept CPU side: MultiMesh buffers
	## live in the RenderingServer (and are not stored at all by the headless dummy renderer).
	var scatter_transforms: Dictionary = {}
	var lod_level: int = 0
	var is_dirty: bool = true
	## Hashes of the composed height / hole region this chunk was last built from. Used to find
	## dirty chunks without copying the old and new images per chunk.
	var image_hash: int = 0
	var holes_hash: int = 0
	var hashes_valid: bool = false
	var edit_revision: int = 0
	var collision_revision: int = 0
	var heightmap: Image = null
	var hole_mask: Image = null
	var has_holes: bool = false
	var nav_dirty: bool = true
	var nav_revision: int = 0
	var nav_baking: bool = false
	var _collision_map_data: PackedFloat32Array

var chunks: Dictionary = {}  # Vector2i -> Chunk
var grid_count: int = 0
var chunk_cells: int = 128
var _root: Node3D = null
var _grid = null

func _init(parent: Node3D) -> void:
	_root = Node3D.new()
	_root.name = "TerrainChunks"
	parent.add_child(_root, false, Node.INTERNAL_MODE_BACK)

func get_root() -> Node3D:
	return _root

## Rebuild the chunk layout for [param grid]. Returns true when the layout changed.
func update_grid(grid, p_chunk_cells: int) -> bool:
	var cells := maxi(p_chunk_cells, 1)
	var count := int(ceil(float(grid.resolution) / float(cells)))
	var changed: bool = count != grid_count or cells != chunk_cells or _grid == null or not _grid.equals(grid)
	grid_count = count
	chunk_cells = cells
	_grid = grid
	var keep: Dictionary = {}
	for y in count:
		for x in count:
			var key := Vector2i(x, y)
			var chunk: Chunk = chunks.get(key)
			if chunk == null:
				chunk = _create(key)
				changed = true
			keep[key] = chunk
			_layout(chunk, grid)
	for key in chunks.keys():
		if not keep.has(key):
			_free(chunks[key])
	chunks = keep
	return changed

func _layout(chunk: Chunk, grid) -> void:
	var x0: int = chunk.key.x * chunk_cells
	var y0: int = chunk.key.y * chunk_cells
	var x1: int = mini(x0 + chunk_cells, grid.resolution)
	var y1: int = mini(y0 + chunk_cells, grid.resolution)
	chunk.sample_rect = Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
	chunk.world_bounds = grid.world_of_rect(chunk.sample_rect)
	# Chunk roots live in generator-local space, centered on their chunk.
	var center: Vector2 = chunk.world_bounds.get_center() - (grid.origin + Vector2(grid.size, grid.size) * 0.5)
	chunk.root.position = Vector3(center.x, 0.0, center.y)

func _create(key: Vector2i) -> Chunk:
	var chunk := Chunk.new()
	chunk.key = key
	chunk.root = Node3D.new()
	chunk.root.name = "Chunk_%d_%d" % [key.x, key.y]
	_root.add_child(chunk.root, false, Node.INTERNAL_MODE_BACK)
	chunk.mesh_instance = MeshInstance3D.new()
	chunk.mesh_instance.name = "Mesh"
	chunk.root.add_child(chunk.mesh_instance, false, Node.INTERNAL_MODE_BACK)
	chunk.static_body = StaticBody3D.new()
	chunk.static_body.name = "Collision"
	chunk.root.add_child(chunk.static_body, false, Node.INTERNAL_MODE_BACK)
	chunk.collision_shape = CollisionShape3D.new()
	chunk.collision_shape.name = "Shape"
	chunk.static_body.add_child(chunk.collision_shape, false, Node.INTERNAL_MODE_BACK)
	return chunk

func _free(chunk: Chunk) -> void:
	if chunk.root and is_instance_valid(chunk.root):
		chunk.root.queue_free()

func mark_all_dirty() -> void:
	for chunk in chunks.values():
		mark_dirty(chunk)

func mark_dirty(chunk: Chunk) -> void:
	chunk.edit_revision += 1
	chunk.is_dirty = true

## Mark every chunk whose world bounds intersect [param bounds]. Returns the marked chunks.
func mark_dirty_for_bounds(bounds: Rect2) -> Array:
	var marked: Array = []
	if bounds.size.x < 0.0 or bounds.size.y < 0.0:
		return marked
	for chunk in chunks.values():
		if chunk.world_bounds.grow(0.001).intersects(bounds, true):
			mark_dirty(chunk)
			marked.append(chunk)
	return marked

## Mark every chunk whose sample rect intersects a grid sample rect.
func mark_dirty_for_samples(rect: Rect2i) -> Array:
	var marked: Array = []
	for chunk in chunks.values():
		if chunk.sample_rect.intersects(rect):
			mark_dirty(chunk)
			marked.append(chunk)
	return marked

func dirty_chunks() -> Array:
	var out: Array = []
	for chunk in chunks.values():
		if chunk.is_dirty:
			out.append(chunk)
	return out

func has_dirty() -> bool:
	for chunk in chunks.values():
		if chunk.is_dirty:
			return true
	return false

func mark_clean(chunk: Chunk, revision: int) -> void:
	if revision == chunk.edit_revision:
		chunk.is_dirty = false

func chunk_at_world(world_xz: Vector2) -> Chunk:
	for chunk in chunks.values():
		if chunk.world_bounds.grow(0.0001).has_point(world_xz):
			return chunk
	return null
