@tool
extends RefCounted

## Auto-material (zero-config default) and the custom-material hook.
##
## The auto material blends the palette (TerrainGenerator.texture_layers + contribution-owned
## layers) by world height and slope, then applies the stage-6 weight planes. A
## `custom_material` replaces it; when it is a ShaderMaterial the builder still feeds it the
## documented uniforms (api.md, "Custom materials"):
##
##     sampler2DArray terrainy_weight_planes    claim per palette layer (R8, slice = layer)
##     sampler2DArray terrainy_modulation_planes add (R) / suppress (G) per layer (RG8)
##     int  terrainy_layer_count, bool terrainy_has_claims, bool terrainy_has_modulation
##     vec2 terrainy_terrain_origin, vec2 terrainy_terrain_size   (world XZ of the planes)

const MAX_LAYERS: int = 32
const MIN_ARRAY_SIZE: int = 16
const PROCEDURAL_ONLY_ARRAY_SIZE: int = 256
const SHADER_PATH := "res://addons/terrainy/shaders/terrain2_material.gdshader"

var texture_array_size: int = 2048

var _material: ShaderMaterial = null
var _layer_signature: String = ""
var _planes_revision: int = -1
var _weight_array: Texture2DArray = null
var _mod_array: Texture2DArray = null

## Plain-data capture of the palette (worker safe, also used by the CPU weight mirror).
static func capture_palette(layers: Array, owned: Array, generator_y: float) -> Array:
	var out: Array = []
	for i in layers.size():
		var layer = layers[i]
		if layer == null:
			out.append({"valid": false, "owned": owned.has(i), "y_offset": generator_y})
			continue
		out.append({
			"valid": true, "owned": owned.has(i), "y_offset": generator_y,
			"height_min": layer.height_min, "height_max": layer.height_max, "height_falloff": layer.height_falloff,
			"slope_min": deg_to_rad(layer.slope_min), "slope_max": deg_to_rad(layer.slope_max),
			"slope_falloff": deg_to_rad(layer.slope_falloff), "strength": layer.layer_strength,
			"blend_mode": layer.blend_mode,
		})
	return out

## CPU mirror of calculate_layer_weight() in terrain2_material.gdshader (without the cosmetic
## blend noise). [param height] is the world height, [param slope] in radians.
static func layer_weight(layer: Dictionary, height: float, slope: float, height_noise: float) -> float:
	if not layer.get("valid", false):
		return 0.0
	var h := height + height_noise
	var weight := 1.0
	var hf: float = layer["height_falloff"]
	var hmin: float = layer["height_min"]
	var hmax: float = layer["height_max"]
	if hf > 0.001:
		if h < hmin:
			weight *= 1.0 - _smoothstep(0.0, hf, hmin - h)
		elif h > hmax:
			weight *= 1.0 - _smoothstep(0.0, hf, h - hmax)
	elif h < hmin or h > hmax:
		return 0.0
	var sf: float = layer["slope_falloff"]
	var smin: float = layer["slope_min"]
	var smax: float = layer["slope_max"]
	if sf > 0.001:
		if slope < smin:
			weight *= 1.0 - _smoothstep(0.0, sf, smin - slope)
		elif slope > smax:
			weight *= 1.0 - _smoothstep(0.0, sf, slope - smax)
	elif slope < smin or slope > smax:
		return 0.0
	return weight * float(layer["strength"])

## CPU mirror of the shader's final per-layer blend weights (Normal-mode layers normalized,
## claims settled after normalization). Used by TerrainyAPI.get_texture_blend_at().
static func blend_weights(palette: Array, height: float, slope: float, claims: PackedFloat32Array, add: PackedFloat32Array, suppress: PackedFloat32Array) -> PackedFloat32Array:
	var n := palette.size()
	var w := PackedFloat32Array()
	w.resize(n)
	for i in n:
		w[i] = layer_weight(palette[i], height, slope, 0.0)
		if i < add.size():
			w[i] += add[i]
		if i < suppress.size():
			w[i] *= 1.0 - suppress[i]
		if palette[i].get("owned", false):
			w[i] = add[i] if i < add.size() else 0.0
	var normal_total := 0.0
	for i in n:
		if int(palette[i].get("blend_mode", 0)) == 0:
			normal_total += w[i]
	if normal_total > 0.001:
		for i in n:
			if int(palette[i].get("blend_mode", 0)) == 0:
				w[i] /= normal_total
	else:
		for i in n:
			w[i] = 0.0
		for i in n:
			if not palette[i].get("owned", false):
				w[i] = 1.0
				break
	var claim_total := 0.0
	for i in mini(n, claims.size()):
		claim_total += claims[i]
	if claim_total > 0.001:
		var t := minf(claim_total, 1.0)
		for i in n:
			var c := claims[i] if i < claims.size() else 0.0
			w[i] = w[i] * (1.0 - t) + c * (t / claim_total)
	return w

