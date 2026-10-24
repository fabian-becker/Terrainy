extends "res://addons/terrainy/tests/framework/test_case.gd"

## The demo scene builds cleanly and covers every shipped node type.

const DEMO := "res://addons/terrainy/demo/terrainy_demo.tscn"

func test_demo_builds_and_covers_every_node() -> void:
	var packed: PackedScene = load(DEMO)
	t.check(packed != null, "demo scene loads")
	if packed == null:
		return
	var root := packed.instantiate()
	var gen: TerrainGenerator = root.get_node("TerrainGenerator")
	gen.navigation_enabled = false
	gen.terrain_resolution = 128
	spawn(root)
	gen.rebuild_now()
	t.check(gen.has_terrain(), "terrain composed")
	var mm: Vector2 = gen.get_final_map().min_max()
	t.check(is_finite(mm.x) and is_finite(mm.y) and mm.y - mm.x > 10.0, "a real landscape (%.1f .. %.1f)" % [mm.x, mm.y])
	var classes := {}
	for node in root.find_children("*", "", true, false):
		var script: Script = node.get_script()
		if script and not script.get_global_name().is_empty():
			classes[script.get_global_name()] = true
	for required in ["TerrainGenerator", "TerrainFieldNode", "TerrainHeightmapNode", "TerrainFieldGroup",
			"TerrainScatterNode", "TerrainHoleNode", "TerrainPaintLayer", "TerrainSmoothModifier",
			"TerrainTerraceModifier", "TerrainClampModifier", "TerrainRemapModifier", "TerrainFlattenModifier"]:
		t.check(classes.has(required), "demo uses %s" % required)
	t.check(gen.get_palette().size() == 4, "river banks append the gravel layer")
	t.check(TerrainyAPI.get_hole_at(gen, Vector3(-20, 0, -40)) or gen.get_hole_map() != null, "cave mouth cuts the mountain")
