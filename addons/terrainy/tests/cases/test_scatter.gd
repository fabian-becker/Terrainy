extends "res://addons/terrainy/tests/framework/test_case.gd"

## TerrainScatterNode: deterministic, mask-aligned MultiMesh placement per chunk.

const ScatterBuilder = preload("res://addons/terrainy/gen/build/scatter_builder.gd")

func _scatter() -> TerrainScatterNode:
	var s := TerrainScatterNode.new()
	s.mesh = BoxMesh.new()
	s.density = 5.0
	return s

func test_one_multimesh_per_chunk_and_on_the_surface() -> void:
	var f := make_field(5.0, Vector2(30, 30))
	var s := _scatter()
	var gen := build(make_generator(), [f, s])
	var count := 0
	for chunk in gen.get_chunk_manager().chunks.values():
		var mmi: MultiMeshInstance3D = chunk.scatter.get(s.get_instance_id())
		t.check(mmi != null, "chunk %s has a MultiMeshInstance3D" % chunk.key)
		if mmi:
			count += mmi.multimesh.instance_count
	var expected := 64.0 * 64.0 / 100.0 * 5.0
	t.check(count > expected * 0.5 and count <= expected * 1.05, "density respected (%d ~ %.0f)" % [count, expected])
	var placed := ScatterBuilder.collect(gen, s)
	var worst := 0.0
	for xf in placed:
		worst = maxf(worst, absf(xf.origin.y - h_at(gen, xf.origin.x, xf.origin.z)))
	t.check(worst < 0.01, "instances sit on the terrain (worst %.4f)" % worst)

func test_placement_is_deterministic_and_chunk_independent() -> void:
	var s := _scatter()
	var gen := build(make_generator(), [s])
	var a := ScatterBuilder.collect(gen, s).size()
	gen.chunk_size = 16
	gen.rebuild_now()
	t.check_eq(ScatterBuilder.collect(gen, s).size(), a, "same instances with another chunk layout")
	s.noise_seed = 42
	gen.rebuild_now()
	settle(gen)
	t.check(ScatterBuilder.collect(gen, s).size() > 0, "reseeded")

func test_masks_slope_and_holes_filter_candidates() -> void:
	var s := _scatter()
	var m := TerrainMaskRegion.new()
	m.size = Vector2(20, 20)
	m.falloff = null
	m.relative_to_owner = false
	s.masks = [m]
	var hole := TerrainHoleNode.new()
	hole.size = Vector3(6, 100, 6)
	var gen := build(make_generator(), [hole, s])
	var placed := ScatterBuilder.collect(gen, s)
	t.check(placed.size() > 0, "some instances")
	for xf in placed:
		var p := Vector2(xf.origin.x, xf.origin.z)
		t.check(absf(p.x) <= 10.5 and absf(p.y) <= 10.5, "inside the region mask")
		t.check(not TerrainyAPI.get_hole_at(gen, Vector3(p.x, 0, p.y)), "never in a hole")

func test_scatter_edit_does_not_recompose_heights() -> void:
	var s := _scatter()
	var gen := build(make_generator(), [make_field(), s])
	var rebuilds: int = gen.get_diagnostics()["rebuild_id"]
	s.density = 1.0
	settle(gen)
	t.check_eq(gen.get_diagnostics()["rebuild_id"], rebuilds, "scatter edits only refresh instances")
	t.check(ScatterBuilder.collect(gen, s).size() < 64 * 64 / 100 * 2, "density applied")