static func _smoothstep(e0: float, e1: float, x: float) -> float:
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func get_material() -> ShaderMaterial:
	return _material

## Build/refresh the material. [param planes]: stage-6 result (+ "revision").
func update(layers: Array, owned: Array, custom_material: Material, planes: Dictionary, world: Rect2) -> Material:
	if custom_material:
		if custom_material is ShaderMaterial:
			_bind_planes(custom_material, layers.size(), planes, world)
		return custom_material
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = load(SHADER_PATH)
		_layer_signature = ""
	_material.set_shader_parameter("compatibility_disable_ao", not RenderingServer.get_rendering_device())
	var sig := _palette_signature(layers, owned)
	if sig != _layer_signature:
		_layer_signature = sig
		_build_arrays(layers, owned)
	_bind_planes(_material, mini(layers.size(), MAX_LAYERS), planes, world)
	return _material

func _bind_planes(material: ShaderMaterial, count: int, planes: Dictionary, world: Rect2) -> void:
	material.set_shader_parameter("terrainy_layer_count", count)
	material.set_shader_parameter("terrainy_terrain_origin", world.position)
	material.set_shader_parameter("terrainy_terrain_size", world.size)
	var revision: int = planes.get("revision", -1)
	if revision != _planes_revision or material != _material:
		_planes_revision = revision
		var claims: Array = planes.get("claims", [])
		var mods: Array = planes.get("modulation", [])
		_weight_array = _array_or_dummy(claims, Image.FORMAT_R8, count)
		_mod_array = _array_or_dummy(mods, Image.FORMAT_RG8, count)
	material.set_shader_parameter("terrainy_has_claims", planes.get("has_claims", false))
	material.set_shader_parameter("terrainy_has_modulation", planes.get("has_modulation", false))
	material.set_shader_parameter("terrainy_weight_planes", _weight_array)
	material.set_shader_parameter("terrainy_modulation_planes", _mod_array)

## Upload new contents of single plane slices (stroke updates) without rebuilding the array.
func update_plane_slices(planes: Dictionary, slices: PackedInt32Array) -> void:
	if _weight_array == null:
		return
	var claims: Array = planes.get("claims", [])
	for i in slices:
		if i < claims.size() and i < _weight_array.get_layers() and claims[i].get_size() == Vector2i(_weight_array.get_width(), _weight_array.get_height()):
			_weight_array.update_layer(claims[i], i)
	for mat in [_material]:
		if mat:
			mat.set_shader_parameter("terrainy_has_claims", planes.get("has_claims", false))

static func _array_or_dummy(images: Array, format: int, count: int) -> Texture2DArray:
	var list: Array[Image] = []
	for img in images:
		if img is Image:
			list.append(img)
	if list.is_empty():
		var dummy := Image.create(1, 1, false, format)
		for i in maxi(count, 1):
			list.append(dummy.duplicate())
	var array := Texture2DArray.new()
	array.create_from_images(list)
	return array

func _palette_signature(layers: Array, owned: Array) -> String:
	var parts := PackedStringArray(["size=%d" % texture_array_size, "owned=%s" % str(owned)])
	for layer in layers:
		if layer == null:
			parts.append("null")
			continue
		parts.append("|".join([
			_tex_id(layer.albedo_texture), _tex_id(layer.normal_texture), _tex_id(layer.roughness_texture),
			_tex_id(layer.metallic_texture), _tex_id(layer.ao_texture), str(layer.albedo_color),
			str(layer.height_min), str(layer.height_max), str(layer.height_falloff), str(layer.slope_min),
			str(layer.slope_max), str(layer.slope_falloff), str(layer.layer_strength), str(layer.blend_mode),
			str(layer.uv_scale), str(layer.uv_offset), str(layer.normal_strength), str(layer.roughness),
			str(layer.metallic), str(layer.ao_strength),
		]))
	return ",".join(parts)

func _tex_id(texture: Texture2D) -> String:
	return "-" if texture == null else str(texture.get_instance_id())

