extends RefCounted

## Stage 7 application: turns a finished composition into chunk meshes, collision, navigation
## regions, scatter placement and LOD, spread across frames by `chunk_apply_budget_ms`.
##
## Extracted from TerrainGenerator. It owns the worker pipeline and the per-chunk work state;
## the host owns the composition (maps, holes), the material and the scene nodes. Every apply
## step checks the frame budget between results, never inside one, which is what makes the
## "generation never blocks the frame" contract hold.
##
## The host is duck-typed (a TerrainGenerator) and must provide:
##
##   properties: chunk_resolution, chunk_apply_budget_ms, use_multithreading, max_worker_threads,
##               collision_quality, collision_triangle_budget, collision_layer, collision_mask,
##               navigation_enabled, navigation_mesh_template, navigation_triangle_budget,
##               navigation_debounce_ms, cast_shadows, enable_lod, lod_distances, lod_auto,
##               lod_pixel_error, lod_levels
##   methods:    get_grid(), get_final_map(), get_final_image(), get_hole_map(),
##               get_navigation_hole_map(), get_chunk_manager(), final_min(), final_max(),
##               current_material(), find_camera(), on_chunks_applied()
##
## It emits:
##
##   region_updated(aabb)            the host re-emits its terrain_region_updated and the API
##   navigation_baked(mesh, key)     the host re-emits navigation_mesh_baked
##   all_applied                     no mesh work is pending; the host refreshes the material

const ChunkPipeline = preload("res://addons/terrainy/gen/build/chunk_pipeline.gd")
const CollisionBuilder = preload("res://addons/terrainy/gen/build/collision_builder.gd")
const MeshGen = preload("res://addons/terrainy/gen/build/mesh_generator.gd")
const NavigationBuilder = preload("res://addons/terrainy/gen/build/navigation_builder.gd")
const ScatterBuilder = preload("res://addons/terrainy/gen/build/scatter_builder.gd")

signal region_updated(aabb: AABB)
signal navigation_baked(mesh: NavigationMesh, key: Vector2i)
signal all_applied

var host = null
var pipeline = null
var diagnostics = null
var collision_refresh_pending: bool = false
var scatter_dirty_all: bool = false
var nav_due_msec: int = 0
var nav_in_flight: int = 0
var scatter_queue: Array = []

var _lod_camera: Vector3 = Vector3.INF

func _init(p_host) -> void:
	host = p_host
	pipeline = ChunkPipeline.new()

# --- Frame step -----------------------------------------------------------------------------

## One main-thread step: apply whatever finished, then top up scatter, LOD and navigation.
func process(now_msec: int) -> void:
	pipeline.poll()
	if pipeline.has_mesh_results():
		apply_mesh_results(true)
	if pipeline.has_collision_results():
		apply_collision_results(true)
	if collision_refresh_pending and not has_mesh_work():
		collision_refresh_pending = false
		refresh_all_collision()
	if not scatter_queue.is_empty() or scatter_dirty_all:
		process_scatter_queue()
	if host.enable_lod and host.get_final_map() != null and not has_mesh_work():
		update_lod()
	if host.navigation_enabled and nav_due_msec > 0 and now_msec >= nav_due_msec and not host.is_rebuilding_meshes():
		bake_navigation_step()

func is_busy() -> bool:
	return has_mesh_work() or collision_refresh_pending or not scatter_queue.is_empty() or scatter_dirty_all

func has_mesh_work() -> bool:
	return pipeline != null and pipeline.has_pending_work()

## True while navigation regions are waiting for (or running) a bake.
func is_baking_navigation() -> bool:
	return nav_in_flight > 0 or nav_due_msec > 0

## Block until every queued chunk mesh / collision result is built and applied.
func drain() -> void:
	while pipeline.has_pending_work():
		pipeline.poll()
		if pipeline.has_mesh_results():
			apply_mesh_results(false)
		if pipeline.has_collision_results():
			apply_collision_results(false)
		if pipeline.has_pending_work():
			OS.delay_usec(200)

# --- Chunks ---------------------------------------------------------------------------------

