extends "res://addons/terrainy/tests/framework/test_case.gd"

## The five modifiers (smooth, terrace, clamp, remap, flatten).

func _ramp_field() -> TerrainFieldNode:
	var f := make_field(30.0, Vector2(60, 60))
	f.region_shape = TerrainTypes.RegionShape.RECTANGLE
	f.domain_falloff = null
	var p := Curve.new()
	p.add_point(Vector2(0, 0))
	p.add_point(Vector2(1, 1))
	f.profile = p
	return f

func test_smooth_reduces_sharp_steps() -> void:
	var f := make_field(10.0, Vector2(20, 20))
	f.region_shape = TerrainTypes.RegionShape.RECTANGLE
	f.domain_falloff = null
	var gen := build(make_generator(), [f])
	var step_before := absf(h_at(gen, 9, 0) - h_at(gen, 10, 0))
	var smooth := TerrainSmoothModifier.new()
	smooth.radius = 3.0
	gen.add_child(smooth)
	gen.rebuild_now()
	var step_after := absf(h_at(gen, 9, 0) - h_at(gen, 10, 0))
	t.check(step_after < step_before * 0.6, "smoothed edge (%.2f -> %.2f)" % [step_before, step_after])
	t.check_almost_eq(h_at(gen, 25, 25), 0.0, "far away unchanged", 0.01)

func test_terrace_quantizes_heights() -> void:
	var f := _ramp_field()
	var terrace := TerrainTerraceModifier.new()
	terrace.step_height = 5.0
	terrace.smoothness = 0.0
	f.add_child(terrace)
	terrace.space = TerrainTypes.Space.LOCAL
	var gen := build(make_generator(), [f])
	for x in [3.0, 9.0, 17.0, 22.0]:
		var h := h_at(gen, x, 0)
		t.check_almost_eq(fmod(h + 0.0001, 5.0), 0.0, "height %.3f on a 5 m step" % h, 0.01)

func test_clamp_and_remap() -> void:
	var f := _ramp_field()
	var remap := TerrainRemapModifier.new()
	remap.input_min = 0.0
	remap.input_max = 30.0
	remap.output_min = 10.0
	remap.output_max = 20.0
	f.add_child(remap)
	remap.space = TerrainTypes.Space.LOCAL
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 0, 0), 20.0, "top remapped", 0.01)
	t.check(h_at(gen, 29, 0) >= 9.99 and h_at(gen, 29, 0) < 11.5, "rim remapped toward 10")
	remap.enabled = false
	var clamp_mod := TerrainClampModifier.new()
	clamp_mod.min_height = 5.0
	clamp_mod.max_height = 25.0
	f.add_child(clamp_mod)
	clamp_mod.space = TerrainTypes.Space.LOCAL
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 25.0, "clamped max")

func test_flatten_target_modes() -> void:
	var f := _ramp_field()
	var flatten := TerrainFlattenModifier.new()
	flatten.footprint_size = Vector2(10, 10)
	flatten.falloff = null
	flatten.position = Vector3(0, 12, 0)
	var gen := build(make_generator(), [f, flatten])
	t.check_almost_eq(h_at(gen, 0, 0), 12.0, "node height target")
	t.check(h_at(gen, 15, 0) > 12.0 and h_at(gen, 15, 0) < 20.0, "outside the footprint untouched")
	flatten.target_mode = TerrainFlattenModifier.TargetMode.ABSOLUTE
	flatten.target_height = 3.0
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 3.0, "absolute target")
	flatten.strength = 0.5
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 16.5, "strength lerps toward the target")

func test_flatten_owner_level() -> void:
	var f := _ramp_field()
	f.position.y = 2.0
	var flatten := TerrainFlattenModifier.new()
	flatten.target_mode = TerrainFlattenModifier.TargetMode.OWNER_LEVEL
	flatten.target_height = 1.0
	flatten.footprint_size = Vector2(8, 8)
	flatten.falloff = null
	f.add_child(flatten)
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 0, 0), 3.0, "owner level (2) + offset (1)")

