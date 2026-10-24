extends "res://addons/terrainy/tests/framework/test_case.gd"

## Per-chunk navigation regions: auto-rebake (debounced), manual bake, hole punching.

func _nav_gen() -> TerrainGenerator:
	return make_generator(64, 64.0, func(g: TerrainGenerator):
		g.navigation_enabled = true
		g.navigation_debounce_ms = 0
		g.use_multithreading = false)

func test_manual_bake_creates_a_region_per_chunk() -> void:
	var gen := build(_nav_gen())
	var baked: Array = []
	gen.navigation_mesh_baked.connect(func(mesh, key): baked.append(key))
	gen.bake_navigation(true)
	t.check_eq(baked.size(), 4, "one bake per chunk")
	var meshes := gen.get_navigation_meshes()
	t.check_eq(meshes.size(), 4, "regions installed")
	var polys := 0
	for m in meshes.values():
		polys += m.get_polygon_count()
	t.check(polys > 0, "navmesh has polygons")

func test_auto_rebake_after_edit_only_touches_dirty_chunks() -> void:
	var gen := build(_nav_gen())
	gen.bake_navigation(true)
	var baked: Array = []
	gen.navigation_mesh_baked.connect(func(mesh, key): baked.append(key))
	gen.add_child(make_field(2.0, Vector2(8, 8), Vector3(-16, 0, -16)))
	gen.rebuild_now()
	settle(gen)
	gen._process(0.0)
	t.check_eq(baked.size(), 1, "only the edited chunk re-baked")

func test_punching_hole_removes_navigable_area() -> void:
	var gen := build(_nav_gen())
	gen.bake_navigation(true)
	var area_before := _nav_area(gen)
	var hole := TerrainHoleNode.new()
	hole.size = Vector3(16, 100, 16)
	hole.punches_navigation = true
	hole.position = Vector3(-16, 0, -16)
	gen.add_child(hole)
	gen.rebuild_now()
	gen.bake_navigation(true)
	t.check(_nav_area(gen) < area_before - 50.0, "navmesh area shrinks by the hole (%.0f -> %.0f)" % [area_before, _nav_area(gen)])

func _nav_area(gen: TerrainGenerator) -> float:
	var area := 0.0
	for mesh in gen.get_navigation_meshes().values():
		var v: PackedVector3Array = mesh.get_vertices()
		for i in mesh.get_polygon_count():
			var p: PackedInt32Array = mesh.get_polygon(i)
			for k in range(1, p.size() - 1):
				area += 0.5 * absf((v[p[k]] - v[p[0]]).cross(v[p[k + 1]] - v[p[0]]).y)
	return area

func test_disabling_navigation_clears_regions() -> void:
	var gen := build(_nav_gen())
	gen.bake_navigation(true)
	gen.navigation_enabled = false
	t.check_eq(gen.get_navigation_meshes().size(), 0, "regions removed")
