extends "res://addons/terrainy/tests/framework/test_case.gd"

## Domain x profile x relief x blend matrix of TerrainFieldNode (replaces the 0.x primitive /
## landscape cases), plus determinism and signature caching.

const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")

func _dome() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, 0), 0, 0)
	c.add_point(Vector2(1, 1), 0, 0)
	return c

func test_empty_generator_is_flat_at_base_height() -> void:
	var gen := build(make_generator(32, 32.0, func(g: TerrainGenerator): g.base_height = 3.0))
	t.check(gen.has_terrain(), "terrain composed")
	t.check_almost_eq(h_at(gen, 0, 0), 3.0, "base height at center")
	t.check_almost_eq(h_at(gen, 15, -15), 3.0, "base height at corner")
	t.check_eq(gen.get_chunk_manager().chunks.size(), 1, "32 cells / 32 per chunk = 1 chunk")

func test_region_field_flat_profile_raises_area_with_default_falloff() -> void:
	var f := make_field(10.0, Vector2(40, 40))
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 0, 0), 10.0, "full height at center")
	t.check_almost_eq(h_at(gen, 30, 30), 0.0, "zero outside the domain")
	# e = 1 - d; at d = 0.85 (17 m of 20 m radius) e = 0.15 -> 0.7 falloff smoothstep(0.5) = 0.5
	t.check_almost_eq(h_at(gen, 17, 0), 10.0 * CurveLut.analytic_falloff(0.15), "0.7 falloff shape at the edge", 0.15)

func test_profile_curve_shapes_cross_section() -> void:
	var f := make_field(20.0, Vector2(40, 40))
	f.profile = _dome()
	f.domain_falloff = null
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 0, 0), 20.0, "profile(1) at center")
	t.check_almost_eq(h_at(gen, 10, 0), 20.0 * f.sample_profile(0.5), "profile(0.5) half way", 0.05)
	t.check(h_at(gen, 10, 0) < h_at(gen, 5, 0), "decreasing toward the edge")

func test_shapes_and_rotation() -> void:
	var f := make_field(5.0, Vector2(40, 8))
	f.region_shape = TerrainTypes.RegionShape.RECTANGLE
	f.domain_falloff = null
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 18, 0), 5.0, "inside along X")
	t.check_almost_eq(h_at(gen, 0, 10), 0.0, "outside along Z")
	f.rotation.y = PI * 0.5
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 18), 5.0, "rotated: inside along Z", 0.01)
	t.check_almost_eq(h_at(gen, 18, 0), 0.0, "rotated: outside along X")

func test_global_domain_covers_everything() -> void:
	var f := TerrainFieldNode.new()
	f.domain_kind = TerrainTypes.DomainKind.GLOBAL
	f.profile_height = 2.5
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, -31, -31), 2.5, "corner")
	t.check_almost_eq(h_at(gen, 20, -5), 2.5, "anywhere")

func test_blend_modes_in_scene_order() -> void:
	var base := TerrainFieldNode.new()
	base.domain_kind = TerrainTypes.DomainKind.GLOBAL
	base.profile_height = 4.0
	var cap := make_field(2.0, Vector2(30, 30))
	cap.domain_falloff = null
	cap.blend_mode = TerrainTypes.BlendMode.REPLACE
	var gen := build(make_generator(), [base, cap])
	t.check_almost_eq(h_at(gen, 0, 0), 2.0, "replace pins to the field height")
	cap.blend_mode = TerrainTypes.BlendMode.MAX
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 4.0, "max keeps the higher terrain")
	cap.blend_mode = TerrainTypes.BlendMode.SUBTRACT
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 2.0, "subtract")
	# Order matters: move the cap before the base -> base adds on top of the replaced value.
	cap.blend_mode = TerrainTypes.BlendMode.REPLACE
	gen.move_child(cap, 0)
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 6.0, "reordering children reorders the composition")

func test_elevation_origins() -> void:
	var f := make_field(0.0, Vector2(30, 30), Vector3(0, 7, 0))
	f.domain_falloff = null
	f.blend_mode = TerrainTypes.BlendMode.REPLACE
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 0, 0), 7.0, "Local: field sits at node height")
	f.elevation_origin = TerrainTypes.ElevationOrigin.WORLD
	f.profile_offset = 3.0
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 3.0, "World: pinned to absolute elevation")
	gen.position.y = 1.0
	gen.rebuild_now()
	t.check_almost_eq(gen.get_height_at(Vector3(0, 0, 0)), 3.0, "World origin is independent of the generator height")

