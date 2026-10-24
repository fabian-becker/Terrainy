@tool
class_name TerrainPaintBundleLoader
extends ResourceFormatLoader

## Makes `.tpaint` bundles regular resources (FileSystem dock, ResourceLoader, export).

func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["tpaint"])

func _get_resource_type(path: String) -> String:
	return "Resource" if path.get_extension().to_lower() == "tpaint" else ""

func _handles_type(type: StringName) -> bool:
	return type == &"Resource"

func _get_resource_script_class(path: String) -> String:
	return "TerrainPaintBundle" if path.get_extension().to_lower() == "tpaint" else ""

func _load(path: String, _original_path: String, _use_sub_threads: bool, _cache_mode: int) -> Variant:
	var bundle := TerrainPaintBundle.load_from_file(path)
	if bundle == null:
		return ERR_FILE_CORRUPT
	return bundle