## Queue mesh jobs for [param dirty]. Empty dirty still closes the stage so the host can finish.
func dispatch(dirty: Array, rebuild_id: int) -> void:
	if dirty.is_empty():
		all_applied.emit()
		return
	var jobs: Array = []
	for chunk in dirty:
		jobs.append(chunk_job(chunk))
	pipeline.use_threads = host.use_multithreading
	pipeline.worker_threads = host.max_worker_threads
	pipeline.dispatch_mesh_jobs(jobs, rebuild_id)
	if not pipeline.use_threads or jobs.size() <= 1:
		apply_mesh_results(false)

func chunk_job(chunk) -> Dictionary:
	var r: Rect2i = chunk.sample_rect
	var heightmap: Image = host.get_final_image().get_region(r)
	var hole_image: Image = null
	var has_holes := false
	var holes = host.get_hole_map()
	if holes != null:
		var sub = holes.extract(r)
		if sub.data.count(0.0) != sub.data.size():
			has_holes = true
			hole_image = sub.to_image()
	var mesh_heightmap := heightmap
	var mesh_holes := hole_image
	var step := mesh_step(chunk)
	if step > 1:
		mesh_heightmap = CollisionBuilder.downsample_exact(heightmap, step)
		if hole_image:
			mesh_holes = CollisionBuilder.downsample_exact(hole_image, step)
	# Normals are computed from the chunk grown by one sample, so the central difference at the
	# chunk border reads the neighbour's samples: neighbouring chunks (and chunks at different LOD
	# levels) then agree on the normal at their shared samples and the seam no longer shows as a
	# shading line. Without this the mesh generator has to fall back to one-sided differences at
	# every chunk edge.
	var normal_border := 1
	var normal_offset := Vector2i.ZERO
	var normal_source: Image = null
	var grid = host.get_grid()
	if grid != null:
		var grown: Rect2i = r.grow(normal_border).intersection(grid.full_rect())
		normal_source = host.get_final_image().get_region(grown)
		normal_offset = grown.position - r.position
	return {
		"key": chunk.key, "revision": chunk.edit_revision, "heightmap": heightmap,
		"hole_mask": hole_image, "has_holes": has_holes, "mesh_heightmap": mesh_heightmap,
		"mesh_hole_mask": mesh_holes, "size": chunk.world_bounds.size, "lod_level": chunk.lod_level,
		"normal_source": normal_source, "normal_stride": step, "normal_offset": normal_offset,
		"collision": true, "collision_budget": collision_budget(),
	}

func mesh_step(chunk) -> int:
	var cells: int = chunk.sample_rect.size.x - 1
	var base := 1
	if host.chunk_resolution > 0 and host.chunk_resolution < cells:
		base = maxi(cells / host.chunk_resolution, 1)
	var step: int = base << chunk.lod_level
	var w: int = chunk.sample_rect.size.x
	var h: int = chunk.sample_rect.size.y
	var fitted := mini(step, mini(w - 1, h - 1))
	while fitted > 1 and ((w - 1) % fitted != 0 or (h - 1) % fitted != 0):
		fitted -= 1
	return maxi(fitted, 1)

func collision_budget() -> int:
	if host.collision_triangle_budget > 0:
		return host.collision_triangle_budget
	return CollisionBuilder.budget_for_quality(host.collision_quality)

func apply_mesh_results(budgeted: bool) -> void:
	var start := Time.get_ticks_msec()
	var applied := 0
	while pipeline.has_mesh_results():
		apply_chunk_result(pipeline.pop_mesh_result())
		applied += 1
		if budgeted and host.chunk_apply_budget_ms > 0 and Time.get_ticks_msec() - start >= host.chunk_apply_budget_ms:
			diagnostics.count("apply_frames")
			break
	diagnostics.count("chunks_applied", applied)
	if not pipeline.has_pending_work():
		all_applied.emit()