## The editor gizmos draw at `elevation_anchor_world_y()`, so it has to equal the elevation the
## evaluator actually starts the profile from in every elevation-origin / blend-mode combination.
func test_elevation_anchor_matches_composed_surface() -> void:
	var f := make_field(10.0, Vector2(30, 30), Vector3(0, 7, 0))
	f.domain_falloff = null
	var gen := build(make_generator(64, 64.0,
		func(g: TerrainGenerator): g.base_height = 48.0), [f])
	# LOCAL + ADD: additive blends sit on the composite datum.
	t.check_almost_eq(f.elevation_anchor_world_y(), 55.0, "local additive anchor", 1e-4)
	t.check_almost_eq(h_at(gen, 0, 0), f.elevation_anchor_world_y() + f.profile_height,
		"surface is anchor + profile", 0.05)
	# LOCAL + REPLACE: target blends set an absolute level and ignore base_height.
	f.blend_mode = TerrainTypes.BlendMode.REPLACE
	gen.rebuild_now()
	t.check_almost_eq(f.elevation_anchor_world_y(), 7.0, "local target anchor", 1e-4)
	t.check_almost_eq(h_at(gen, 0, 0), 17.0, "replace target = anchor + profile", 0.05)
	# WORLD pins the profile in absolute world elevation.
	f.elevation_origin = TerrainTypes.ElevationOrigin.WORLD
	f.profile_offset = 3.0
	gen.rebuild_now()
	t.check_almost_eq(f.elevation_anchor_world_y(), 3.0, "world target anchor", 1e-4)
	t.check_almost_eq(h_at(gen, 0, 0), 13.0, "world target = anchor + profile", 0.05)
	f.blend_mode = TerrainTypes.BlendMode.ADD
	gen.rebuild_now()
	t.check_almost_eq(f.elevation_anchor_world_y(), 51.0, "world additive anchor sits on the datum", 1e-4)
	t.check_almost_eq(h_at(gen, 0, 0), 61.0, "world additive = anchor + profile", 0.05)

func test_blend_modes_classify_as_delta_or_target() -> void:
	for mode in [TerrainTypes.BlendMode.ADD, TerrainTypes.BlendMode.SUBTRACT]:
		t.check(TerrainTypes.is_delta_blend(mode), "delta blend %d" % mode)
		t.check(TerrainTypes.has_elevation(mode), "delta blend %d is in meters" % mode)
	for mode in [TerrainTypes.BlendMode.MAX, TerrainTypes.BlendMode.MIN,
			TerrainTypes.BlendMode.AVERAGE, TerrainTypes.BlendMode.REPLACE]:
		t.check(not TerrainTypes.is_delta_blend(mode), "target blend %d" % mode)
		t.check(TerrainTypes.has_elevation(mode), "target blend %d is in meters" % mode)
	t.check(not TerrainTypes.has_elevation(TerrainTypes.BlendMode.MULTIPLY),
		"multiply is a factor, not an elevation")

func test_relief_adds_deterministic_noise() -> void:
	var f := TerrainFieldNode.new()
	f.domain_kind = TerrainTypes.DomainKind.GLOBAL
	f.profile_height = 0.0
	var r := TerrainReliefSource.new()
	r.weight = 5.0
	f.relief_layers = [r]
	var gen := build(make_generator(), [f])
	var a := h_at(gen, 3.3, 7.1)
	var mm: Vector2 = gen.get_final_map().min_max()
	t.check(mm.y - mm.x > 0.5, "noise produces variation")
	t.check(mm.x >= -5.01 and mm.y <= 5.01, "bounded by the weight")
	gen.force_rebuild()
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 3.3, 7.1), a, "deterministic recomposition", 1e-5)
	gen.noise_seed = 99
	gen.rebuild_now()
	t.check(absf(h_at(gen, 3.3, 7.1) - a) > 1e-4, "generator seed changes relief")

