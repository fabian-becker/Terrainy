extends "res://addons/terrainy/tests/framework/test_case.gd"

## TerrainHeightmapNode: external heightmaps as terrain base or blend layer.

func _global_hm() -> TerrainHeightmapNode:
	var hm := TerrainHeightmapNode.new()
	hm.domain_kind = TerrainTypes.DomainKind.GLOBAL
	hm.blend_mode = TerrainTypes.BlendMode.REPLACE
	return hm

func _source(size: int = 65) -> Image:
	return make_ramp_image(Vector2i(size, size), 1.0)

func test_global_heightmap_maps_normalized_values() -> void:
	var hm := _global_hm()
	hm.source_texture = ImageTexture.create_from_image(_source())
	hm.elevation_min = 10.0
	hm.elevation_max = 20.0
	var gen := build(make_generator(), [hm])
	t.check_almost_eq(h_at(gen, -32, -32), 10.0, "min corner", 0.05)
	t.check_almost_eq(h_at(gen, 32, 32), 20.0, "max corner", 0.05)
	t.check_almost_eq(h_at(gen, 0, 0), 15.0, "center", 0.1)

func test_heightmap_round_trip_through_exr() -> void:
	var gen := build(make_generator())
	var src := make_ramp_image(Vector2i(65, 65), 12.0)
	var path := "user://terrainy_test_heightmap.exr"
	t.check_eq(src.save_exr(path, true), OK, "exr written")
	var hm := _global_hm()
	hm.source_path = path
	hm.value_mode = 1
	gen.add_child(hm)
	gen.rebuild_now()
	var worst := 0.0
	for y in [0, 16, 40, 64]:
		for x in [0, 8, 33, 64]:
			worst = maxf(worst, absf(gen.get_final_map().get_at(x, y) - src.get_pixel(x, y).r))
	t.check(worst < 0.01, "meters round trip within 1 cm (worst %.5f)" % worst)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_region_heightmap_blends_with_falloff_and_mask() -> void:
	var hm := TerrainHeightmapNode.new()
	hm.source_texture = ImageTexture.create_from_image(make_flat_image(Vector2i(16, 16), 1.0))
	hm.domain_kind = TerrainTypes.DomainKind.REGION
	hm.region_shape = TerrainTypes.RegionShape.RECTANGLE
	hm.region_size = Vector2(20, 20)
	hm.domain_falloff = null
	hm.blend_mode = TerrainTypes.BlendMode.ADD
	hm.elevation_max = 8.0
	var gen := build(make_generator(), [hm])
	t.check_almost_eq(h_at(gen, 0, 0), 8.0, "inside the footprint")
	t.check_almost_eq(h_at(gen, 20, 0), 0.0, "outside")

func test_missing_source_diagnostics() -> void:
	var hm := _global_hm()
	t.check(hm.get_source_diagnostic().contains("No heightmap"), "no source reported")
	hm.source_path = "res://does/not/exist.exr"
	t.check(hm.get_source_diagnostic().contains("could not be loaded"), "unloadable source reported")
	var gen := build(make_generator(), [hm])
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "a missing source contributes nothing")

func test_source_change_invalidates_signature() -> void:
	var hm := _global_hm()
	hm.source_texture = ImageTexture.create_from_image(make_flat_image(Vector2i(8, 8), 0.5))
	hm.elevation_max = 10.0
	var gen := build(make_generator(), [hm])
	t.check_almost_eq(h_at(gen, 0, 0), 5.0, "first source")
	hm.source_texture = ImageTexture.create_from_image(make_flat_image(Vector2i(8, 8), 0.25))
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 2.5, "new source recomposed")

func test_explicit_values_survive_save_and_load() -> void:
	# Regression: defaults must not be changed in _init(), or values equal to the declared
	# default are not serialized and the _init() value wins on load.
	var root := Node3D.new()
	var hm := TerrainHeightmapNode.new()
	hm.name = "HM"
	hm.domain_kind = TerrainTypes.DomainKind.REGION
	hm.blend_mode = TerrainTypes.BlendMode.ADD
	var f := TerrainFieldNode.new()
	f.name = "F"
	f.domain_falloff = null
	var r := TerrainReliefSource.new()
	f.relief_layers = [r]
	var flat := TerrainFlattenModifier.new()
	flat.name = "Flat"
	flat.falloff = null
	for n in [hm, f, flat]:
		root.add_child(n)
		n.owner = root
	var packed := PackedScene.new()
	t.check_eq(packed.pack(root), OK, "packed")
	root.free()
	var copy := packed.instantiate()
	t.check_eq(copy.get_node("HM").domain_kind, TerrainTypes.DomainKind.REGION, "heightmap domain kept")
	t.check_eq(copy.get_node("HM").blend_mode, TerrainTypes.BlendMode.ADD, "heightmap blend kept")
	t.check(copy.get_node("F").domain_falloff == null, "hard-edge (null) falloff kept")
	t.check(copy.get_node("F").relief_layers[0].noise != null, "relief noise kept")
	t.check(copy.get_node("Flat").falloff == null, "flatten null falloff kept")
	var fresh := TerrainFieldNode.new()
	t.check(fresh.domain_falloff != null, "fresh field still gets the 0.7-shaped falloff")
	fresh.free()
	copy.free()
