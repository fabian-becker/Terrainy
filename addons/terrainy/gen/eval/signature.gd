@tool
extends RefCounted

## Content signatures for compose caching.
##
## A signature is a plain string built from exact values (no rounding), so any input change
## produces a different string. Resources are walked through their storage properties; image
## data contributes a hash of its bytes, cached per resource instance until it emits changed.

static var _image_hash_cache: Dictionary = {}

static func of_value(value, depth: int = 0) -> String:
	if value == null:
		return "null"
	if value is Object:
		return of_object(value, depth)
	if value is Array:
		var parts := PackedStringArray()
		for item in value:
			parts.append(of_value(item, depth + 1))
		return "[" + ",".join(parts) + "]"
	if value is Dictionary:
		var parts := PackedStringArray()
		for key in value:
			parts.append("%s:%s" % [str(key), of_value(value[key], depth + 1)])
		return "{" + ",".join(parts) + "}"
	if value is PackedByteArray or value is PackedFloat32Array or value is PackedInt32Array \
			or value is PackedVector3Array or value is PackedVector2Array or value is PackedFloat64Array:
		return "h%d/%d" % [hash(value), value.size()]
	# var_to_str keeps full float precision (str() rounds to 6 digits).
	return var_to_str(value)

static func of_object(obj: Object, depth: int = 0) -> String:
	if not is_instance_valid(obj):
		return "freed"
	if depth > 4:
		return "o%d" % obj.get_instance_id()
	if obj is Image:
		return "img%d:%s" % [hash((obj as Image).get_data()), str((obj as Image).get_size())]
	if obj is Texture2D:
		return texture_signature(obj)
	if obj is Node:
		return "n%d" % obj.get_instance_id()
	var parts := PackedStringArray()
	parts.append(obj.get_class())
	for prop in obj.get_property_list():
		var usage: int = prop["usage"]
		if not (usage & PROPERTY_USAGE_STORAGE):
			continue
		var pname: String = prop["name"]
		if pname.begins_with("resource_") or pname == "script":
			continue
		parts.append("%s=%s" % [pname, of_value(obj.get(pname), depth + 1)])
	return "(" + ";".join(parts) + ")"

static func texture_signature(texture: Texture2D) -> String:
	if texture == null:
		return "tex-null"
	var id := texture.get_instance_id()
	if _image_hash_cache.has(id):
		return _image_hash_cache[id]
	var image := texture.get_image()
	var sig := "tex%d" % id
	if image != null:
		sig = "tex:%d:%s" % [hash(image.get_data()), str(image.get_size())]
	_image_hash_cache[id] = sig
	if not texture.changed.is_connected(_forget.bind(id)):
		texture.changed.connect(_forget.bind(id))
	return sig

static func _forget(id: int) -> void:
	_image_hash_cache.erase(id)
