extends "res://addons/terrainy/tests/framework/test_case.gd"

## Tests for TerrainMaterialBuilder: layer cap, texture array sizing, the cheap layer
## signature used to skip redundant rebuilds, and material assignment.

const LAYERS_CONST := TerrainMaterialBuilder.MAX_LAYERS

func _make_layer(albedo_value: float, albedo_size: Vector2i = Vector2i.ZERO) -> TerrainTextureLayer:
	var layer := TerrainTextureLayer.new()
	if albedo_size != Vector2i.ZERO:
		layer.albedo_texture = ImageTexture.create_from_image(make_grey_texture_image(albedo_size, albedo_value))
	return layer

func test_layer_cap_matches_the_shader() -> void:
	t.check_eq(TerrainMaterialBuilder.MAX_LAYERS, 32, "terrain shader layer cap")

func test_floor_power_of_two() -> void:
	var builder := TerrainMaterialBuilder.new()
	t.check_eq(builder._floor_power_of_two(1), 1, "1 stays 1")
	t.check_eq(builder._floor_power_of_two(15), 8, "15 floors to 8")
	t.check_eq(builder._floor_power_of_two(16), 16, "exact powers stay")
	t.check_eq(builder._floor_power_of_two(17), 16, "17 floors to 16")
	t.check_eq(builder._floor_power_of_two(2048), 2048, "2048 stays 2048")

func test_array_size_follows_the_largest_source_texture() -> void:
	var builder := TerrainMaterialBuilder.new()
	var layers: Array[TerrainTextureLayer] = [_make_layer(1.0, Vector2i(128, 128)), _make_layer(1.0, Vector2i(64, 64))]
	t.check_eq(builder._resolve_array_size(layers, 2), Vector2i(128, 128), "largest source wins")

func test_array_size_is_clamped_to_texture_array_size() -> void:
	var builder := TerrainMaterialBuilder.new()
	builder.texture_array_size = 64
	var layers: Array[TerrainTextureLayer] = [_make_layer(1.0, Vector2i(512, 512))]
	t.check_eq(builder._resolve_array_size(layers, 1), Vector2i(64, 64), "large sources are downscaled to the configured size")

func test_array_size_never_upscales_and_respects_the_minimum() -> void:
	var builder := TerrainMaterialBuilder.new()
	var small: Array[TerrainTextureLayer] = [_make_layer(1.0, Vector2i(8, 8))]
	t.check_eq(
		builder._resolve_array_size(small, 1), Vector2i(16, 16),
		"sources below the minimum are padded up to MIN_ARRAY_SIZE"
	)
	var medium: Array[TerrainTextureLayer] = [_make_layer(1.0, Vector2i(48, 48))]
	t.check_eq(
		builder._resolve_array_size(medium, 1), Vector2i(32, 32),
		"sources are never upscaled, only floored to a power of two"
	)

func test_procedural_only_layers_use_the_procedural_size() -> void:
	var builder := TerrainMaterialBuilder.new()
	var layers: Array[TerrainTextureLayer] = [_make_layer(0.5)]
	t.check_eq(
		builder._resolve_array_size(layers, 1), Vector2i(256, 256),
		"layers without textures use PROCEDURAL_ONLY_ARRAY_SIZE"
	)

func test_layer_signature_tracks_shader_relevant_settings() -> void:
	var builder := TerrainMaterialBuilder.new()
	var layer := _make_layer(1.0, Vector2i(64, 64))
	var layers: Array[TerrainTextureLayer] = [layer]
	var signature := builder._compute_layer_signature(layers)
	t.check_eq(
		builder._compute_layer_signature(layers), signature,
		"the signature is stable for unchanged layers"
	)
	layer.height_min = -5.0
	t.check_not_eq(
		builder._compute_layer_signature(layers), signature,
		"height_min is part of the signature"
	)
	var resized: Array[TerrainTextureLayer] = [_make_layer(1.0, Vector2i(32, 32))]
	t.check_not_eq(
		builder._compute_layer_signature(resized), signature,
		"a different texture changes the signature"
	)

func test_layer_signature_ignores_layers_beyond_the_cap() -> void:
	var builder := TerrainMaterialBuilder.new()
	var layers: Array[TerrainTextureLayer] = []
	for i in LAYERS_CONST:
		layers.append(_make_layer(1.0))
	var signature := builder._compute_layer_signature(layers)
	layers.append(_make_layer(0.5))
	t.check_eq(
		builder._compute_layer_signature(layers), signature,
		"layers past MAX_LAYERS cannot affect the shader output"
	)

func test_update_material_assigns_a_material_and_skips_redundant_rebuilds() -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = BoxMesh.new()
	spawn(mesh_instance)

	var builder := TerrainMaterialBuilder.new()
	var layers: Array[TerrainTextureLayer] = [_make_layer(1.0, Vector2i(64, 64))]
	builder.update_material(mesh_instance, layers)
	var material = mesh_instance.material_override
	t.check(material != null, "a material is assigned to the mesh")
	t.check(material is ShaderMaterial, "the terrain shader material is used")
	var signature := builder._layer_signature
	t.check(signature != "" and signature != "empty", "the layer signature is recorded")

	builder.update_material(mesh_instance, layers)
	t.check_eq(builder._layer_signature, signature, "unchanged layers keep the signature")
	t.check(mesh_instance.material_override == material, "the material is reused")

	var changed: Array[TerrainTextureLayer] = [_make_layer(1.0, Vector2i(64, 64))]
	changed[0].layer_strength = 0.25
	builder.update_material(mesh_instance, changed)
	t.check_not_eq(builder._layer_signature, signature, "changed layers rebuild the arrays")

func test_update_material_without_layers_clears_the_layer_count() -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = BoxMesh.new()
	spawn(mesh_instance)

	var builder := TerrainMaterialBuilder.new()
	var empty: Array[TerrainTextureLayer] = []
	builder.update_material(mesh_instance, empty)
	t.check_eq(builder._layer_signature, "empty", "an empty layer list is recorded")
	t.check(mesh_instance.material_override != null, "the material is still assigned")

func test_update_material_honors_a_custom_material() -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = BoxMesh.new()
	spawn(mesh_instance)

	var custom := StandardMaterial3D.new()
	var builder := TerrainMaterialBuilder.new()
	var layers: Array[TerrainTextureLayer] = [_make_layer(1.0, Vector2i(64, 64))]
	builder.update_material(mesh_instance, layers, custom)
	t.check(mesh_instance.material_override == custom, "the custom material wins")
	t.check_eq(builder._layer_signature, "", "no texture arrays are built for custom materials")
