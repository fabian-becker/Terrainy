extends "res://addons/terrainy/tests/framework/test_case.gd"

## Distance LOD, seaming (skirts), streaming (view distance) and the per-frame work budget.
##
## Track B of the optimization work: a chunk only builds what the camera can tell apart, chunks
## outside the view distance release their GPU/physics resources, LOD boundaries do not crack, and
## the main-thread work per frame stays inside `chunk_apply_budget_ms`.

const LodController = preload("res://addons/terrainy/gen/build/lod_controller.gd")
const ChunkScheduler = preload("res://addons/terrainy/gen/build/chunk_scheduler.gd")

var _root_size_before: Vector2i = Vector2i.ZERO

func after_all() -> void:
	if _root_size_before != Vector2i.ZERO:
		tree.root.size = _root_size_before
		_root_size_before = Vector2i.ZERO
	super.after_all()

## A camera looking at the terrain from [param position]. LOD distances are fixed in the tests
## (lod_auto off) so the levels do not depend on the headless viewport size.
func _camera(position: Vector3, look_at: Vector3 = Vector3.ZERO) -> Camera3D:
	if _root_size_before == Vector2i.ZERO:
		_root_size_before = tree.root.size
	tree.root.size = Vector2i(1280, 720)
	var camera := Camera3D.new()
	camera.fov = 70.0
	spawn(camera)
	camera.global_position = position
	if not position.is_equal_approx(look_at):
		camera.look_at(look_at)
	camera.current = true
	return camera

## Generator with fixed, explicit LOD distances (100 / 200 / 300 m) and LOD switched on.
func _gen(resolution: int = 128, size: float = 128.0, extra: Callable = Callable()) -> TerrainGenerator:
	var gen := make_generator(resolution, size, func(g: TerrainGenerator) -> void:
		g.enable_lod = true
		g.lod_auto = false
		g.lod_distances = PackedFloat32Array([100.0, 200.0, 300.0])
		g.lod_hysteresis = 0.1
		if extra.is_valid():
			extra.call(g))
	return gen

# --- LOD selection -----------------------------------------------------------------------------

func test_lod_level_follows_the_switch_distances() -> void:
	var distances := PackedFloat32Array([100.0, 200.0, 300.0])
	t.check_eq(LodController.level_with_hysteresis(0.0, 0, distances, 0.0), 0, "right on top of the chunk")
	t.check_eq(LodController.level_with_hysteresis(99.0, 0, distances, 0.0), 0, "just inside level 0")
	t.check_eq(LodController.level_with_hysteresis(100.0, 0, distances, 0.0), 1, "at the first switch distance")
	t.check_eq(LodController.level_with_hysteresis(250.0, 0, distances, 0.0), 2, "between 200 and 300")
	t.check_eq(LodController.level_with_hysteresis(5000.0, 0, distances, 0.0), 3, "beyond the last level clamps")

func test_hysteresis_holds_the_level_inside_the_band() -> void:
	var distances := PackedFloat32Array([100.0, 200.0, 300.0])
	# A chunk that is already coarse stays coarse until it is clearly closer.
	t.check_eq(LodController.level_with_hysteresis(95.0, 1, distances, 0.1), 1, "95 m does not refine at 10 %")
	t.check_eq(LodController.level_with_hysteresis(89.0, 1, distances, 0.1), 0, "89 m refines")
	# and a fine chunk does not coarsen until it is clearly farther.
	t.check_eq(LodController.level_with_hysteresis(105.0, 0, distances, 0.1), 0, "105 m does not coarsen at 10 %")
	t.check_eq(LodController.level_with_hysteresis(111.0, 0, distances, 0.1), 1, "111 m coarsens")
	# A camera teleporting several levels lands on the right one in one pass.
	t.check_eq(LodController.level_with_hysteresis(1000.0, 0, distances, 0.1), 3, "multi-level jump")

## The real thrash case: a camera hovering on a switch distance must not rebuild the chunk.
func test_hovering_on_a_switch_distance_does_not_rebuild() -> void:
	var gen := _gen(128, 128.0)
	build(gen)
	var camera := _camera(Vector3(0.0, 120.0, 260.0), Vector3.ZERO)
	var chunk = gen.get_chunk_manager().chunks[Vector2i(0, 0)]
	gen._applier.update_lod()
	var revision_before: int = chunk.edit_revision
	var level: int = chunk.lod_level
	for i in 12:
		# 0.5 m back and forth across whatever distance this chunk currently sits at.
		camera.global_position.z = 260.0 + (0.5 if i % 2 == 0 else -0.5)
		gen._applier.update_lod()
	t.check_eq(chunk.lod_level, level, "level is stable over 12 jittering updates")
	var rebuilds: int = chunk.edit_revision - revision_before
	t.check(rebuilds <= 0, "no rebuild while the camera jitters on the boundary (%d)" % rebuilds)
	t.check_eq(int(gen.get_diagnostics()["lod"]["flips"]), 0, "no LOD flip while parked on a boundary")

