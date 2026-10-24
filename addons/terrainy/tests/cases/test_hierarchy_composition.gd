extends "res://addons/terrainy/tests/framework/test_case.gd"

## Scene tree = composition structure: sibling order, Local / Group / Global spaces, groups,
## Independent scope, isolate preview, space in the signature.

func _global(height: float) -> TerrainFieldNode:
	var f := TerrainFieldNode.new()
	f.domain_kind = TerrainTypes.DomainKind.GLOBAL
	f.profile_height = height
	return f

func _flat(height: float, size: Vector2, pos: Vector3 = Vector3.ZERO) -> TerrainFieldNode:
	var f := make_field(height, size, pos)
	f.domain_falloff = null
	return f

func test_local_child_shapes_only_its_parent() -> void:
	var mountain := _flat(10.0, Vector2(20, 20))
	var bump := _flat(5.0, Vector2(60, 60))
	bump.space = TerrainTypes.Space.LOCAL
	mountain.add_child(bump)
	var gen := build(make_generator(), [mountain])
	t.check_almost_eq(h_at(gen, 0, 0), 15.0, "child adds inside the parent")
	t.check_almost_eq(h_at(gen, 20, 0), 0.0, "child does not act outside the parent's domain")

func test_group_space_child_acts_on_the_composite() -> void:
	var mountain := _flat(10.0, Vector2(20, 20))
	var bump := _flat(5.0, Vector2(60, 60))
	bump.space = TerrainTypes.Space.GROUP
	mountain.add_child(bump)
	var gen := build(make_generator(), [mountain])
	t.check_almost_eq(h_at(gen, 0, 0), 15.0, "on the mountain")
	t.check_almost_eq(h_at(gen, 20, 0), 5.0, "also beside it (siblings interfere at group level)")

func test_local_modifier_vs_group_modifier() -> void:
	var base := _global(20.0)
	var hill := _flat(10.0, Vector2(20, 20))
	var clamp_mod := TerrainClampModifier.new()
	clamp_mod.use_min = false
	clamp_mod.max_height = 4.0
	clamp_mod.space = TerrainTypes.Space.LOCAL
	hill.add_child(clamp_mod)
	var gen := build(make_generator(), [base, hill])
	t.check_almost_eq(h_at(gen, 0, 0), 24.0, "local clamp limits the hill's own map (20 + 4)")
	t.check_almost_eq(h_at(gen, 20, 20), 20.0, "base untouched")
	clamp_mod.space = TerrainTypes.Space.GROUP
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 4.0, "group clamp limits the composite")
	t.check_almost_eq(h_at(gen, 20, 20), 4.0, "everywhere")

func test_global_space_runs_after_everything_in_scene_order() -> void:
	var lake := _flat(1.0, Vector2(20, 20))
	lake.space = TerrainTypes.Space.GLOBAL
	lake.blend_mode = TerrainTypes.BlendMode.MIN
	var later := _global(8.0)
	# lake comes first in the tree, but as a Global unit it runs after the composite is final.
	var gen := build(make_generator(), [lake, later])
	t.check_almost_eq(h_at(gen, 0, 0), 1.0, "global MIN carves against the final elevation")
	t.check_almost_eq(h_at(gen, 25, 25), 8.0, "outside the lake")
	lake.space = TerrainTypes.Space.GROUP
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 8.0, "as a group unit it runs first: min(0, 1) = 0, then +8")

func test_nested_global_unit_is_hoisted_to_the_post_pass() -> void:
	var parent := _flat(5.0, Vector2(30, 30))
	var g := TerrainClampModifier.new()
	g.use_min = false
	g.max_height = 2.0
	g.space = TerrainTypes.Space.GLOBAL
	parent.add_child(g)
	var after := _global(1.0)
	var gen := build(make_generator(), [parent, after])
	t.check_almost_eq(h_at(gen, 0, 0), 2.0, "global clamp nested under a field applies to the final terrain")

func test_group_composes_children_and_blends_with_coverage() -> void:
	var base := _global(3.0)
	var group := TerrainFieldGroup.new()
	var a := _flat(4.0, Vector2(10, 10), Vector3(-10, 0, 0))
	var b := _flat(6.0, Vector2(10, 10), Vector3(10, 0, 0))
	group.add_child(a)
	group.add_child(b)
	group.blend_mode = TerrainTypes.BlendMode.REPLACE
	var gen := build(make_generator(), [base, group])
	t.check_almost_eq(h_at(gen, -10, 0), 4.0, "group replace on child a's coverage")
	t.check_almost_eq(h_at(gen, 10, 0), 6.0, "child b")
	t.check_almost_eq(h_at(gen, 0, 20), 3.0, "outside the children's coverage the terrain is kept")
	t.check(group.get_influence_bounds().size.x >= 29.0, "bounds union of the children")

func test_independent_group_is_excluded_unless_isolated() -> void:
	var group := TerrainFieldGroup.new()
	group.scope = TerrainTypes.Scope.INDEPENDENT
	group.add_child(_flat(4.0, Vector2(20, 20)))
	var other := _flat(2.0, Vector2(10, 10), Vector3(20, 0, 20))
	var gen := build(make_generator(), [group, other])
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "independent group excluded")
	gen.preview_isolate_node = group
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 4.0, "isolated: the group is composed")
	t.check_almost_eq(h_at(gen, 20, 20), 0.0, "everything else previewed flat")
	gen.preview_isolate_node = null
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 20, 20), 2.0, "isolation cleared")

func test_group_space_inside_group_reads_the_group_composite() -> void:
	var outer := _global(10.0)
	var group := TerrainFieldGroup.new()
	var field := _flat(3.0, Vector2(20, 20))
	var clamp_mod := TerrainClampModifier.new()
	clamp_mod.use_min = false
	clamp_mod.max_height = 1.0
	field.add_child(clamp_mod)  # Group space: clamps the GROUP composite (0..3), not the terrain
	group.add_child(field)
	var gen := build(make_generator(), [outer, group])
	t.check_almost_eq(h_at(gen, 0, 0), 11.0, "10 + group(min(3, 1))")

func test_organisational_nodes_are_transparent() -> void:
	var folder := Node3D.new()
	folder.add_child(_flat(4.0, Vector2(20, 20)))
	var gen := build(make_generator(), [folder])
	t.check_almost_eq(h_at(gen, 0, 0), 4.0, "field under a plain Node3D still composes")

func test_space_joins_the_signature() -> void:
	var a := _flat(3.0, Vector2(20, 20))
	var b := _flat(2.0, Vector2(40, 40))
	a.add_child(b)
	var gen := build(make_generator(), [a])
	var before: int = gen.get_diagnostics()["counters"].get("compose_reused", 0)
	b.space = TerrainTypes.Space.LOCAL
	gen.rebuild_now()
	t.check_eq(gen.get_diagnostics()["counters"].get("compose_reused", 0), before, "space change recomposes")
	t.check_almost_eq(h_at(gen, 15, 0), 0.0, "local child no longer acts outside the parent")
