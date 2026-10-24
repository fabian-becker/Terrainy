extends "res://addons/terrainy/tests/framework/test_case.gd"

## Auto material + custom material hook + CPU weight mirror.

const MaterialBuilder = preload("res://addons/terrainy/gen/build/material_builder.gd")

func test_auto_material_is_installed_on_chunks() -> void:
	var l := TerrainyTextureLayer.new()
	var gen := build(make_generator(64, 64.0, func(g: TerrainGenerator): g.texture_layers = [l]))
	for chunk in gen.get_chunk_manager().chunks.values():
		var mat = chunk.mesh_instance.material_override
		t.check(mat is ShaderMaterial, "shader material on chunk %s" % chunk.key)
		t.check_eq(mat.get_shader_parameter("layer_count"), 1, "palette uploaded")
		t.check(mat.get_shader_parameter("terrainy_weight_planes") is Texture2DArray, "weight planes bound")

func test_custom_material_receives_weight_plane_contract() -> void:
	var custom := ShaderMaterial.new()
	custom.shader = Shader.new()
	custom.shader.code = "shader_type spatial;\nuniform sampler2DArray terrainy_weight_planes;\nuniform int terrainy_layer_count;\nuniform vec2 terrainy_terrain_origin;\nuniform vec2 terrainy_terrain_size;\nvoid fragment() { ALBEDO = vec3(1.0); }"
	var gen := build(make_generator(64, 64.0, func(g: TerrainGenerator):
		g.texture_layers = [TerrainyTextureLayer.new(), TerrainyTextureLayer.new()]
		g.custom_material = custom))
	var chunk = gen.get_chunk_manager().chunks.values()[0]
	t.check(chunk.mesh_instance.material_override == custom, "custom material used")
	t.check_eq(custom.get_shader_parameter("terrainy_layer_count"), 2, "layer count uniform")
	t.check(custom.get_shader_parameter("terrainy_weight_planes") is Texture2DArray, "weight planes uniform")
	t.check(custom.get_shader_parameter("terrainy_terrain_size") == Vector2(64, 64), "terrain size uniform")

func test_albedo_tint_uploaded_as_linear_srgb() -> void:
	var l := TerrainyTextureLayer.new()
	l.albedo_color = Color(0.32, 0.5, 0.22)
	l.normal_strength = 1.5
	var gen := build(make_generator(64, 64.0, func(g: TerrainGenerator): g.texture_layers = [l]))
	var mat = gen.get_chunk_manager().chunks.values()[0].mesh_instance.material_override
	var cn: PackedVector4Array = mat.get_shader_parameter("layer_color_normal")
	t.check_almost_eq(cn[0].x, 0.0836, "sRGB red 0.32 -> linear ~0.084", 0.002)
	t.check_almost_eq(cn[0].y, 0.2138, "sRGB green 0.5 -> linear ~0.214", 0.002)
	t.check_almost_eq(cn[0].z, 0.0397, "sRGB blue 0.22 -> linear ~0.040", 0.002)
	t.check_eq(cn[0].w, 1.5, "normal strength stays raw, not converted")

func test_cpu_weight_mirror_height_bands() -> void:
	var low := TerrainyTextureLayer.new()
	low.height_max = 5.0
	low.height_falloff = 0.0
	var high := TerrainyTextureLayer.new()
	high.height_min = 5.0
	high.height_falloff = 0.0
	var palette := MaterialBuilder.capture_palette([low, high], [], 0.0)
	var w := MaterialBuilder.blend_weights(palette, 2.0, 0.0, PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array())
	t.check_almost_eq(w[0], 1.0, "low band below 5 m")
	w = MaterialBuilder.blend_weights(palette, 9.0, 0.0, PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array())
	t.check_almost_eq(w[1], 1.0, "high band above 5 m")
	w = MaterialBuilder.blend_weights(palette, 9.0, 0.0, PackedFloat32Array([0.5, 0.0]), PackedFloat32Array(), PackedFloat32Array())
	t.check_almost_eq(w[0], 0.5, "a half claim takes half the surface")

func test_shader_compiles_with_contract_uniforms() -> void:
	var shader: Shader = load(MaterialBuilder.SHADER_PATH)
	t.check(shader != null, "material shader loads")
	var names := []
	for u in shader.get_shader_uniform_list():
		names.append(u["name"])
	for required in ["terrainy_weight_planes", "terrainy_modulation_planes", "terrainy_layer_count", "terrainy_terrain_origin", "terrainy_terrain_size"]:
		t.check(names.has(required), "uniform %s present" % required)