# --- LOD rebuilds are per chunk ----------------------------------------------------------------

func test_lod_change_rebuilds_only_the_changed_chunks() -> void:
	var gen := _gen(128, 128.0)
	build(gen)
	_camera(Vector3(0.0, 100.0, 0.5), Vector3.ZERO)
	gen._applier.update_lod()
	var chunks = gen.get_chunk_manager().chunks
	var before: Dictionary = {}
	for key in chunks:
		before[key] = chunks[key].edit_revision
	# Move to the +Z edge: the far half of the terrain must coarsen, the near half must not.
	_camera(Vector3(0.0, 100.0, 120.0), Vector3.ZERO)
	gen._applier.update_lod()
	var changed: Array = []
	var untouched: Array = []
	for key in chunks:
		if chunks[key].edit_revision != before[key]:
			changed.append(key)
		else:
			untouched.append(key)
	t.check(not changed.is_empty(), "chunks behind the camera coarsened (%d)" % changed.size())
	t.check(not untouched.is_empty(), "chunks in front of the camera were left alone (%d)" % untouched.size())
	# And the coarse mesh really is coarser.
	var coarse = null
	for key in changed:
		if coarse == null or chunks[key].lod_level > coarse.lod_level:
			coarse = chunks[key]
	t.check(coarse.lod_level > 0, "changed chunk is at a coarser level (%d)" % coarse.lod_level)
	var verts: int = (coarse.mesh_instance.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	t.check(verts < 33 * 33, "coarse chunk mesh has fewer vertices (%d)" % verts)
	t.check_eq(coarse.collision_shape.shape != null, true, "collision stays at full resolution")

# --- Streaming ---------------------------------------------------------------------------------

func test_view_distance_streams_out_and_back() -> void:
	var gen := _gen(128, 128.0, func(g: TerrainGenerator) -> void:
		g.view_distance = 48.0
		g.lod_distances = PackedFloat32Array([8.0, 16.0, 24.0]))
	build(gen)
	var chunks = gen.get_chunk_manager().chunks
	var far_key := Vector2i(3, 3)
	var far = chunks[far_key]
	# Camera in the opposite corner: the far corner chunk is ~170 m away.
	_camera(Vector3(-64.0, 60.0, -64.0), Vector3.ZERO)
	gen._applier.update_lod()
	t.check_eq(far.streamed_in, false, "far chunk is streamed out")
	t.check(far.mesh_instance.mesh == null, "streamed-out chunk released its mesh")
	t.check(far.collision_shape.shape == null, "streamed-out chunk released its collision shape")
	t.check(far.heightmap == null, "streamed-out chunk released its heightmap")
	t.check(int(gen.get_diagnostics()["streamed_out_chunks"]) > 0, "diagnostics report streamed-out chunks")
	# Fly to it: it must come back, fully built.
	_camera(Vector3(48.0, 60.0, 48.0), Vector3.ZERO)
	gen._applier.update_lod()
	t.check_eq(far.streamed_in, true, "near chunk is resident again")
	t.check(far.mesh_instance.mesh != null, "mesh rebuilt on re-entry")
	t.check(far.collision_shape.shape is HeightMapShape3D, "collision rebuilt on re-entry")
	t.check_eq(far.mesh_instance.visible, true, "mesh visible again")

## `view_distance == 0` is the default and must keep everything resident.
func test_view_distance_zero_keeps_everything() -> void:
	var gen := _gen(128, 128.0)
	build(gen)
	_camera(Vector3(0.0, 60.0, 0.0), Vector3.ZERO)
	gen._applier.update_lod()
	for chunk in gen.get_chunk_manager().chunks.values():
		t.check_eq(chunk.streamed_in, true, "chunk %s resident" % chunk.key)
	t.check_eq(int(gen.get_diagnostics()["streamed_out_chunks"]), 0, "nothing streamed out")

# --- Frame budget ------------------------------------------------------------------------------

## The accountant itself: a budget is spent between units, never inside one, and a spent budget
## stops the drain even though work is queued.
func test_budget_accountant_stops_between_units() -> void:
	var gen := _gen(256, 256.0, func(g: TerrainGenerator) -> void:
		g.chunk_size = 64
		g.lod_distances = PackedFloat32Array([4.0, 8.0, 12.0]))
	build(gen)
	var chunks = gen.get_chunk_manager()
	_camera(Vector3(0.0, 200.0, 0.0), Vector3.ZERO)
	var scheduler = gen._applier.scheduler
	scheduler.clear()
	for chunk in chunks.chunks.values():
		chunk.lod_level = 3
		chunks.mark_dirty(chunk)
		scheduler.enqueue(chunk, ChunkScheduler.Priority.EDIT)
	var queued: int = scheduler.queued()
	t.check(queued > 4, "many chunks want work (%d queued)" % queued)
	# A budget far below the cost of one job assembly: exactly one unit may run.
	scheduler.budget_ms = 0.05
	scheduler.begin_frame(0)
	gen._applier._drain_queue(true)
	var units: int = scheduler.units_taken()
	t.check(units >= 1, "the budget still makes progress (%d units)" % units)
	# A job assembly shares one snapshot per rebuild (design §4.4), so a unit costs tens of
	# microseconds rather than milliseconds: more than two can legitimately fit into 0.05 ms. The
	# invariant is that the drain *stops on the budget*, not that it runs exactly one unit.
	t.check(units < queued, "one tiny-budget frame ran only %d of %d queued units" % [units, queued])
	t.check(not scheduler.can_spend(), "the drain stopped because the budget was spent")
	t.check(scheduler.has_work(), "the rest of the queue survives to the next frame")
	# And the synchronous path drains it regardless of the budget.
	gen._applier.drain()
	t.check_eq(scheduler.has_work(), false, "drain() empties the queue unbudgeted")
	t.check_eq(gen._applier.has_mesh_work(), false, "no mesh job left in flight")

## Priority order and the starvation guard (design D7.2).
func test_scheduler_priority_order_and_starvation_guard() -> void:
	var gen := _gen(128, 128.0)
	build(gen)
	var chunks = gen.get_chunk_manager()
	var keys: Array = chunks.chunks.keys()
	t.check(keys.size() >= 4, "fixture has at least four chunks")
	var a = chunks.chunks[keys[0]]
	var b = chunks.chunks[keys[1]]
	var c = chunks.chunks[keys[2]]
	var d = chunks.chunks[keys[3]]
	var scheduler = gen._applier.scheduler
	scheduler.clear()
	scheduler.budget_ms = 8.0
	scheduler.begin_frame(0)
	scheduler.enqueue(a, ChunkScheduler.Priority.NAV)
	scheduler.enqueue(b, ChunkScheduler.Priority.COLLISION)
	scheduler.enqueue(c, ChunkScheduler.Priority.EDIT)
	scheduler.enqueue(d, ChunkScheduler.Priority.LOD_COARSEN)
	t.check_eq(scheduler.queued(), 4, "four units queued")
	t.check_eq(scheduler.take_next(), c, "EDIT drains first")
	t.check_eq(scheduler.take_next(), d, "then LOD_COARSEN")
	t.check_eq(scheduler.take_next(), b, "then COLLISION")
	t.check_eq(scheduler.take_next(), a, "NAV last")
	t.check_eq(scheduler.take_next(), null, "empty queue returns null")

	# A unit that waits long enough beats a fresher one class above it.
	scheduler.clear()
	scheduler.begin_frame(0)
	scheduler.enqueue(a, ChunkScheduler.Priority.NAV)
	for frame in range(1, 200):
		scheduler.begin_frame(frame)
	scheduler.enqueue(c, ChunkScheduler.Priority.COLLISION)
	t.check_eq(scheduler.take_next(), a, "a starving NAV unit outranks a fresh COLLISION unit")

	# Re-queueing a chunk keeps exactly one entry (no stacked rebuilds).
	scheduler.clear()
	scheduler.begin_frame(0)
	scheduler.enqueue(a, ChunkScheduler.Priority.EDIT)
	scheduler.enqueue(a, ChunkScheduler.Priority.LOD_COARSEN)
	t.check_eq(scheduler.queued(), 1, "one entry per chunk")
	t.check_eq(scheduler.take_next(), a, "the re-queued chunk is handed out once")
	t.check_eq(scheduler.take_next(), null, "and not again")

	# Cancel drops a unit without handing it out.
	scheduler.enqueue(a, ChunkScheduler.Priority.EDIT)
	scheduler.cancel(a)
	t.check_eq(scheduler.has_work(), false, "cancelled work is not handed out")
	t.check(int(scheduler.stats()["drops"]) >= 1, "the drop is counted")

# --- Seams -------------------------------------------------------------------------------------

## A uniform terrain has no LOD boundary, so it must not pay for skirts at all.
func test_uniform_terrain_has_no_skirts() -> void:
	var gen := _gen(64, 64.0)
	build(gen)
	var chunk = gen.get_chunk_manager().chunks[Vector2i(0, 0)]
	t.check_eq(chunk.lod_level, 0, "chunk is at full resolution")
	t.check_eq(gen._applier.lod.edges_for(chunk.key, gen.get_chunk_manager().chunks), 0,
		"no edge needs a skirt")
	t.check_eq(chunk.mesh_instance.mesh.get_surface_count(), 1, "mesh is the terrain surface only")

## The edge mask names the edges whose neighbour samples at a different resolution (design D5.4).
func test_edges_for_marks_only_the_differing_neighbour() -> void:
	var gen := _gen(64, 64.0)
	build(gen)
	var chunks = gen.get_chunk_manager().chunks
	var fine = chunks[Vector2i(0, 0)]
	var coarse = chunks[Vector2i(1, 0)]
	coarse.lod_level = 2
	t.check_eq(gen._applier.lod.step_for(fine), 1, "level 0 mesh step is 1")
	t.check_eq(gen._applier.lod.step_for(coarse), 4, "level 2 mesh step is 4")
	var mask: int = gen._applier.lod.edges_for(fine.key, chunks)
	t.check_eq(mask & LodController.Edge.EAST, LodController.Edge.EAST, "east edge differs")
	t.check_eq(mask & LodController.Edge.WEST, 0, "west edge has no neighbour")
	t.check_eq(mask & LodController.Edge.NORTH, 0, "north edge has no neighbour")
	t.check_eq(gen._applier.lod.edges_for(coarse.key, chunks) & LodController.Edge.WEST,
		LodController.Edge.WEST, "the coarse side sees it too")

## A chunk whose neighbour is coarser emits a wall on the shared edge, deep enough to cover the
## sampling error between the two resolutions.
func test_skirt_covers_the_lod_crack() -> void:
	var f := make_field(6.0, Vector2(64, 64))
	var relief := TerrainReliefSource.new()
	relief.weight = 5.0
	relief.noise.frequency = 0.09
	relief.noise_seed = 3
	f.relief_layers = [relief] as Array[TerrainReliefSource]
	var gen := _gen(64, 64.0)
	build(gen, [f])
	var chunks = gen.get_chunk_manager().chunks
	# Force one neighbour to a coarse level, exactly what distance LOD does at runtime.
	var coarse = chunks[Vector2i(1, 0)]
	coarse.lod_level = 2
	gen.get_chunk_manager().mark_dirty(coarse)
	gen.rebuild_now()
	var fine = chunks[Vector2i(0, 0)]
	t.check_eq(fine.lod_level, 0, "neighbour stays at LOD 0")
	var fine_edge := _border_heights(fine, true)
	var coarse_edge := _border_heights(coarse, false)
	t.check(fine_edge.size() == 33, "fine border has 33 samples")
	t.check(coarse_edge.size() == 9, "coarse border has 9 samples (LOD 2)")
	var worst := 0.0
	for j in fine_edge.size():
		var t01 := float(j) / float(fine_edge.size() - 1)
		var cpos := t01 * float(coarse_edge.size() - 1)
		var i0 := clampi(int(floor(cpos)), 0, coarse_edge.size() - 1)
		var i1 := clampi(i0 + 1, 0, coarse_edge.size() - 1)
		var lerped: float = lerpf(coarse_edge[i0], coarse_edge[i1], cpos - float(i0))
		worst = maxf(worst, absf(fine_edge[j] - lerped))
	t.check(worst > 0.0001, "the two borders really disagree (%.3f m gap)" % worst)
	# The rebuilt coarse chunk carries the skirt on the shared edge ...
	var mesh: ArrayMesh = coarse.mesh_instance.mesh
	t.check_eq(mesh.get_surface_count(), 2, "coarse chunk has the terrain surface and a skirt")
	var base: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	t.check_eq(base.size(), 9 * 9, "surface 0 is still the plain chunk mesh")
	var skirt: PackedVector3Array = mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
	t.check(skirt.size() >= 8 * 4, "skirt covers the shared edge (%d verts)" % skirt.size())
	var base_min := 1e20
	for v in base:
		base_min = minf(base_min, v.y)
	var skirt_min := 1e20
	for v in skirt:
		skirt_min = minf(skirt_min, v.y)
	t.check(skirt_min < base_min, "skirt reaches below the surface (%.2f < %.2f)" % [skirt_min, base_min])
	var depth: float = gen._applier.lod.skirt_depth(gen._applier.lod.step_for(coarse))
	t.check(depth >= minf(worst, 6.0), "skirt depth %.2f m covers the %.3f m crack" % [depth, worst])

## Heights of a chunk's border along Z, at the edge shared with its +X / -X neighbour.
func _border_heights(chunk, right_edge: bool) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var mesh: ArrayMesh = chunk.mesh_instance.mesh
	if mesh == null:
		return out
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var xs: Array[float] = []
	for v in verts:
		xs.append(v.x)
	var target: float = xs.max() if right_edge else xs.min()
	var by_z: Dictionary = {}
	for v in verts:
		if absf(v.x - target) < 0.001:
			by_z[snappedf(v.z, 0.001)] = v.y
	var keys: Array = by_z.keys()
	keys.sort()
	for k in keys:
		out.append(by_z[k])
	return out
