extends SceneTree

## Regenerates demo/terrainy_demo.tscn (every shipped node, configured as recipe examples):
##     godot --headless --path . --script res://addons/terrainy/demo/build_demo.gd

const OUT := "res://addons/terrainy/demo/terrainy_demo.tscn"

func _curve(points: Array) -> Curve:
	var c := Curve.new()
	for p in points:
		c.add_point(Vector2(p[0], p[1]), p[2] if p.size() > 2 else 0.0, p[3] if p.size() > 3 else 0.0)
	return c

func _relief(weight: float, freq: float, seed_value: int, scale: Vector2 = Vector2.ONE, follow: bool = false) -> TerrainReliefSource:
	var r := TerrainReliefSource.new()
	r.weight = weight
	r.noise.frequency = freq
	r.noise_seed = seed_value
	r.scale = scale
	r.follow_profile = follow
	return r

func _layer(layer_name: String, color: Color) -> TerrainyTextureLayer:
	var l := TerrainyTextureLayer.new()
	l.layer_name = layer_name
	l.albedo_color = color
	l.uv_scale = Vector2(8, 8)
	return l

func _add(parent: Node, child: Node, root: Node) -> Node:
	parent.add_child(child)
	child.owner = root
	for c in child.get_children():
		c.owner = root
	return child

