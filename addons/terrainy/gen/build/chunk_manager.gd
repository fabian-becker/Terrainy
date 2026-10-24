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
	## CPU-side collision data of this chunk (heights for a heightfield chunk, triangle soup for a
	## holed one). Kept so the collision shape can be dropped outside the physics range and
	## restored when the chunk comes back in range, without another worker round trip.
	var collision_heights: PackedFloat32Array
	var collision_faces: PackedVector3Array
	## Streaming residency (design D8.1). The node skeleton and all bookkeeping always stay; only the
	## resources a state does not need are released, so a chunk that comes back is a rebuild from the
	## current composition, never a recompose.
	enum Residency { READY, QUEUED, EVICTED }
	var residency: int = Residency.READY
	## False while the chunk is streamed out: its mesh, collision shape, navigation mesh and
	## scatter instances have been released because it sits outside the generator's view distance.
	var streamed_in: bool:
		get:
			return residency != Residency.EVICTED
	## True while a rebuild for this chunk is queued in the streaming scheduler.
	var build_queued: bool = false
	## Bitmask of edges that need a skirt ([method LodController.edges_for]). Kept on the chunk so the
	## controller can tell when a neighbour's level change made this chunk's mesh stale even though
	## its own level did not move.
	var skirt_edges: int = 0

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

## Release everything the chunk owns in the renderer and the physics server: mesh, collision
## shape, navigation mesh and scatter instances. The node skeleton and the heightmap hash stay, so
## [method stream_in] can rebuild the chunk from the current composition without recomposing.
func stream_out(chunk: Chunk) -> void:
	if not chunk.streamed_in:
		return
	chunk.residency = Chunk.Residency.EVICTED
	chunk.is_dirty = false
	chunk.build_queued = false
	if chunk.mesh_instance:
		chunk.mesh_instance.mesh = null
		chunk.mesh_instance.visible = false
	if chunk.collision_shape:
		# Dropping the shape returns its RID (HeightMapShape3D data included) to the physics server.
		chunk.collision_shape.shape = null
	chunk.height_shape = null
	chunk.collision_trimesh = null
	chunk.heightmap = null
	chunk.hole_mask = null
	chunk.has_holes = false
	chunk.nav_dirty = true
	chunk.nav_baking = false
	if chunk.nav_region and is_instance_valid(chunk.nav_region):
		chunk.nav_region.enabled = false
		chunk.nav_region.navigation_mesh = null
	for node in chunk.scatter.values():
		if node and is_instance_valid(node):
			node.queue_free()
	chunk.scatter.clear()
	chunk.scatter_transforms.clear()

## Bring a streamed-out chunk back: visible again, dirty so the next build refills it.
func stream_in(chunk: Chunk) -> void:
	if chunk.streamed_in:
		return
	chunk.residency = Chunk.Residency.READY
	if chunk.mesh_instance:
		chunk.mesh_instance.visible = true
	if chunk.nav_region and is_instance_valid(chunk.nav_region):
		chunk.nav_region.enabled = true
	chunk.is_dirty = true

## Chunks that are currently not drawn (streamed out).
func streamed_out_chunks() -> Array:
	var out: Array = []
	for chunk in chunks.values():
		if not chunk.streamed_in:
			out.append(chunk)
	return out

## Chunks whose mesh and collision shape are live.
func resident_chunks() -> Array:
	var out: Array = []
	for chunk in chunks.values():
		if chunk.streamed_in:
			out.append(chunk)
	return out

## The up-to-four chunks sharing an edge with [param key]. Missing neighbours are simply absent:
## the terrain border has no neighbour to seam against.
func neighbours_of(key: Vector2i) -> Array:
	var out: Array = []
	for offset in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		var chunk = chunks.get(key + offset)
		if chunk != null:
			out.append(chunk)
	return out

## Move [param chunk] into [param state], releasing or restoring resources as that state requires.
## Never frees or creates nodes: physics-server and renderer churn per camera move is exactly what
## this avoids (design D8.1).
func set_residency(chunk: Chunk, state: int) -> void:
	if chunk == null or chunk.residency == state:
		return
	match state:
		Chunk.Residency.EVICTED:
			stream_out(chunk)
		Chunk.Residency.QUEUED:
			chunk.residency = Chunk.Residency.QUEUED
			chunk.build_queued = true
		_:
			stream_in(chunk)
			chunk.residency = Chunk.Residency.READY
			chunk.build_queued = false

## Evict every chunk farther than [param view_distance] from [param camera_xz] and restore the ones
## that came back inside it. Returns the restored chunks - the caller queues them, because a
## restored chunk still has to be rebuilt from its heightmap.
##
## [param hysteresis] is the fraction of the view distance a chunk has to come back inside before it
## is restored, which is what stops a chunk sitting exactly on the boundary from being released and
## rebuilt every frame (design D8.1). `view_distance <= 0` keeps every chunk resident, which is the
## default and the pre-streaming behaviour.
func evict_beyond(camera_xz: Vector2, view_distance: float, hysteresis: float = 0.15) -> Array:
	var restored: Array = []
	if view_distance <= 0.0:
		return restored
	var margin := clampf(hysteresis, 0.0, 0.45)
	var reenter := view_distance * (1.0 - margin)
	for chunk in chunks.values():
		var d := _distance_to_bounds(chunk.world_bounds, camera_xz)
		if chunk.streamed_in:
			if d > view_distance:
				stream_out(chunk)
			continue
		if d <= reenter:
			stream_in(chunk)
			restored.append(chunk)
	return restored

static func _distance_to_bounds(bounds: Rect2, point: Vector2) -> float:
	var nearest := Vector2(
		clampf(point.x, bounds.position.x, bounds.end.x),
		clampf(point.y, bounds.position.y, bounds.end.y))
	return point.distance_to(nearest)

func chunk_at_world(world_xz: Vector2) -> Chunk:
	for chunk in chunks.values():
		if chunk.world_bounds.grow(0.0001).has_point(world_xz):
			return chunk
	return null
