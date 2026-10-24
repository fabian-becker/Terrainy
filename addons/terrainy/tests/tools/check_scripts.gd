extends SceneTree

## Loads every GDScript of the terrainy addon and reports which fail to compile
## (dev helper: `godot --headless --path . --script res://addons/terrainy/tests/tools/check_scripts.gd`).

func _initialize() -> void:
	var failed := 0
	var files: Array = []
	_collect("res://addons/terrainy", files)
	for path in files:
		var script = load(path)
		if script == null or (script is GDScript and not script.can_instantiate() and not path.contains("plugin")):
			print("FAILED: ", path)
			failed += 1
	print("checked %d scripts, %d failed" % [files.size(), failed])
	quit(1 if failed > 0 else 0)

func _collect(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		_collect(dir + "/" + d, out)