## The flatten gizmo draws its footprint on the resolved target plane; that plane must match the
## height the modifier actually pulls the terrain toward.
func test_flatten_target_world_y_matches_composed_target() -> void:
	var f := _ramp_field()
	f.position.y = 2.0
	var flatten := TerrainFlattenModifier.new()
	flatten.footprint_size = Vector2(8, 8)
	flatten.falloff = null
	flatten.position = Vector3(0, 12, 0)
	var gen := build(make_generator(64, 64.0,
		func(g: TerrainGenerator): g.base_height = 20.0), [f, flatten])
	t.check_almost_eq(flatten.resolve_target_world_y(), 12.0, "node height is absolute", 1e-4)
	t.check_almost_eq(flatten.resolve_target_height(gen.global_position.y), 12.0,
		"generator-local twin", 1e-4)
	t.check_almost_eq(h_at(gen, 0, 0), 12.0, "composed target matches the plane", 0.05)
	flatten.target_mode = TerrainFlattenModifier.TargetMode.ABSOLUTE
	flatten.target_height = 3.0
	gen.rebuild_now()
	t.check_almost_eq(flatten.resolve_target_world_y(), 3.0, "absolute target", 1e-4)
	t.check_almost_eq(h_at(gen, 0, 0), 3.0, "absolute target composed", 0.05)
	# With no field/group owner the generator's own level is the fallback.
	flatten.target_mode = TerrainFlattenModifier.TargetMode.OWNER_LEVEL
	flatten.target_height = 1.0
	t.check_almost_eq(flatten.resolve_target_world_y(), 1.0, "generator level fallback", 1e-4)
	var owned := TerrainFlattenModifier.new()
	owned.target_mode = TerrainFlattenModifier.TargetMode.OWNER_LEVEL
	owned.target_height = 1.0
	f.add_child(owned)
	t.check_almost_eq(owned.resolve_target_world_y(), 3.0, "owner level (2) + offset (1)", 1e-4)

## Group composites and additive fields' own maps hold deltas over the enclosing composite, but
## a flatten's target height is an absolute world height (the plane its gizmo draws). The
## composer must rebase the target by the composite under the modifier, or the terrain lands a
## whole base height away from the gizmo.
func test_flatten_in_delta_group_targets_world_height() -> void:
	for mode in [TerrainTypes.BlendMode.ADD, TerrainTypes.BlendMode.SUBTRACT]:
		var group := TerrainFieldGroup.new()
		group.blend_mode = mode
		var flatten := TerrainFlattenModifier.new()
		flatten.footprint_size = Vector2(8, 8)
		flatten.falloff = null
		flatten.position = Vector3(0, 25, 0)
		group.add_child(flatten)
		var gen := build(_based_generator(20.0), [group])
		t.check_almost_eq(h_at(gen, 0, 0), 25.0,
			"%s group: composed terrain matches the target plane"
				% TerrainTypes.BlendMode.keys()[mode], 0.05)

## The rebase samples the composite under the modifier, not just base_height.
func test_flatten_in_delta_group_reads_the_enclosing_composite() -> void:
	var hill := TerrainFieldNode.new()
	hill.domain_kind = TerrainTypes.DomainKind.GLOBAL
	hill.profile_height = 10.0
	var group := TerrainFieldGroup.new()
	var flatten := TerrainFlattenModifier.new()
	flatten.footprint_size = Vector2(8, 8)
	flatten.falloff = null
	flatten.position = Vector3(0, 40, 0)
	group.add_child(flatten)
	var gen := build(_based_generator(20.0), [hill, group])
	t.check_almost_eq(h_at(gen, 0, 0), 40.0, "20 (base) + 10 (hill), flattened to 40", 0.05)

## Local-space flatten inside an additive field: the field map is a delta too.
func test_flatten_local_in_additive_field_targets_world_height() -> void:
	var hill := make_field(10.0, Vector2(20, 20))
	var flatten := TerrainFlattenModifier.new()
	flatten.space = TerrainTypes.Space.LOCAL
	flatten.footprint_size = Vector2(8, 8)
	flatten.falloff = null
	flatten.position = Vector3(0, 25, 0)
	hill.add_child(flatten)
	var gen := build(_based_generator(20.0), [hill])
	t.check_almost_eq(h_at(gen, 0, 0), 25.0, "local target is a world height", 0.05)

func _based_generator(base_height: float) -> TerrainGenerator:
	return make_generator(64, 64.0,
		func(g: TerrainGenerator): g.base_height = base_height)

func test_modifier_mask_and_disable() -> void:
	var f := _ramp_field()
	var clamp_mod := TerrainClampModifier.new()
	clamp_mod.use_min = false
	clamp_mod.max_height = 0.0
	var m := TerrainMaskRegion.new()
	m.size = Vector2(6, 6)
	m.falloff = null
	clamp_mod.mask = m
	var gen := build(make_generator(), [f, clamp_mod])
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "masked clamp acts inside its mask")
	t.check(h_at(gen, 10, 0) > 15.0, "outside the mask untouched")
	clamp_mod.enabled = false
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 30.0, "disabled modifier")