func test_relief_anisotropic_scale_and_follow_profile() -> void:
	var f := make_field(0.0, Vector2(50, 50))
	f.domain_falloff = null
	var r := TerrainReliefSource.new()
	r.weight = 4.0
	r.scale = Vector2(8.0, 1.0)
	r.follow_profile = true
	f.relief_layers = [r]
	var p := Curve.new()
	p.add_point(Vector2(0, 0))
	p.add_point(Vector2(1, 1))
	f.profile = p
	var gen := build(make_generator(), [f])
	# Variation along local X (stretched) is much smaller than along Z.
	var dx := 0.0
	var dz := 0.0
	for i in 10:
		dx += absf(h_at(gen, i * 0.5, 0) - h_at(gen, i * 0.5 + 0.5, 0))
		dz += absf(h_at(gen, 0, i * 0.5) - h_at(gen, 0, i * 0.5 + 0.5))
	t.check(dx < dz, "anisotropic scale stretches features along X (%.3f < %.3f)" % [dx, dz])

func test_strength_and_disable() -> void:
	var f := make_field(10.0, Vector2(30, 30))
	f.strength = 0.5
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 0, 0), 5.0, "strength scales the add")
	f.enabled = false
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "disabled field drops out")
	f.enabled = true
	f.visible = false
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "hidden field drops out")

func test_signature_caching_reevaluates_only_changed_field() -> void:
	var a := make_field(5.0, Vector2(20, 20), Vector3(-15, 0, 0))
	var b := make_field(5.0, Vector2(20, 20), Vector3(15, 0, 0))
	var gen := build(make_generator(), [a, b])
	b.profile_height = 8.0
	gen.rebuild_now()
	var stats: Dictionary = gen.get_diagnostics()["stats"]
	t.check_eq(stats["evaluated"], 1, "only the edited field is evaluated")
	t.check_eq(stats["reused"], 1, "the other field replays its cache")
	t.check_almost_eq(h_at(gen, 15, 0), 8.0, "edit applied")

func test_unchanged_rebuild_reuses_composition() -> void:
	var gen := build(make_generator(), [make_field()])
	var before: int = gen.get_diagnostics()["counters"].get("compose_reused", 0)
	gen.rebuild_now()
	t.check_eq(gen.get_diagnostics()["counters"].get("compose_reused", 0), before + 1, "no-op rebuild skips composition")

func test_moving_a_field_only_rebuilds_affected_chunks() -> void:
	var f := make_field(6.0, Vector2(12, 12), Vector3(-16, 0, -16))
	var gen := build(make_generator(), [f])
	t.check_eq(gen.get_chunk_manager().chunks.size(), 4, "2x2 chunks")
	var applied: Array = []
	gen.terrain_region_updated.connect(func(aabb): applied.append(aabb))
	f.position = Vector3(-14, 0, -16)
	gen.rebuild_now()
	t.check_eq(applied.size(), 1, "only the chunk under the field rebuilt")


func test_resolution_change_reuses_no_old_grid_evaluations() -> void:
	var gen := build(make_generator(64, 64.0), [make_field(10.0, Vector2(32, 32))])
	t.check_almost_eq(h_at(gen, 0, 0), 10.0, "peak at the world center")
	gen.terrain_resolution = 32
	gen.rebuild_now()
	t.check_eq(gen.get_grid().samples, 33, "grid rebuilt at the new resolution")
	t.check_almost_eq(h_at(gen, 0, 0), 10.0, "field still peaks at the world center")
	t.check_almost_eq(h_at(gen, 30, 30), 0.0, "field still ends at the same world edge")

func test_chunk_resolution_change_rebuilds_meshes_without_recompose() -> void:
	var gen := build(make_generator(64, 64.0), [make_field(5.0, Vector2(40, 40))])
	var chunk = gen.get_chunk_manager().chunks.values()[0]
	var before: int = (chunk.mesh_instance.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	var reused: int = gen.get_diagnostics()["counters"].get("compose_reused", 0)
	gen.chunk_resolution = 16
	gen.rebuild_now()
	var after: int = (chunk.mesh_instance.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	t.check_eq(gen.get_diagnostics()["counters"].get("compose_reused", 0), reused + 1, "composition reused")
	t.check(after < before, "mesh resolution dropped (%d -> %d vertices)" % [before, after])