func _build_arrays(layers: Array, owned: Array) -> void:
	var count := mini(layers.size(), MAX_LAYERS)
	_material.set_shader_parameter("layer_count", count)
	if count == 0:
		return
	var hs: Array[Vector4] = []
	var bp: Array[Vector4] = []
	var uv: Array[Vector4] = []
	var cn: Array[Vector4] = []
	var pbr: Array[Vector4] = []
	var tf: Array[Vector4] = []
	var ef: Array[Vector4] = []
	var albedo: Array[Image] = []
	var normal: Array[Image] = []
	var rough: Array[Image] = []
	var metal: Array[Image] = []
	var ao: Array[Image] = []
	var size := _resolve_array_size(layers, count)
	for i in count:
		var layer = layers[i]
		if layer == null:
			layer = TerrainyTextureLayer.new()
			layer.layer_strength = 0.0
		hs.append(Vector4(layer.height_min, layer.height_max, layer.height_falloff, deg_to_rad(layer.slope_min)))
		bp.append(Vector4(layer.layer_strength, deg_to_rad(layer.slope_max), deg_to_rad(layer.slope_falloff), float(layer.blend_mode)))
		uv.append(Vector4(layer.uv_scale.x, layer.uv_scale.y, layer.uv_offset.x, layer.uv_offset.y))
		# Albedo tint and textures are authored in sRGB, but the renderer computes lighting in
		# linear space and the engine never converts packed vector uniforms - without this the
		# tints render ~1.6-2x brighter and desaturated ("washed out").
		var albedo_linear: Color = layer.albedo_color.srgb_to_linear()
		cn.append(Vector4(albedo_linear.r, albedo_linear.g, albedo_linear.b, layer.normal_strength))
		pbr.append(Vector4(layer.roughness, layer.metallic, layer.ao_strength, 0.0))
		tf.append(Vector4(1.0 if layer.albedo_texture else 0.0, 1.0 if layer.normal_texture else 0.0,
			1.0 if layer.roughness_texture else 0.0, 1.0 if layer.metallic_texture else 0.0))
		ef.append(Vector4(1.0 if layer.ao_texture else 0.0, 0.0, 0.0, 1.0 if owned.has(i) else 0.0))
		albedo.append(_image_for(layer.albedo_texture, size, albedo_linear, true))
		normal.append(_image_for(layer.normal_texture, size, Color(0.5, 0.5, 1.0)))
		rough.append(_image_for(layer.roughness_texture, size, Color(layer.roughness, layer.roughness, layer.roughness)))
		metal.append(_image_for(layer.metallic_texture, size, Color(layer.metallic, layer.metallic, layer.metallic)))
		ao.append(_image_for(layer.ao_texture, size, Color(1, 1, 1)))
	_material.set_shader_parameter("layer_height_slope_params", hs)
	_material.set_shader_parameter("layer_blend_params", bp)
	_material.set_shader_parameter("layer_uv_params", uv)
	_material.set_shader_parameter("layer_color_normal", cn)
	_material.set_shader_parameter("layer_pbr_params", pbr)
	_material.set_shader_parameter("layer_texture_flags", tf)
	_material.set_shader_parameter("layer_extra_flags", ef)
	_material.set_shader_parameter("albedo_textures", _texture_array(albedo))
	_material.set_shader_parameter("normal_textures", _texture_array(normal))
	_material.set_shader_parameter("roughness_textures", _texture_array(rough))
	_material.set_shader_parameter("metallic_textures", _texture_array(metal))
	_material.set_shader_parameter("ao_textures", _texture_array(ao))

func _resolve_array_size(layers: Array, count: int) -> Vector2i:
	var largest := 0
	for i in count:
		var layer = layers[i]
		if layer == null:
			continue
		for t in [layer.albedo_texture, layer.normal_texture, layer.roughness_texture, layer.metallic_texture, layer.ao_texture]:
			if t:
				var s: Vector2 = t.get_size()
				largest = maxi(largest, maxi(int(s.x), int(s.y)))
	if largest <= 0:
		largest = PROCEDURAL_ONLY_ARRAY_SIZE
	largest = mini(largest, texture_array_size)
	var p := 1
	while p * 2 <= largest:
		p *= 2
	p = maxi(p, MIN_ARRAY_SIZE)
	return Vector2i(p, p)

## [param color] is used as the fill when [param texture] is null. With [param srgb] set, the
## image is converted from sRGB to linear (matches what the engine does for
## `source_color` textures so the shader samples linear data from the raw upload).
func _image_for(texture: Texture2D, size: Vector2i, color: Color, srgb: bool = false) -> Image:
	if texture:
		var src := texture.get_image()
		if src:
			var img := src.duplicate() as Image
			if img.is_compressed():
				img.decompress()
			if img.get_size() != size:
				img.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			if not img.has_mipmaps():
				img.generate_mipmaps()
			if srgb:
				img.srgb_to_linear()
			return img
	var solid := Image.create(size.x, size.y, true, Image.FORMAT_RGBA8)
	solid.fill(color)
	solid.generate_mipmaps()
	return solid

func _texture_array(images: Array[Image]) -> Texture2DArray:
	if images.is_empty():
		return null
	var array := Texture2DArray.new()
	array.create_from_images(images)
	return array
