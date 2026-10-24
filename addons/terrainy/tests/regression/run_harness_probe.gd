extends "res://addons/terrainy/tests/run_tests.gd"

## Intentionally faulty cases run ONLY in child processes of verify_harness.gd.
var _invalid_case_path: String = ""

func _get_case_paths() -> PackedStringArray:
	if OS.get_cmdline_user_args()[0] == "case_load_parse_error":
		# Write a real case resource, not GDScript.reload() inside a running test.
		# Keep invalid syntax out of the project so normal editor imports stay clean.
		_invalid_case_path = "user://terrainy_harness_invalid_case_%d.gd" % OS.get_process_id()
		var file := FileAccess.open(_invalid_case_path, FileAccess.WRITE)
		if file != null:
			file.store_string("extends RefCounted\nfunc broken(:\n")
			file.close()
		return [_invalid_case_path]
	return ["res://addons/terrainy/tests/regression/harness_probe.gd"]

func _finalize() -> void:
	if not _invalid_case_path.is_empty():
		DirAccess.remove_absolute(_invalid_case_path)
	super._finalize()
