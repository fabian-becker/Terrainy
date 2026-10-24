extends "res://addons/terrainy/tests/framework/test_case.gd"

## Compatibility rules (§10): no global class name collides with another addon, no file reaches
## into another addon, no water anywhere in terrainy.
##
## 0.x used to sit next to this addon (2.0 was `addons/terrainy2`, 0.x `addons/terrainy`). The
## working tree moved 2.0 into `addons/terrainy` and removed 0.x, so "the other addon" is now
## whatever else lives under `res://addons` — a hardcoded sibling path would compare terrainy
## with itself. The tests skip while no other addon is present and re-arm as soon as one is.

const ROOT := "res://addons/terrainy"

## Every addon root except ours: colliding with one of them is what §10 guards against.
func _other_addon_roots() -> PackedStringArray:
	var roots := PackedStringArray()
	for dir in DirAccess.get_directories_at("res://addons"):
		var path := "res://addons/%s" % dir
		if path != ROOT:
			roots.append(path)
	return roots

func _scripts(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd") or f.ends_with(".gdshader") or f.ends_with(".glsl"):
			out.append(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		_scripts(dir + "/" + d, out)

func _class_names(dir: String) -> Dictionary:
	var names := {}
	var files: Array = []
	_scripts(dir, files)
	var re := RegEx.create_from_string("(?m)^class_name\\s+(\\w+)")
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		for m in re.search_all(text):
			names[m.get_string(1)] = path
	return names

func test_no_class_name_collides_with_0x() -> void:
	var mine := _class_names(ROOT)
	t.check(mine.size() >= 20, "terrainy exposes its node/resource classes (%d)" % mine.size())
	var others := _other_addon_roots()
	if others.is_empty():
		t.skip("no other addon under res://addons to collide with")
		return
	for other in others:
		var theirs := _class_names(other)
		for name in mine:
			t.check(not theirs.has(name), "class_name %s does not collide with %s" % [name, other])

func test_no_shared_code_path_and_no_water() -> void:
	var others := _other_addon_roots()
	var files: Array = []
	_scripts(ROOT, files)
	for path in files:
		if path.contains("/tests/cases/test_namespace.gd"):
			continue
		var text := FileAccess.get_file_as_string(path)
		for other in others:
			t.check(not text.contains(other + "/"), "%s does not depend on %s" % [path.get_file(), other])
		t.check(not text.to_lower().contains("water_level") and not text.contains("WaterNode"), "%s has no water path" % path.get_file())
