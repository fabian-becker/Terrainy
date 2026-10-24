extends "res://addons/terrainy/tests/framework/test_case.gd"

## Core evaluation building blocks: grid, maps, LUTs, corridor raster fast path, blend math.

const TerrainGrid = preload("res://addons/terrainy/gen/eval/terrain_grid.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")
const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const Composer = preload("res://addons/terrainy/gen/eval/composer.gd")
const FieldSnapshot = preload("res://addons/terrainy/gen/eval/field_snapshot.gd")

func test_grid_defaults_give_one_meter_cells() -> void:
	var gen := TerrainGenerator.new()
	t.check_eq(gen.terrain_resolution, 256, "default resolution")
	t.check_almost_eq(gen.terrain_size, 256.0, "default size")
	t.check_eq(gen.chunk_size, 128, "default chunk size")
	var grid := TerrainGrid.new(gen.terrain_resolution, gen.terrain_size, Vector2.ZERO)
	t.check_almost_eq(grid.cell, 1.0, "1 m cells")
	t.check_eq(grid.samples, 257, "samples = cells + 1")
	t.check(grid.world_of(0, 0).is_equal_approx(Vector2(-128, -128)), "corner at -size/2")
	gen.free()

func test_grid_rect_for_world_clamps() -> void:
	var grid := TerrainGrid.new(64, 64.0, Vector2.ZERO)
	var r := grid.rect_for_world(Rect2(-10, -10, 20, 20), 0)
	t.check_eq(r, Rect2i(22, 22, 21, 21), "world rect -> samples")
	t.check_eq(grid.rect_for_world(Rect2(1000, 1000, 5, 5)), Rect2i(), "outside -> empty")
	t.check_eq(grid.rect_for_world(Rect2(-100, -100, 400, 400)), grid.full_rect(), "clamped to grid")

func test_hmap_extract_and_paste_round_trip() -> void:
	var m := HMap.new(Rect2i(0, 0, 8, 8))
	for i in m.data.size():
		m.data[i] = float(i)
	var sub = m.extract(Rect2i(2, 3, 3, 2))
	t.check_eq(sub.data.size(), 6, "extract size")
	t.check_almost_eq(sub.data[0], 3.0 * 8 + 2, "extract first value")
	for i in sub.data.size():
		sub.data[i] = -1.0
	m.paste(sub)
	t.check_almost_eq(m.get_at(2, 3), -1.0, "paste wrote inside")
	t.check_almost_eq(m.get_at(1, 3), 3.0 * 8 + 1, "paste kept outside")
	t.check_eq(m.data.size(), 64, "paste keeps size")
	t.check_almost_eq(m.get_at(7, 7), 63.0, "paste keeps tail")

func test_default_falloff_matches_07_analytic_falloff() -> void:
	var curve := CurveLut.default_falloff()
	var lut := CurveLut.bake(curve)
	var worst := 0.0
	for i in 101:
		var e := float(i) / 100.0
		worst = maxf(worst, absf(CurveLut.sample(lut, e) - CurveLut.analytic_falloff(e)))
	t.check(worst < 0.01, "default falloff curve within 0.01 of 0.7 smoothstep falloff (worst %.4f)" % worst)

func test_corridor_raster_matches_reference() -> void:
	var grid := TerrainGrid.new(48, 48.0, Vector2.ZERO)
	var pts := PackedVector3Array([Vector3(-20, 1, -10), Vector3(0, 3, 5), Vector3(18, 0, 12)])
	var rect := grid.full_rect()
	var raster := Raster.rasterize_polyline(pts, 6.0, grid, rect)
	var dist: PackedFloat32Array = raster["dist"]
	var elev: PackedFloat32Array = raster["elev"]
	var mismatches := 0
	for y in rect.size.y:
		for x in rect.size.x:
			var w: Vector2 = grid.world_of(x, y)
			var ref := Raster.polyline_nearest(pts, w.x, w.y)
			var i := y * rect.size.x + x
			if ref.x < 6.0:
				if absf(dist[i] - ref.x) > 1e-4 or absf(elev[i] - ref.y) > 1e-4:
					mismatches += 1
			elif dist[i] < 6.0:
				mismatches += 1
	t.check_eq(mismatches, 0, "fast corridor raster equals per-sample reference")

func test_blend_modes_match_07_formulas() -> void:
	t.check_almost_eq(Composer.blend_value(2.0, 3.0, 0.5, TerrainTypes.BlendMode.ADD), 3.5, "add")
	t.check_almost_eq(Composer.blend_value(2.0, 3.0, 0.5, TerrainTypes.BlendMode.SUBTRACT), 0.5, "subtract")
	t.check_almost_eq(Composer.blend_value(2.0, 3.0, 0.5, TerrainTypes.BlendMode.MULTIPLY), 2.0 * 2.5, "multiply")
	t.check_almost_eq(Composer.blend_value(2.0, 4.0, 0.5, TerrainTypes.BlendMode.REPLACE), 3.0, "replace")
	t.check_almost_eq(Composer.blend_value(2.0, 4.0, 1.0, TerrainTypes.BlendMode.MAX), 4.0, "max full weight")
	t.check_almost_eq(Composer.blend_value(5.0, 4.0, 1.0, TerrainTypes.BlendMode.MAX), 5.0, "max keeps higher")
	t.check_almost_eq(Composer.blend_value(5.0, 4.0, 1.0, TerrainTypes.BlendMode.MIN), 4.0, "min")
	t.check_almost_eq(Composer.blend_value(2.0, 4.0, 1.0, TerrainTypes.BlendMode.AVERAGE), 3.0, "average")
	t.check_almost_eq(Composer.blend_value(2.0, 4.0, 0.0001, TerrainTypes.BlendMode.AVERAGE), 2.0, "average continuous at edge", 0.001)

## The shared enums live exactly once, in terrain_types.gd. They used to be declared twice — on
## the node and on the snapshot/composer mirroring it — coupled only by ordinal, and a reordered
## member on one side would have silently reinterpreted saved scenes, snapshot payloads and the
## GPU buffer contract. A second local declaration would reintroduce exactly that, so pin the
## count rather than the values.
func test_shared_enums_are_declared_once() -> void:
	for name in ["BlendMode", "DomainKind", "RegionShape", "ElevationOrigin", "Space", "Scope"]:
		t.check_eq(_enum_declarations(name), 1, "enum %s is declared exactly once" % name)

func _enum_declarations(name: String) -> int:
	var re := RegEx.create_from_string("(?m)^enum\\s+%s\\b" % name)
	var count := 0
	var files: Array = []
	_collect_scripts("res://addons/terrainy", files)
	for path in files:
		count += re.search_all(FileAccess.get_file_as_string(path)).size()
	return count

func _collect_scripts(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		_collect_scripts(dir + "/" + d, out)
