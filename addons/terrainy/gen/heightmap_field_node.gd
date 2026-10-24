@tool
@icon("res://addons/terrainy/icons/heightmap.svg")
class_name TerrainHeightmapNode
extends TerrainFieldNode

## External heightmap (real-world data, DCC output) as a terrain base or blend layer.
##
## Reuses the field model: Region (footprint) or Global (full map) domain, falloff, blend,
## strength, mask and modifier children. The heightmap data replaces profile + relief.
## Elevation is read from the red channel (or luminance); normalized sources are mapped to
## [elevation_min, elevation_max], float sources can be taken as meters directly.

@export_group("Heightmap")
## Image source. Takes precedence over [member source_path].
@export var source_texture: Texture2D:
	set(value):
		source_texture = value
		_source_image = null
		_commit()

## EXR / 16-bit PNG / any Image.load()-able file, read with full precision.
@export_file("*.exr", "*.png", "*.hdr", "*.webp", "*.jpg") var source_path: String = "":
	set(value):
		source_path = value
		_source_image = null
		_commit()

@export var use_luminance: bool = false:
	set(value):
		use_luminance = value
		_source_image = null
		_commit()

## Normalized: source values 0..1 map to elevation_min..elevation_max. Meters: raw values.
@export_enum("Normalized", "Meters") var value_mode: int = 0:
	set(value):
		value_mode = value
		_commit()

@export var elevation_min: float = 0.0:
	set(value):
		elevation_min = value
		_commit()

@export var elevation_max: float = 64.0:
	set(value):
		elevation_max = value
		_commit()

## Crop of the source in normalized UV (0..1).
@export var source_region: Rect2 = Rect2(0, 0, 1, 1):
	set(value):
		source_region = value
		_commit()

@export_enum("Bilinear", "Nearest") var interpolation: int = 0:
	set(value):
		interpolation = value
		_commit()

var _source_image: Image = null
var _source_sig: String = ""
var _source_data: PackedFloat32Array = PackedFloat32Array()

func _validate_property(property: Dictionary) -> void:
	super._validate_property(property)
	var pname: String = property["name"]
	if pname in ["profile", "profile_height", "relief_layers", "domain_path", "domain_width"]:
		property["usage"] = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE
	if pname == "domain_kind":
		property["hint_string"] = "Region:0,Global:2"

func get_unit_kind() -> int:
	return 0

## The resolved source image, or null (with a diagnostic) when nothing can be loaded.
func get_source_image() -> Image:
	if _source_image != null:
		return _source_image
	if source_texture:
		_source_image = source_texture.get_image()
	elif not source_path.is_empty():
		var image := Image.new()
		var abs_path := ProjectSettings.globalize_path(source_path) if source_path.begins_with("res://") or source_path.begins_with("user://") else source_path
		if FileAccess.file_exists(abs_path) and image.load(abs_path) == OK:
			_source_image = image
	if _source_image == null:
		_source_data = PackedFloat32Array()
		_source_sig = ""
		return null
	if _source_image.is_compressed():
		_source_image = _source_image.duplicate()
		_source_image.decompress()
	_source_data = Raster.image_channel(_source_image, use_luminance)
	_source_sig = "%d:%s" % [hash(_source_data), str(_source_image.get_size())]
	return _source_image

## Human readable problem with the source, or "" when it is fine.
func get_source_diagnostic() -> String:
	if source_texture == null and source_path.is_empty():
		return "No heightmap source set"
	if get_source_image() == null:
		return "Heightmap source could not be loaded: %s" % (source_path if source_texture == null else str(source_texture))
	return ""

func make_snapshot(context: Dictionary) -> RefCounted:
	var snap := FieldSnapshot.new()
	_fill_snapshot(snap, context)
	if snap.domain_kind == TerrainTypes.DomainKind.CORRIDOR:
		var grid = context.get("grid")
		snap.domain_kind = TerrainTypes.DomainKind.GLOBAL
		snap.bounds = grid.world_rect() if grid else Rect2()
	snap.is_heightmap = true
	snap.relief_noise.clear()
	snap.profile_lut = CurveLut.bake(null, 1.0)
	var image := get_source_image()
	if image != null:
		snap.hm_data = _source_data
		snap.hm_size = image.get_size()
	snap.hm_region = source_region
	snap.hm_min = elevation_min
	snap.hm_max = elevation_max
	snap.hm_nearest = interpolation == 1
	snap.hm_meters = value_mode == 1
	# A use_luminance flip changes _source_data; the source signature covers it.
	snap.signature += "|hm:%s|%d|%s|%s|%s|%s|%d|%d" % [
		_source_sig, int(use_luminance), var_to_str(source_region), var_to_str(elevation_min),
		var_to_str(elevation_max), str(interpolation), value_mode, int(snap.hm_size.x)
	]
	return snap
