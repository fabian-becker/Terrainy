extends "res://addons/terrainy/tests/framework/test_case.gd"

## Masks as data resources: Region, Texture, Path, Slope, Elevation, Paint.

func _global(height: float) -> TerrainFieldNode:
	var f := TerrainFieldNode.new()
	f.domain_kind = TerrainTypes.DomainKind.GLOBAL
	f.profile_height = height
	return f

func test_region_mask_limits_a_global_field() -> void:
	var f := _global(5.0)
	var m := TerrainMaskRegion.new()
	m.size = Vector2(20, 20)
	m.falloff = null
	f.mask = m
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 0, 0), 5.0, "inside the mask")
	t.check_almost_eq(h_at(gen, 20, 0), 0.0, "outside the mask")
	m.invert = true
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "inverted inside")
	t.check_almost_eq(h_at(gen, 20, 0), 5.0, "inverted outside")

func test_region_mask_moves_with_owner() -> void:
	var f := make_field(5.0, Vector2(64, 64))
	f.domain_falloff = null
	var m := TerrainMaskRegion.new()
	m.size = Vector2(10, 10)
	m.falloff = null
	f.mask = m
	var gen := build(make_generator(), [f])
	f.position = Vector3(10, 0, 0)
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 10, 0), 5.0, "mask follows the field")
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "old spot unmasked")

func test_texture_mask_uses_red_channel() -> void:
	var img := Image.create(2, 1, false, Image.FORMAT_RGB8)
	img.set_pixel(0, 0, Color(0, 0, 0))
	img.set_pixel(1, 0, Color(1, 0, 0))
	var m := TerrainMaskTexture.new()
	m.texture = ImageTexture.create_from_image(img)
	m.size = Vector2(40, 40)
	var f := _global(4.0)
	f.mask = m
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, -19, 0), 0.0, "black side", 0.3)
	t.check_almost_eq(h_at(gen, 19, 0), 4.0, "red side", 0.3)
	t.check_almost_eq(h_at(gen, 30, 0), 0.0, "outside the texture rect")

func test_path_mask_shares_the_corridor_curve() -> void:
	var road := TerrainFieldNode.new()
	road.domain_kind = TerrainTypes.DomainKind.CORRIDOR
	road.domain_width = 6.0
	road.profile_height = -1.0
	road.domain_falloff = null
	var path := Path3D.new()
	path.name = "Route"
	path.curve = Curve3D.new()
	path.curve.add_point(Vector3(-30, 0, 0))
	path.curve.add_point(Vector3(30, 0, 0))
	road.add_child(path)
	var banks := _global(2.0)
	var m := TerrainMaskPath.new()
	m.curve = path.curve
	m.relative_to_owner = false
	m.width = 16.0
	m.falloff = null
	banks.mask = m
	var gen := build(make_generator(), [banks, road])
	t.check_almost_eq(h_at(gen, 0, 0), 1.0, "banks + road on the center line")
	t.check_almost_eq(h_at(gen, 0, 6), 2.0, "banks beside the road")
	t.check_almost_eq(h_at(gen, 0, 12), 0.0, "outside the path mask")

func test_slope_mask_flattens_only_steep_parts() -> void:
	var ramp := make_field(30.0, Vector2(40, 40))
	ramp.region_shape = TerrainTypes.RegionShape.RECTANGLE
	ramp.domain_falloff = null
	var p := Curve.new()
	p.add_point(Vector2(0, 0), 0, 0)
	p.add_point(Vector2(1, 1), 0, 0)
	ramp.profile = p
	var flatten := TerrainFlattenModifier.new()
	flatten.target_mode = TerrainFlattenModifier.TargetMode.ABSOLUTE
	flatten.target_height = 0.0
	flatten.footprint_size = Vector2(64, 64)
	flatten.footprint_shape = 2
	flatten.falloff = null
	var steep := TerrainMaskSlope.new()
	steep.min_degrees = 60.0
	steep.max_degrees = 90.0
	steep.softness_degrees = 0.0
	flatten.mask = steep
	var gen := build(make_generator(), [ramp, flatten])
	t.check(h_at(gen, 0, 0) > 25.0, "flat top of the pyramid kept")
	t.check_almost_eq(h_at(gen, 25, 25), 0.0, "flat surroundings kept")

func test_elevation_mask_band() -> void:
	var hill := make_field(20.0, Vector2(60, 60))
	var p := Curve.new()
	p.add_point(Vector2(0, 0))
	p.add_point(Vector2(1, 1))
	hill.profile = p
	hill.domain_falloff = null
	var clamp_mod := TerrainClampModifier.new()
	clamp_mod.use_min = false
	clamp_mod.max_height = 0.0
	var band := TerrainMaskElevation.new()
	band.min_height = 15.0
	band.max_height = 100.0
	band.softness = 0.0
	clamp_mod.mask = band
	var gen := build(make_generator(), [hill, clamp_mod])
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "summit (above 15 m) clamped")
	t.check(h_at(gen, 12, 0) > 5.0, "lower slopes untouched")

func test_paint_mask_gates_a_field() -> void:
	var gen := make_generator()
	var layer := TerrainPaintLayer.new()
	layer.name = "Meadow"
	layer.kind = TerrainPaintLayer.PaintKind.MASK
	gen.add_child(layer)
	var f := _global(3.0)
	var m := TerrainMaskPaint.new()
	m.layer_name = "Meadow"
	f.mask = m
	build(gen, [f])
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "unpainted mask = 0")
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.MASK, Vector3.ZERO, 6.0, 1.0)])
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 3.0, "painted mask lets the field act", 0.05)
	t.check_almost_eq(h_at(gen, 20, 0), 0.0, "outside the stroke")
