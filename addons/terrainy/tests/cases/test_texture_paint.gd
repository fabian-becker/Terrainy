extends "res://addons/terrainy/tests/framework/test_case.gd"

## Stage 6: surface contributions + TEXTURE paint layers -> per-layer R8 weight planes.

func _layer(name: String) -> TerrainyTextureLayer:
	var l := TerrainyTextureLayer.new()
	l.layer_name = name
	return l

func _plane_value(gen: TerrainGenerator, index: int, x: float, z: float) -> float:
	var planes := gen.get_weight_planes()
	var img: Image = planes["claims"][index]
	var w := gen.get_terrain_world_rect()
	var s := img.get_size()
	var px := Vector2i(clampi(int((x - w.position.x) / w.size.x * s.x), 0, s.x - 1), clampi(int((z - w.position.y) / w.size.y * s.y), 0, s.y - 1))
	return img.get_pixelv(px).r

func test_one_r8_weight_plane_per_palette_layer() -> void:
	var gen := make_generator(64, 64.0, func(g: TerrainGenerator): g.texture_layers = [_layer("grass"), _layer("rock")])
	build(gen)
	var planes := gen.get_weight_planes()
	t.check_eq((planes["claims"] as Array).size(), 2, "one plane per layer")
	t.check_eq((planes["claims"][0] as Image).get_format(), Image.FORMAT_R8, "R8 planes")
	t.check(not planes["has_claims"], "no claims without contributions / paint")

func test_contribution_claims_follow_the_field_weight() -> void:
	var gravel := _layer("gravel")
	var f := make_field(0.0, Vector2(20, 20))
	f.domain_falloff = null
	var c := TerrainySurfaceContribution.new()
	c.texture_layer = gravel
	f.surface_contributions = [c]
	var gen := make_generator(64, 64.0, func(g: TerrainGenerator): g.texture_layers = [_layer("grass")])
	build(gen, [f])
	t.check_eq(gen.get_palette().size(), 2, "contribution-owned layer appended to the palette")
	t.check_almost_eq(_plane_value(gen, 1, 0, 0), 1.0, "claimed inside the field", 0.01)
	t.check_almost_eq(_plane_value(gen, 1, 25, 25), 0.0, "not outside")
	var blend := TerrainyAPI.get_texture_blend_at(gen, Vector3(0, 0, 0))
	t.check_almost_eq(blend[1], 1.0, "API: gravel takes over inside", 0.01)
	blend = TerrainyAPI.get_texture_blend_at(gen, Vector3(25, 0, 25))
	t.check_almost_eq(blend[0], 1.0, "API: grass outside", 0.01)

func test_texture_paint_wins_over_contributions() -> void:
	var grass := _layer("grass")
	var sand := _layer("sand")
	var f := make_field(0.0, Vector2(40, 40))
	f.domain_falloff = null
	var c := TerrainySurfaceContribution.new()
	c.texture_layer = sand
	f.surface_contributions = [c]
	var gen := make_generator(64, 64.0, func(g: TerrainGenerator): g.texture_layers = [grass, sand])
	var paint := TerrainPaintLayer.new()
	paint.kind = TerrainPaintLayer.PaintKind.TEXTURE
	paint.texture_layer_index = 0
	gen.add_child(paint)
	build(gen, [f])
	t.check_almost_eq(_plane_value(gen, 1, 5, 5), 1.0, "sand claimed by the contribution", 0.01)
	gen.paint_stamps(paint, [stamp(BrushStamp.StrokeOp.TEXTURE, Vector3(5, 0, 5), 4.0, 1.0)])
	t.check_eq((gen.get_weight_planes()["claims"][0] as Image).get_width(), gen.paint_layer_grid, "planes switch to the paint grid")
	t.check_almost_eq(_plane_value(gen, 0, 5, 5), 1.0, "painted grass wins", 0.01)
	t.check_almost_eq(_plane_value(gen, 1, 5, 5), 0.0, "sand claim removed where painted", 0.01)
	t.check_almost_eq(_plane_value(gen, 1, -10, -10), 1.0, "sand kept elsewhere", 0.01)
	# A full recompose reproduces the same planes.
	gen.force_rebuild()
	gen.rebuild_now()
	t.check_almost_eq(_plane_value(gen, 0, 5, 5), 1.0, "recomposed planes keep the paint", 0.01)

func test_erase_texture_paint() -> void:
	var gen := make_generator(64, 64.0, func(g: TerrainGenerator): g.texture_layers = [_layer("a"), _layer("b")])
	var paint := TerrainPaintLayer.new()
	paint.kind = TerrainPaintLayer.PaintKind.TEXTURE
	paint.texture_layer_index = 1
	gen.add_child(paint)
	build(gen)
	gen.paint_stamps(paint, [stamp(BrushStamp.StrokeOp.TEXTURE, Vector3.ZERO, 5.0, 1.0)])
	t.check_almost_eq(_plane_value(gen, 1, 0, 0), 1.0, "painted", 0.01)
	var erase = stamp(BrushStamp.StrokeOp.TEXTURE, Vector3.ZERO, 5.0, 1.0)
	erase.erase = true
	gen.paint_stamps(paint, [erase])
	t.check_almost_eq(_plane_value(gen, 1, 0, 0), 0.0, "erased", 0.01)
