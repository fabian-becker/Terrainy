extends "res://addons/terrainy/tests/framework/test_case.gd"

## Bake to scene: static meshes + collision + navigation + scatter, round-trip stable.

func test_bake_round_trip() -> void:
	var s := TerrainScatterNode.new()
	s.mesh = BoxMesh.new()
	s.density = 1.0
	# A plain material keeps the baked file small (the auto material embeds texture arrays,
	# which the headless dummy renderer cannot read back).
	var gen := build(make_generator(64, 64.0, func(g: TerrainGenerator): g.custom_material = StandardMaterial3D.new()), [make_field(5.0, Vector2(30, 30)), s])
	var path := "user://terrainy_bake_test.tscn"
	t.check_eq(gen.bake_to_scene(path), OK, "baked")
	var packed: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	t.check(packed != null, "baked scene loads")
	var root := packed.instantiate()
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	var shapes := root.find_children("*", "CollisionShape3D", true, false)
	var mmis := root.find_children("*", "MultiMeshInstance3D", true, false)
	t.check_eq(meshes.size(), 4, "one mesh per chunk")
	t.check_eq(shapes.size(), 4, "collision per chunk")
	t.check(mmis.size() > 0, "scatter baked")
	var script_count := 0
	for n in root.find_children("*", "", true, false):
		if n.get_script() != null:
			script_count += 1
	t.check_eq(script_count, 0, "baked scene has no Terrainy scripts")
	# Stable: baking twice gives the same vertex data.
	var first: ArrayMesh = (meshes[0] as MeshInstance3D).mesh
	root.free()
	gen.bake_to_scene(path)
	var root2 := (ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	var second: ArrayMesh = (root2.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D).mesh
	t.check(first.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == second.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], "bake is stable")
	root2.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_bake_embeds_addon_material() -> void:
	var gen := build(make_generator(64, 64.0), [make_field(5.0, Vector2(30, 30))])
	var path := "user://terrainy_bake_embed_test.tscn"
	t.check_eq(gen.bake_to_scene(path), OK, "baked with the automatic material")
	var text := FileAccess.get_file_as_string(path)
	t.check(not text.contains("res://addons/terrainy/"), "baked scene references no addon resource")
	t.check(text.contains("[sub_resource type=\"Shader\""), "terrain shader embedded as a sub-resource")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