func _initialize() -> void:
	var root := Node3D.new()
	root.name = "terrainyDemo"

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.shadow_enabled = true
	_add(root, sun, root)
	var env := WorldEnvironment.new()
	env.name = "Environment"
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	_add(root, env, root)
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.position = Vector3(0, 110, 170)
	cam.rotation_degrees = Vector3(-32, 0, 0)
	cam.far = 2000
	_add(root, cam, root)

	var gen := TerrainGenerator.new()
	gen.name = "TerrainGenerator"
	# The demo composition is authored for a 256 m world at 1 m cells. Resizing it keeps the cell
	# size (`preserve_cell_size`), adds chunks, and LOD/navigation follow the cell size.
	gen.terrain_size = 256.0
	gen.cell_size = 1.0
	gen.base_height = 56.0
	var grass := _layer("Grass", Color(0.32, 0.5, 0.22))
	grass.slope_max = 30.0
	var rock := _layer("Rock", Color(0.45, 0.42, 0.4))
	rock.slope_min = 28.0
	var snow := _layer("Snow", Color(0.93, 0.95, 0.97))
	snow.height_min = 34.0
	snow.height_falloff = 4.0
	var gravel := _layer("Gravel", Color(0.6, 0.55, 0.45))
	var palette: Array[TerrainyTextureLayer] = [grass, rock, snow]
	gen.texture_layers = palette
	gen.paint_bundle_path = "res://addons/terrainy/demo/terrainy_demo_terrainy.tpaint"
	gen.paint_section = "demo"
	_add(root, gen, root)

	# Recipe "create noise": Global domain, flat profile at 0 + relief stack.
	var base := TerrainFieldNode.new()
	base.name = "RollingHills"
	base.domain_kind = TerrainTypes.DomainKind.GLOBAL
	base.profile_height = 0.0
	base.relief_layers = [_relief(5.0, 0.012, 1), _relief(1.2, 0.05, 2)] as Array[TerrainReliefSource]
	_add(gen, base, root)

	# Recipe "mountain": Region, concave-convex profile, relief following the profile.
	var mountain := TerrainFieldNode.new()
	mountain.name = "Mountain"
	mountain.position = Vector3(-55, 0, -50)
	mountain.region_size = Vector2(120, 120)
	mountain.profile_height = 45.0
	mountain.profile = _curve([[0, 0, 0, 0.5], [0.55, 0.45, 1.2, 1.2], [1, 1, 0.3, 0]])
	mountain.relief_layers = [_relief(10.0, 0.03, 3, Vector2.ONE, true)] as Array[TerrainReliefSource]
	_add(gen, mountain, root)
	# Nested sculpting: a Local-space terrace shapes only the mountain.
	var terrace := TerrainTerraceModifier.new()
	terrace.name = "MountainTerraces"
	terrace.space = TerrainTypes.Space.LOCAL
	terrace.step_height = 6.0
	terrace.smoothness = 0.5
	terrace.strength = 0.6
	terrace.mask = TerrainMaskElevation.new()
	terrace.mask.min_height = 0.0
	terrace.mask.max_height = 22.0
	_add(mountain, terrace, root)

	# Recipe "dunes": anisotropic relief inside an ellipse.
	var dunes := TerrainFieldNode.new()
	dunes.name = "Dunes"
	dunes.position = Vector3(70, 0, 60)
	dunes.rotation_degrees.y = 25
	dunes.region_shape = TerrainTypes.RegionShape.ELLIPSE
	dunes.region_size = Vector2(110, 70)
	dunes.profile_height = 0.0
	dunes.relief_layers = [_relief(4.0, 0.04, 4, Vector2(6, 1))] as Array[TerrainReliefSource]
	_add(gen, dunes, root)

	# Recipe "river": Corridor, concave cross-section, Curve elevation, Min blend.
	var river := TerrainFieldNode.new()
	river.name = "River"
	river.domain_kind = TerrainTypes.DomainKind.CORRIDOR
	river.domain_width = 18.0
	river.profile = _curve([[0, 0, 0, 0], [1, 1, 0, 0]])
	river.profile_height = -3.0
	river.elevation_origin = TerrainTypes.ElevationOrigin.CURVE
	river.blend_mode = TerrainTypes.BlendMode.MIN
	var route := Path3D.new()
	route.name = "Route"
	route.curve = Curve3D.new()
	for p in [Vector3(-128, -1, 40), Vector3(-60, -1.5, 20), Vector3(0, -2, 35), Vector3(60, -2.5, 10), Vector3(128, -3, 20)]:
		route.curve.add_point(p)
	river.add_child(route)
	var banks := TerrainySurfaceContribution.new()
	banks.texture_layer = gravel
	river.surface_contributions = [banks] as Array[TerrainySurfaceContribution]
	_add(gen, river, root)

	# Recipe "plateau": Region, flat profile, Replace blend; flatten modifier evens the top.
	var group := TerrainFieldGroup.new()
	group.name = "Settlement"
	group.position = Vector3(40, 0, -55)
	_add(gen, group, root)
	var plateau := TerrainFieldNode.new()
	plateau.name = "Plateau"
	plateau.region_shape = TerrainTypes.RegionShape.RECTANGLE
	plateau.region_size = Vector2(50, 36)
	plateau.profile_height = 8.0
	_add(group, plateau, root)
	var flatten := TerrainFlattenModifier.new()
	flatten.name = "LevelTheTop"
	flatten.position = Vector3(0, 8, 0)
	flatten.footprint_shape = 2
	flatten.footprint_size = Vector2(40, 26)
	_add(group, flatten, root)

	# Global post pass: never let anything dig below -6 m.
	var floor_clamp := TerrainClampModifier.new()
	floor_clamp.name = "WorldFloor"
	floor_clamp.space = TerrainTypes.Space.GLOBAL
	floor_clamp.use_max = false
	floor_clamp.min_height = -6.0
	_add(gen, floor_clamp, root)
	var smooth := TerrainSmoothModifier.new()
	smooth.name = "SoftenRiverbanks"
	smooth.radius = 2.0
	smooth.strength = 0.5
	var bank_mask := TerrainMaskPath.new()
	bank_mask.path_node = NodePath("../River/Route")
	bank_mask.width = 30.0
	smooth.mask = bank_mask
	_add(gen, smooth, root)
	var remap := TerrainRemapModifier.new()
	remap.name = "GentleLowlands"
	remap.input_min = -6.0
	remap.input_max = 60.0
	remap.output_min = -6.0
	remap.output_max = 60.0
	remap.curve = _curve([[0, 0, 0, 0.7], [1, 1, 1.4, 0]])
	remap.strength = 0.4
	_add(gen, remap, root)

	# A cave mouth in the mountain flank (punches navigation too).
	var hole := TerrainHoleNode.new()
	hole.name = "CaveMouth"
	hole.hole_shape = TerrainHoleNode.HoleShape.SPHERE
	hole.size = Vector3(9, 9, 9)
	hole.position = Vector3(-20, 12, -40)
	hole.punches_navigation = true
	_add(gen, hole, root)

	# Imported height data blended in: a small crater made from an image.
	var crater_img := Image.create(64, 64, false, Image.FORMAT_RF)
	for y in 64:
		for x in 64:
			var d := Vector2(x - 31.5, y - 31.5).length() / 32.0
			crater_img.set_pixel(x, y, Color(clampf(1.0 - absf(d - 0.6) * 4.0, 0.0, 1.0) - (0.6 if d < 0.5 else 0.0) * (1.0 - d), 0, 0))
	var heightmap := TerrainHeightmapNode.new()
	heightmap.name = "ImportedCrater"
	heightmap.domain_kind = TerrainTypes.DomainKind.REGION
	heightmap.region_shape = TerrainTypes.RegionShape.RECTANGLE
	heightmap.region_size = Vector2(40, 40)
	heightmap.position = Vector3(-80, 0, 80)
	heightmap.blend_mode = TerrainTypes.BlendMode.ADD
	heightmap.value_mode = 1
	heightmap.source_texture = ImageTexture.create_from_image(crater_img)
	heightmap.elevation_max = 6.0
	_add(gen, heightmap, root)

	var trees := TerrainScatterNode.new()
	trees.name = "Trees"
	var tree_mesh := CylinderMesh.new()
	tree_mesh.top_radius = 0.0
	tree_mesh.bottom_radius = 1.2
	tree_mesh.height = 4.0
	var tree_mat := StandardMaterial3D.new()
	tree_mat.albedo_color = Color(0.15, 0.35, 0.15)
	tree_mesh.material = tree_mat
	trees.mesh = tree_mesh
	trees.density = 0.6
	trees.slope_max = 28.0
	trees.height_offset = 2.0
	trees.elevation_max = 30.0
	var not_river := TerrainMaskPath.new()
	not_river.path_node = NodePath("../River/Route")
	not_river.width = 34.0
	not_river.invert = true
	trees.masks = [not_river] as Array[TerrainMaskResource]
	_add(gen, trees, root)

	var sculpt := TerrainPaintLayer.new()
	sculpt.name = "Sculpt"
	sculpt.layer_uid = "demo_sculpt"
	_add(gen, sculpt, root)
	var paths := TerrainPaintLayer.new()
	paths.name = "Paths"
	paths.kind = TerrainPaintLayer.PaintKind.TEXTURE
	paths.texture_layer_index = 3
	paths.layer_uid = "demo_paths"
	_add(gen, paths, root)

	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err == OK:
		err = ResourceSaver.save(packed, OUT)
	print("demo scene: %s (%s)" % [OUT, error_string(err)])
	root.free()
	quit(0 if err == OK else 1)