func apply_chunk_result(result: Dictionary) -> void:
	var chunks = host.get_chunk_manager()
	var chunk = chunks.chunks.get(result["key"])
	if chunk == null or result.get("revision", -1) != chunk.edit_revision:
		return
	chunk.mesh_instance.mesh = MeshGen.mesh_from_arrays(result["arrays"])
	chunk.mesh_instance.cast_shadow = host.cast_shadows
	chunk.heightmap = result["heightmap"]
	chunk.hole_mask = result.get("hole_mask")
	chunk.has_holes = result.get("has_holes", false)
	chunk.collision_revision += 1
	chunks.mark_clean(chunk, result["revision"])
	apply_collision(chunk, result.get("collision_faces", PackedVector3Array()))
	chunk.nav_dirty = true
	if host.navigation_enabled:
		nav_due_msec = Time.get_ticks_msec() + host.navigation_debounce_ms
	queue_chunk_scatter(chunk)
	var material: Material = host.current_material()
	if material != null:
		chunk.mesh_instance.material_override = material
	var b: Rect2 = chunk.world_bounds
	var gy: float = host.global_position.y
	var aabb := AABB(Vector3(b.position.x, gy + host.final_min(), b.position.y),
		Vector3(b.size.x, maxf(host.final_max() - host.final_min(), 0.001), b.size.y))
	region_updated.emit(aabb)

# --- Collision ------------------------------------------------------------------------------

func apply_collision(chunk, faces: PackedVector3Array) -> void:
	if chunk.heightmap == null:
		return
	chunk.static_body.collision_layer = host.collision_layer
	chunk.static_body.collision_mask = host.collision_mask
	if not chunk.has_holes:
		var shape: HeightMapShape3D = chunk.height_shape if chunk.height_shape else HeightMapShape3D.new()
		chunk.height_shape = shape
		var w: int = chunk.heightmap.get_width()
		var d: int = chunk.heightmap.get_height()
		shape.map_width = w
		shape.map_depth = d
		shape.map_data = chunk.heightmap.get_data().to_float32_array()
		chunk.collision_shape.shape = shape
		chunk.collision_shape.scale = Vector3(chunk.world_bounds.size.x / float(w - 1), 1.0, chunk.world_bounds.size.y / float(d - 1))
		chunk.collision_trimesh = null
		return
	if faces.is_empty():
		faces = CollisionBuilder.build_faces(chunk.heightmap, chunk.world_bounds.size, chunk.hole_mask, collision_budget(), 0)
	var trimesh: ConcavePolygonShape3D = chunk.collision_trimesh if chunk.collision_trimesh else ConcavePolygonShape3D.new()
	chunk.collision_trimesh = trimesh
	trimesh.set_faces(faces)
	chunk.collision_shape.shape = trimesh
	chunk.collision_shape.scale = Vector3.ONE

func refresh_all_collision() -> void:
	var chunks = host.get_chunk_manager()
	if chunks == null:
		return
	var jobs: Array = []
	for chunk in chunks.chunks.values():
		if chunk.heightmap == null:
			continue
		if not chunk.has_holes:
			apply_collision(chunk, PackedVector3Array())
			continue
		jobs.append({"key": chunk.key, "heightmap": chunk.heightmap, "hole_mask": chunk.hole_mask,
			"size": chunk.world_bounds.size, "budget": collision_budget(), "lod_level": 0,
			"revision": chunk.collision_revision})
	pipeline.use_threads = host.use_multithreading
	pipeline.dispatch_collision_jobs(jobs)

func apply_collision_results(budgeted: bool) -> void:
	var chunks = host.get_chunk_manager()
	var start := Time.get_ticks_msec()
	while pipeline.has_collision_results():
		var result: Dictionary = pipeline.pop_collision_result()
		var chunk = chunks.chunks.get(result["key"])
		if chunk and result.get("revision", 0) == chunk.collision_revision:
			apply_collision(chunk, result.get("collision_faces", PackedVector3Array()))
		if budgeted and host.chunk_apply_budget_ms > 0 and Time.get_ticks_msec() - start >= host.chunk_apply_budget_ms:
			break

func apply_collision_layers() -> void:
	var chunks = host.get_chunk_manager()
	if chunks == null:
		return
	for chunk in chunks.chunks.values():
		chunk.static_body.collision_layer = host.collision_layer
		chunk.static_body.collision_mask = host.collision_mask

