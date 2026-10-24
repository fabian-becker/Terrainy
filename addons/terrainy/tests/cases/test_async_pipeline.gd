extends "res://addons/terrainy/tests/framework/test_case.gd"

## Performance contract: composition runs as a worker task, chunks are applied under the
## frame budget, nothing is lost or applied out of order.

func test_threaded_compose_does_not_block_the_frame() -> void:
	var gen := make_generator(256, 256.0)
	gen.chunk_size = 32
	gen.chunk_apply_budget_ms = 4
	for i in 6:
		var f := make_field(5.0, Vector2(60, 60), Vector3(-80 + i * 30, 0, 0))
		var r := TerrainReliefSource.new()
		f.relief_layers = [r]
		gen.add_child(f)
	spawn(gen)
	var worst := 0
	var frames := 0
	var deadline := Time.get_ticks_msec() + 60000
	while gen.is_rebuilding() and Time.get_ticks_msec() < deadline:
		var t0 := Time.get_ticks_msec()
		gen._process(0.0)
		worst = maxi(worst, Time.get_ticks_msec() - t0)
		frames += 1
		OS.delay_usec(1000)
	t.check(not gen.is_rebuilding(), "settled")
	t.check(frames > 2, "the rebuild was spread over several frames (%d)" % frames)
	# The apply budget bounds per-frame work; one chunk / collision apply may overshoot it.
	t.check(worst < 250, "no frame blocked for long (worst %d ms)" % worst)
	t.check_eq(gen.get_chunk_manager().dirty_chunks().size(), 0, "every chunk applied")
	t.check(gen.get_diagnostics()["counters"].get("apply_frames", 0) > 0, "application was budgeted over frames")

func test_edit_during_rebuild_is_not_lost() -> void:
	var gen := make_generator()
	var f := make_field(3.0, Vector2(20, 20))
	gen.add_child(f)
	spawn(gen)
	gen._process(0.0)
	f.profile_height = 9.0  # while the first rebuild is in flight
	t.check(settle(gen), "settled")
	t.check_almost_eq(h_at(gen, 0, 0), 9.0, "the later edit wins")

func test_synchronous_and_threaded_paths_agree() -> void:
	var make := func(threaded: bool) -> TerrainGenerator:
		var g := make_generator()
		g.use_multithreading = threaded
		var f := make_field(4.0, Vector2(30, 30))
		f.relief_layers = [TerrainReliefSource.new()]
		g.add_child(f)
		spawn(g)
		settle(g)
		return g
	var a: TerrainGenerator = make.call(true)
	var b: TerrainGenerator = make.call(false)
	t.check(a.get_final_map().data == b.get_final_map().data, "identical composites")

# --- Track A: worker threads, cancellation, collision range, tail unit -------------------------

func test_worker_thread_count_defaults_to_cores_minus_one() -> void:
	var gen := make_generator()
	t.check_eq(gen.max_worker_threads, 0, "0 = auto by default")
	t.check_eq(gen.effective_worker_threads(), maxi(OS.get_processor_count() - 1, 1),
		"auto resolves to cores - 1 so the main thread keeps a core")
	gen.max_worker_threads = 3
	t.check_eq(gen.effective_worker_threads(), 3, "an explicit thread count wins")
	gen.free()  # never entered the tree, so the runner cannot clean it up

func test_stale_chunk_result_is_discarded() -> void:
	# Cancellation: a result whose revision no longer matches the chunk must be dropped, not
	# committed. The result here is deliberately empty, so a commit would fail loudly.
	var gen := build(make_generator(64, 64.0), [make_field(4.0, Vector2(30, 30))])
	var chunk = gen.get_chunk_manager().chunks[Vector2i(0, 0)]
	var before = chunk.mesh_instance.mesh
	gen._applier.apply_chunk_result({
		"key": chunk.key, "revision": chunk.edit_revision - 1,
		"arrays": [], "heightmap": null,
	})
	t.check(chunk.mesh_instance.mesh == before, "superseded result did not replace the mesh")

func test_collision_range_keeps_shapes_only_near_the_camera() -> void:
	# The physics range is measured from the LOD camera, or from the generator when there is none.
	# Park the generator far from the world origin so the measurement point lies outside every chunk
	# regardless of which reference source this run resolves (a leftover camera from an earlier case
	# used to decide that, which made the assertion order-dependent).
	var gen := build(make_generator(128, 128.0, func(g: TerrainGenerator) -> void:
		g.chunk_size = 32
		g.position = Vector3(10000.0, 0.0, 10000.0)), [make_field(4.0, Vector2(60, 60))])
	var chunks = gen.get_chunk_manager().chunks
	var applier = gen._applier
	# 0 = physics everywhere, which is the 1.x behaviour and the default.
	for chunk in chunks.values():
		t.check(not chunk.collision_shape.disabled, "shape active with collision_range = 0")
	# A range nothing can fall into gates every chunk, but keeps the CPU heightfield on the chunk.
	gen.collision_range = 0.001
	applier.update_collision_range()
	var gated := 0
	for chunk in chunks.values():
		if chunk.collision_shape.disabled:
			gated += 1
			t.check(chunk.collision_heights.size() > 0 or chunk.has_holes,
				"gated chunk %s keeps its CPU data for re-entry" % chunk.key)
	t.check_eq(gated, chunks.size(), "every chunk outside the range lost its shape")
	# Widening the range restores the shapes from that cache - no rebuild, no recompose.
	gen.collision_range = 1e6
	applier.update_collision_range()
	var restored := 0
	for chunk in chunks.values():
		if not chunk.collision_shape.disabled:
			restored += 1
	t.check_eq(restored, chunks.size(), "re-entering the range restores every shape")

func test_collision_refresh_is_queued_not_built_in_one_frame() -> void:
	# DESIGN.md §6.3 / D7.1: a collision quality change must not rebuild every shape in one frame
	# (114.9 ms at 2048 cells in the LOD flythrough). The setter only queues; the frame step drains
	# a budgeted slice and the rest waits.
	var gen := build(make_generator(256, 256.0, func(g: TerrainGenerator) -> void:
		g.chunk_size = 32), [make_field(4.0, Vector2(60, 60))])
	var applier = gen._applier
	gen.collision_triangle_budget = 2000
	t.check(applier.collision_refresh_pending, "a collision setting change queues a refresh")
	applier.step_collision_refresh(false)
	t.check(not applier.collision_refresh_pending, "an unbudgeted slice drains the queue")
	t.check(applier._collision_refresh_queue.is_empty(), "queue emptied")
	var shaped := 0
	for chunk in gen.get_chunk_manager().chunks.values():
		if chunk.collision_shape.shape != null:
			shaped += 1
	t.check_eq(shaped, gen.get_chunk_manager().chunks.size(), "every chunk still has a shape")

func test_all_applied_tail_gets_its_own_frame() -> void:
	# DESIGN.md §7.4: the tail (material refresh + report) is one budget unit of its own, so a frame
	# that already committed may not also run it.
	var gen := build(make_generator(), [make_field(3.0, Vector2(20, 20))])
	var applier = gen._applier
	gen.chunk_apply_budget_ms = 8
	gen.tail_budget_ms = 2
	applier._budgeted_window = true
	applier._budget_start_usec = Time.get_ticks_usec()
	t.check(not applier.can_spend_tail(1), "a frame that committed hands the tail to the next frame")
	t.check(applier.can_spend_tail(0), "a frame that committed nothing may run the tail")
