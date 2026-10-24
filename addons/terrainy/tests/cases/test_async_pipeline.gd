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
