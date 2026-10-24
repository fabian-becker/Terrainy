@tool
@icon("res://addons/terrainy/icons/paint_layer.svg")
class_name TerrainPaintBundle
extends Resource

## Single paint bundle file per scene (`res://<scene>_terrainy.tpaint`): every generator's paint
## layers of a scene, one section per generator (keyed by TerrainGenerator.paint_section).
##
## File format (little endian, Godot var serialization):
##     "T2PB" magic, u32 version, then a zstd-compressed var-encoded Dictionary
##     { "version": int, "sections": { section_key: { layer_uid: layer_record } } }
##     layer_record = { name, kind, revision, width, height, format, data: PackedByteArray,
##                      content_rect: Rect2i, params: Dictionary }
##
## Saving is atomic: the bundle is written to `<path>.tmp` and renamed over the target, so a
## crash never leaves a half-written bundle or orphan layer files behind.

const MAGIC := "T2PB"
const VERSION := 1
## Upper bound for a declared uncompressed payload (1 GiB). Guards `decompress()` against a
## corrupt or hostile header claiming an arbitrarily large allocation.
const MAX_RAW_BYTES := 1 << 30

## section_key -> { layer_uid -> layer_record }
@export var sections: Dictionary = {}

func get_section(key: String) -> Dictionary:
	return sections.get(key, {})

func set_section(key: String, layers: Dictionary) -> void:
	if layers.is_empty():
		sections.erase(key)
	else:
		sections[key] = layers

static func record_from_layer(layer) -> Dictionary:
	var image: Image = layer.get_data()
	return {
		"name": String(layer.name),
		"kind": int(layer.kind),
		"revision": int(layer.revision),
		"width": image.get_width(),
		"height": image.get_height(),
		"format": image.get_format(),
		"data": image.get_data(),
		"content_rect": layer.content_rect,
		"params": {
			"opacity": layer.opacity,
			"texture_layer_index": layer.texture_layer_index,
			"smooth_radius": layer.smooth_radius,
		},
	}

static func image_from_record(record: Dictionary) -> Image:
	var data: PackedByteArray = record.get("data", PackedByteArray())
	var w: int = record.get("width", 0)
	var h: int = record.get("height", 0)
	var fmt: int = record.get("format", Image.FORMAT_RF)
	if w <= 0 or h <= 0 or data.is_empty():
		return null
	return Image.create_from_data(w, h, false, fmt, data)

func to_bytes() -> PackedByteArray:
	var payload := var_to_bytes({"version": VERSION, "sections": sections})
	var compressed := payload.compress(FileAccess.COMPRESSION_ZSTD)
	var out := PackedByteArray()
	out.append_array(MAGIC.to_ascii_buffer())
	var header := PackedByteArray()
	header.resize(12)
	header.encode_u32(0, VERSION)
	header.encode_u32(4, payload.size())
	header.encode_u32(8, compressed.size())
	out.append_array(header)
	out.append_array(compressed)
	return out

static func from_bytes(bytes: PackedByteArray) -> TerrainPaintBundle:
	if bytes.size() < 16 or bytes.slice(0, 4).get_string_from_ascii() != MAGIC:
		return null
	if bytes.decode_u32(4) != VERSION:
		return null
	var raw_size := bytes.decode_u32(8)
	var compressed_size := bytes.decode_u32(12)
	if raw_size <= 0 or raw_size > MAX_RAW_BYTES:
		return null
	if compressed_size <= 0 or compressed_size > bytes.size() - 16:
		return null
	var payload := bytes.slice(16).decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if payload.size() != raw_size:
		return null
	var decoded = bytes_to_var(payload)
	if not (decoded is Dictionary) or int(decoded.get("version", -1)) != VERSION:
		return null
	var bundle := TerrainPaintBundle.new()
	bundle.sections = decoded.get("sections", {})
	return bundle

## Atomic save. Returns OK or an error code.
func save_to_file(path: String) -> Error:
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(to_bytes())
	file.close()
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var abs_path := ProjectSettings.globalize_path(path)
	# Replace in one step where the platform allows it (Windows rename replaces the target).
	var err := DirAccess.rename_absolute(abs_tmp, abs_path)
	if err == OK:
		return OK
	# Fallback for platforms that refuse to rename over an existing file.
	if FileAccess.file_exists(path):
		err = DirAccess.remove_absolute(abs_path)
		if err != OK:
			return err
		return DirAccess.rename_absolute(abs_tmp, abs_path)
	return err

static func load_from_file(path: String) -> TerrainPaintBundle:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	return from_bytes(bytes)
