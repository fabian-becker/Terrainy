@tool
class_name TerrainPaintBundleSaver
extends ResourceFormatSaver

## Saves [TerrainPaintBundle] resources as `.tpaint` (atomic, see TerrainPaintBundle).

func _get_recognized_extensions(resource: Resource) -> PackedStringArray:
	if resource is TerrainPaintBundle:
		return PackedStringArray(["tpaint"])
	return PackedStringArray()

func _recognize(resource: Resource) -> bool:
	return resource is TerrainPaintBundle

func _save(resource: Resource, path: String, _flags: int) -> Error:
	if not (resource is TerrainPaintBundle):
		return ERR_INVALID_PARAMETER
	return (resource as TerrainPaintBundle).save_to_file(path)