# --- Navigation -----------------------------------------------------------------------------

## Re-bake every chunk's navigation region now (manual schedule). [param synchronous] blocks.
func bake_navigation(synchronous: bool = false) -> void:
	mark_all_nav_dirty()
	nav_due_msec = Time.get_ticks_msec()
	if synchronous:
		bake_navigation_step(true)

func mark_all_nav_dirty() -> void:
	var chunks = host.get_chunk_manager()
	if chunks == null:
		return
	for chunk in chunks.chunks.values():
		chunk.nav_dirty = true
	if host.navigation_enabled:
		nav_due_msec = Time.get_ticks_msec() + host.navigation_debounce_ms

func clear_navigation() -> void:
	var chunks = host.get_chunk_manager()
	if chunks == null:
		return
	for chunk in chunks.chunks.values():
		if chunk.nav_region:
			chunk.nav_region.queue_free()
			chunk.nav_region = null
	nav_due_msec = 0

func bake_navigation_step(synchronous: bool = false) -> void:
	nav_due_msec = 0
	var final_map = host.get_final_map()
	if final_map == null:
		return
	var chunks = host.get_chunk_manager()
	for chunk in chunks.chunks.values():
		if not chunk.nav_dirty or chunk.nav_baking or chunk.heightmap == null:
			continue
		var job := NavigationBuilder.make_job(chunk, host.get_grid(), final_map, host.get_navigation_hole_map(),
			host.navigation_mesh_template, host.navigation_triangle_budget)
		chunk.nav_dirty = false
		if job.is_empty():
			continue
		chunk.nav_revision += 1
		var mesh: NavigationMesh = job["mesh"]
		if synchronous or not host.use_multithreading:
			NavigationServer3D.bake_from_source_geometry_data(mesh, job["geometry"])
			on_nav_baked(chunk.key, chunk.nav_revision, mesh)
		else:
			chunk.nav_baking = true
			nav_in_flight += 1
			NavigationServer3D.bake_from_source_geometry_data_async(mesh, job["geometry"],
				_nav_trampoline.bind(weakref(self), chunk.key, chunk.nav_revision, mesh))

static func _nav_trampoline(ref: WeakRef, key: Vector2i, revision: int, mesh: NavigationMesh) -> void:
	var applier = ref.get_ref()
	if is_instance_valid(applier):
		applier.on_nav_baked(key, revision, mesh, true)

func on_nav_baked(key: Vector2i, revision: int, mesh: NavigationMesh, was_async: bool = false) -> void:
	var chunks = host.get_chunk_manager()
	var chunk = chunks.chunks.get(key) if chunks else null
	if was_async:
		nav_in_flight = maxi(nav_in_flight - 1, 0)
	if chunk == null:
		return
	chunk.nav_baking = false
	if revision != chunk.nav_revision or not host.navigation_enabled or not host.is_inside_tree():
		return
	if chunk.nav_region == null or not is_instance_valid(chunk.nav_region):
		chunk.nav_region = NavigationRegion3D.new()
		chunk.nav_region.name = "Navigation"
		chunk.root.add_child(chunk.nav_region, false, Node.INTERNAL_MODE_BACK)
	chunk.nav_region.navigation_mesh = mesh
	navigation_baked.emit(mesh, key)
	if chunk.nav_dirty:
		nav_due_msec = Time.get_ticks_msec() + host.navigation_debounce_ms

## Navigation meshes of every chunk that has one (chunk key -> NavigationMesh).
func navigation_meshes() -> Dictionary:
	var out := {}
	var chunks = host.get_chunk_manager()
	if chunks:
		for chunk in chunks.chunks.values():
			if chunk.nav_region and chunk.nav_region.navigation_mesh:
				out[chunk.key] = chunk.nav_region.navigation_mesh
	return out

# --- LOD ------------------------------------------------------------------------------------

