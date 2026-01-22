class_name TerrainMaterialBuilder
extends RefCounted

## Helper class for building terrain materials with texture layers
## Handles shader material creation and texture array setup

const TerrainTextureLayer = preload("res://addons/terrainy/resources/terrain_texture_layer.gd")

var _shader_material: ShaderMaterial = null

## Update material on a mesh instance with texture layers
func update_material(
	mesh_instance: MeshInstance3D,
	texture_layers: Array[TerrainTextureLayer],
	custom_material: Material = null
) -> void:
	if not mesh_instance:
		return
	
	# Use custom material if provided
	if custom_material:
		mesh_instance.material_override = custom_material
		return
	
	# Create shader material if needed
	if not _shader_material:
		_shader_material = ShaderMaterial.new()
		var shader = load("res://addons/terrainy/shaders/terrain_material.gdshader")
		_shader_material.shader = shader
	
	mesh_instance.material_override = _shader_material
	
	# Update shader with texture layers
	if texture_layers.is_empty():
		_shader_material.set_shader_parameter("layer_count", 0)
		return
	
	_build_texture_arrays(texture_layers)

## Build texture arrays from layers
func _build_texture_arrays(texture_layers: Array[TerrainTextureLayer]) -> void:
	if texture_layers.is_empty():
		return
	
	var layer_count = min(texture_layers.size(), 32)
	_shader_material.set_shader_parameter("layer_count", layer_count)
	
	# Prepare layer parameter arrays
	var height_slope_params: Array[Vector4] = []
	var blend_params: Array[Vector4] = []
	var uv_params: Array[Vector4] = []
	var color_normal: Array[Vector4] = []
	var pbr_params: Array[Vector4] = []
	var texture_flags: Array[Vector4] = []
	var extra_flags: Array[Vector4] = []
	
	# Collect textures
	var albedo_images: Array[Image] = []
	var normal_images: Array[Image] = []
	var roughness_images: Array[Image] = []
	var metallic_images: Array[Image] = []
	var ao_images: Array[Image] = []
	
	var texture_size = Vector2i(2048, 2048)
	
	for i in range(layer_count):
		var layer = texture_layers[i]
		if not layer:
			continue
		
		# Pack parameters
		height_slope_params.append(Vector4(
			layer.height_min,
			layer.height_max,
			layer.height_falloff,
			deg_to_rad(layer.slope_min)
		))
		
		blend_params.append(Vector4(
			layer.layer_strength,
			deg_to_rad(layer.slope_max),
			deg_to_rad(layer.slope_falloff),
			float(layer.blend_mode)
		))
		
		uv_params.append(Vector4(
			layer.uv_scale.x,
			layer.uv_scale.y,
			layer.uv_offset.x,
			layer.uv_offset.y
		))
		
		color_normal.append(Vector4(
			layer.albedo_color.r,
			layer.albedo_color.g,
			layer.albedo_color.b,
			layer.normal_strength
		))
		
		pbr_params.append(Vector4(
			layer.roughness,
			layer.metallic,
			layer.ao_strength,
			0.0
		))
		
		# Texture flags: [has_albedo, has_normal, has_roughness, has_metallic]
		texture_flags.append(Vector4(
			1.0 if layer.albedo_texture else 0.0,
			1.0 if layer.normal_texture else 0.0,
			1.0 if layer.roughness_texture else 0.0,
			1.0 if layer.metallic_texture else 0.0
		))
		
		# Extra flags: [has_ao, use_height_curve, use_slope_curve, unused]
		extra_flags.append(Vector4(
			1.0 if layer.ao_texture else 0.0,
			0.0,
			0.0,
			0.0
		))
		
		# Get textures
		albedo_images.append(_get_or_create_image(layer.albedo_texture, texture_size, layer.albedo_color))
		normal_images.append(_get_or_create_image(layer.normal_texture, texture_size, Color(0.5, 0.5, 1.0)))
		roughness_images.append(_get_or_create_image(layer.roughness_texture, texture_size, Color(layer.roughness, layer.roughness, layer.roughness)))
		metallic_images.append(_get_or_create_image(layer.metallic_texture, texture_size, Color(layer.metallic, layer.metallic, layer.metallic)))
		ao_images.append(_get_or_create_image(layer.ao_texture, texture_size, Color(layer.ao_strength, layer.ao_strength, layer.ao_strength)))
	
	# Set shader parameters
	_shader_material.set_shader_parameter("layer_height_slope_params", height_slope_params)
	_shader_material.set_shader_parameter("layer_blend_params", blend_params)
	_shader_material.set_shader_parameter("layer_uv_params", uv_params)
	_shader_material.set_shader_parameter("layer_color_normal", color_normal)
	_shader_material.set_shader_parameter("layer_pbr_params", pbr_params)
	_shader_material.set_shader_parameter("layer_texture_flags", texture_flags)
	_shader_material.set_shader_parameter("layer_extra_flags", extra_flags)
	
	# Set texture index mapping (identity for now: layer i → texture slot i)
	var texture_indices: PackedInt32Array = []
	for i in range(layer_count):
		texture_indices.append(i)
	_shader_material.set_shader_parameter("layer_texture_index", texture_indices)
	
	# Create texture arrays
	var albedo_array = _create_texture_array(albedo_images)
	var normal_array = _create_texture_array(normal_images)
	var roughness_array = _create_texture_array(roughness_images)
	var metallic_array = _create_texture_array(metallic_images)
	var ao_array = _create_texture_array(ao_images)
	
	# Set to shader
	if albedo_array:
		_shader_material.set_shader_parameter("albedo_textures", albedo_array)
	if normal_array:
		_shader_material.set_shader_parameter("normal_textures", normal_array)
	if roughness_array:
		_shader_material.set_shader_parameter("roughness_textures", roughness_array)
	if metallic_array:
		_shader_material.set_shader_parameter("metallic_textures", metallic_array)
	if ao_array:
		_shader_material.set_shader_parameter("ao_textures", ao_array)

## Get or create image from texture
func _get_or_create_image(texture: Texture2D, size: Vector2i, default_color: Color) -> Image:
	if texture:
		var img = texture.get_image()
		if not img:
			var fallback = Image.create(size.x, size.y, true, Image.FORMAT_RGBA8)
			fallback.fill(default_color)
			fallback.generate_mipmaps()
			return fallback
		if img.get_size() != size:
			img.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		# Generate mipmaps for better filtering at distance
		if not img.has_mipmaps():
			img.generate_mipmaps()
		return img
	else:
		var img = Image.create(size.x, size.y, true, Image.FORMAT_RGBA8)
		img.fill(default_color)
		img.generate_mipmaps()
		return img

## Create texture array from images
func _create_texture_array(images: Array[Image]) -> Texture2DArray:
	if images.is_empty():
		return null
	
	var size = images[0].get_size()
	var format = Image.FORMAT_RGBA8
	var has_mipmaps = images[0].has_mipmaps()
	
	# Ensure all images have consistent properties
	for i in range(images.size()):
		if images[i].get_size() != size:
			images[i].resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
		if images[i].get_format() != format:
			images[i].convert(format)
		# Ensure consistent mipmap state
		if has_mipmaps and not images[i].has_mipmaps():
			images[i].generate_mipmaps()
		elif not has_mipmaps and images[i].has_mipmaps():
			images[i].clear_mipmaps()
	
	var texture_array = Texture2DArray.new()
	texture_array.create_from_images(images)
	
	return texture_array
