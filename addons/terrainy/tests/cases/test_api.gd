extends "res://addons/terrainy/tests/framework/test_case.gd"

## TerrainyAPI: static registry, query semantics, region sampling, settle, signals.

func test_registry_and_signals() -> void:
	var added: Array = []
	var removed: Array = []
	var on_add := func(tt): added.append(tt)
	var on_remove := func(tt): removed.append(tt)
	TerrainyAPI.signals.terrain_added.connect(on_add)
	TerrainyAPI.signals.terrain_removed.connect(on_remove)
	var gen := make_generator()
	gen.position = Vector3(5000, 0, 0)
	build(gen)
	t.check(TerrainyAPI.get_terrains().has(gen), "registered on ready")
	t.check(added.has(gen), "terrain_added emitted")
	t.check(TerrainyAPI.find_terrain_at(Vector3(5005, 0, 5)) == gen, "find_terrain_at")
	tree.root.remove_child(gen)
	t.check(not TerrainyAPI.get_terrains().has(gen), "unregistered on exit")
	t.check(removed.has(gen), "terrain_removed emitted")
	tree.root.add_child(gen)
	TerrainyAPI.signals.terrain_added.disconnect(on_add)
	TerrainyAPI.signals.terrain_removed.disconnect(on_remove)

func test_multiple_terrains_are_queried_explicitly() -> void:
	var a := build(make_generator(), [make_field(5.0, Vector2(20, 20))])
	var b := make_generator()
	b.position = Vector3(7000, 3, 0)
	build(b)
	t.check_almost_eq(TerrainyAPI.get_height_at(a, Vector3(0, 0, 0)), 5.0, "terrain a")
	t.check_almost_eq(TerrainyAPI.get_height_at(b, Vector3(7000, 0, 0)), 3.0, "terrain b includes its y")
	t.check(TerrainyAPI.find_terrain_at(Vector3(7000, 0, 0)) == b, "lookup by position")

func test_height_is_bilinear_and_outside_falls_back() -> void:
	var gen := build(make_generator(64, 64.0, func(g: TerrainGenerator): g.base_height = 1.0), [make_field(4.0, Vector2(30, 30))])
	var h00 := h_at(gen, 2, 2)
	var h10 := h_at(gen, 3, 2)
	t.check_almost_eq(h_at(gen, 2.5, 2), (h00 + h10) * 0.5, "bilinear between samples", 1e-4)
	t.check_almost_eq(TerrainyAPI.get_height_at(gen, Vector3(500, 0, 500)), 1.0, "outside: generator y + base height")
	t.check(is_nan(TerrainyAPI.get_height_at(null, Vector3.ZERO)), "invalid terrain -> NAN")

func test_normal_points_downhill() -> void:
	var f := make_field(10.0, Vector2(40, 40))
	var p := Curve.new()
	p.add_point(Vector2(0, 0))
	p.add_point(Vector2(1, 1))
	f.profile = p
	f.domain_falloff = null
	var gen := build(make_generator(), [f])
	var n := TerrainyAPI.get_normal_at(gen, Vector3(10, 0, 0))
	t.check(n.x > 0.1 and n.y > 0.5, "normal tilts away from the summit (%s)" % n)
	t.check(TerrainyAPI.get_normal_at(gen, Vector3(30, 0, 30)).is_equal_approx(Vector3.UP), "flat outside")

func test_fields_at_and_paint_at() -> void:
	var a := make_field(2.0, Vector2(20, 20))
	var b := make_field(2.0, Vector2(10, 10), Vector3(20, 0, 20))
	var gen := make_generator()
	var layer := TerrainPaintLayer.new()
	layer.kind = TerrainPaintLayer.PaintKind.HEIGHT_DELTA
	gen.add_child(layer)
	build(gen, [a, b])
	var at := TerrainyAPI.get_fields_at(gen, Vector3(0, 0, 0))
	t.check(at.has(a) and not at.has(b), "fields_at center")
	t.check(TerrainyAPI.get_fields_at(gen, Vector3(20, 0, 20)).has(b), "fields_at second")
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.RAISE, Vector3(-20, 0, 5), 4.0, 1.5)])
	t.check_almost_eq(TerrainyAPI.get_paint_at(gen, layer, Vector3(-20, 0, 5)), 1.5, "paint value", 0.01)
	var aabb := TerrainyAPI.get_painted_region_aabb(gen, [layer])
	t.check(aabb.has_point(Vector3(-20, aabb.position.y + 0.0001, 5)), "painted region AABB covers the stroke")
	t.check(aabb.size.x < 12.0, "painted AABB is stroke sized")

func test_sample_region() -> void:
	var gen := build(make_generator(), [make_field(6.0, Vector2(20, 20))])
	var field := TerrainyAPI.sample_region(gen, Rect2(-10, -10, 20, 20), Vector2i(11, 11))
	t.check_eq(field.heights.size(), 121, "11x11 samples")
	t.check_almost_eq(field.get_height(5, 5), TerrainyAPI.get_height_at(gen, Vector3.ZERO), "center sample")
	t.check(field.world_position(10, 10).is_equal_approx(Vector3(10, field.get_height(10, 10), 10)), "sample positions")
	t.check(field.to_image().get_size() == Vector2i(11, 11), "image export")

func test_rebuild_state_and_settle() -> void:
	var gen := make_generator()
	spawn(gen)
	t.check(TerrainyAPI.is_rebuilding(gen), "rebuild queued after entering the tree")
	t.check(settle(gen), "settles")
	t.check(not TerrainyAPI.is_rebuilding(gen), "settled")
	t.check(gen.has_terrain(), "built by the pumped process loop")
	var diag := TerrainyAPI.get_diagnostics(gen)
	t.check(diag.has("rebuild_id") and diag.has("phases") and diag.has("gpu"), "diagnostics shape")

func test_region_changed_hub_signal() -> void:
	var gen := build(make_generator())
	var hits: Array = []
	var cb := func(tt, aabb): hits.append([tt, aabb])
	TerrainyAPI.signals.region_changed.connect(cb)
	gen.add_child(make_field(3.0, Vector2(6, 6), Vector3(10, 0, 10)))
	gen.rebuild_now()
	TerrainyAPI.signals.region_changed.disconnect(cb)
	t.check_eq(hits.size(), 1, "one dirty region")
	if hits.size() == 1:
		t.check(hits[0][0] == gen, "carries the terrain")
		t.check((hits[0][1] as AABB).has_point(Vector3(10, (hits[0][1] as AABB).position.y + 0.001, 10)), "covers the edit")