## LOD switch distances in meters, one per further level (each level halves the mesh resolution).
## With `lod_auto` the distances are derived from the world-space cell size and the camera
## projection: level n starts where one cell still covers `lod_pixel_error` pixels of the viewport.
## That is scale independent - the fixed meter distances of 0.x made every chunk of a 4 km terrain
## jump straight to the coarsest level and turned the terrain into countable triangles.
func lod_distances_for(camera: Camera3D) -> PackedFloat32Array:
	if not host.lod_auto or camera == null:
		return host.lod_distances
	var grid = host.get_grid()
	if grid == null:
		return host.lod_distances
	var view_height := 0.0
	var viewport := camera.get_viewport()
	if viewport != null:
		view_height = viewport.get_visible_rect().size.y
	if view_height < 1.0:
		# Headless / not-yet-sized viewport: the project's window height is the sane stand-in.
		view_height = maxf(float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080)), 1.0)
	var tan_half_fov := tan(deg_to_rad(clampf(camera.fov, 1.0, 179.0)) * 0.5)
	# A cell covers `cell * view_height / (2 * distance * tan(fov/2))` pixels: solve for distance.
	var cell: float = grid.cell
	var level_zero: float = cell * view_height / (2.0 * tan_half_fov * maxf(host.lod_pixel_error, 0.1))
	var out := PackedFloat32Array()
	for i in maxi(host.lod_levels, 1):
		out.append(level_zero * float(1 << i))
	return out

## Distance from [param point] (XZ) to the nearest point of the chunk rectangle.
static func _distance_to_bounds(bounds: Rect2, point: Vector2) -> float:
	var nearest := Vector2(
		clampf(point.x, bounds.position.x, bounds.end.x),
		clampf(point.y, bounds.position.y, bounds.end.y))
	return point.distance_to(nearest)

func update_lod() -> void:
	var camera: Camera3D = host.find_camera()
	if camera == null:
		return
	var pos := camera.global_position
	if _lod_camera != Vector3.INF and pos.distance_to(_lod_camera) < 16.0:
		return
	_lod_camera = pos
	var distances := lod_distances_for(camera)
	var chunks = host.get_chunk_manager()
	var changed: Array = []
	for chunk in chunks.chunks.values():
		var d := _distance_to_bounds(chunk.world_bounds, Vector2(pos.x, pos.z))
		var lod := 0
		for i in distances.size():
			if d >= distances[i]:
				lod = i + 1
		if lod != chunk.lod_level:
			chunk.lod_level = lod
			chunks.mark_dirty(chunk)
			changed.append(chunk)
	if not changed.is_empty():
		dispatch(changed, host.get_rebuild_id())

# --- Scatter --------------------------------------------------------------------------------

func scatter_nodes() -> Array:
	var out: Array = []
	_collect_scatter(host, out)
	return out

func _collect_scatter(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is TerrainScatterNode:
			if child.enabled and child.visible:
				out.append(child)
		elif child is Node3D and not (child is TerrainPaintLayer):
			_collect_scatter(child, out)

func queue_chunk_scatter(chunk) -> void:
	if not scatter_queue.has(chunk.key):
		scatter_queue.append(chunk.key)

func process_scatter_queue(unbudgeted: bool = false) -> void:
	var final_map = host.get_final_map()
	var chunks = host.get_chunk_manager()
	if final_map == null or chunks == null:
		return
	var scatters := scatter_nodes()
	if scatter_dirty_all:
		scatter_dirty_all = false
		scatter_queue.clear()
		for key in chunks.chunks.keys():
			scatter_queue.append(key)
	var start := Time.get_ticks_msec()
	while not scatter_queue.is_empty():
		var item = scatter_queue.pop_front()
		if item is int:
			# A scatter node changed: every chunk refreshes that node only.
			var node := instance_from_id(item) as TerrainScatterNode
			for chunk in chunks.chunks.values():
				ScatterBuilder.refresh_chunk(host, chunk, [node] if node and scatters.has(node) else [],
					host.get_grid(), final_map, host.get_hole_map(), item)
		else:
			var chunk = chunks.chunks.get(item)
			if chunk:
				ScatterBuilder.refresh_chunk(host, chunk, scatters, host.get_grid(), final_map, host.get_hole_map())
		if not unbudgeted and host.chunk_apply_budget_ms > 0 and Time.get_ticks_msec() - start >= host.chunk_apply_budget_ms:
			break
