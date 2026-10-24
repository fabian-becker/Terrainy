extends SceneTree

## Dependency-free headless test runner for Terrainy 2 (ported 0.x harness).
##
## Usage:
##     godot --headless --path . --script res://addons/terrainy/tests/run_tests.gd
##
## Options (pass after a bare `--`):
##     --verbose             print one line per test instead of only failures
##     --filter=<substring>  only run tests whose "<case>::<test>" label contains the
##                           substring (repeatable)
##
## Exits with code 0 when every test passes, 1 otherwise, so CI can rely on the exit code.

const SETTLE_FRAMES: int = 5

const TestRunner = preload("res://addons/terrainy/tests/framework/test_runner.gd")

## Loaded after the logger is installed (see the 0.x harness notes).
const CASES: PackedStringArray = [
	"res://addons/terrainy/tests/cases/test_eval_core.gd",
	"res://addons/terrainy/tests/cases/test_scale_invariance.gd",
	"res://addons/terrainy/tests/cases/test_mesh_seams.gd",
	"res://addons/terrainy/tests/cases/test_field_composition.gd",
	"res://addons/terrainy/tests/cases/test_corridor_domain.gd",
	"res://addons/terrainy/tests/cases/test_hierarchy_composition.gd",
	"res://addons/terrainy/tests/cases/test_masks.gd",
	"res://addons/terrainy/tests/cases/test_modifiers.gd",
	"res://addons/terrainy/tests/cases/test_heightmap_node.gd",
	"res://addons/terrainy/tests/cases/test_paint_layers.gd",
	"res://addons/terrainy/tests/cases/test_texture_paint.gd",
	"res://addons/terrainy/tests/cases/test_chunks_collision.gd",
	"res://addons/terrainy/tests/cases/test_holes.gd",
	"res://addons/terrainy/tests/cases/test_navigation.gd",
	"res://addons/terrainy/tests/cases/test_scatter.gd",
	"res://addons/terrainy/tests/cases/test_material.gd",
	"res://addons/terrainy/tests/cases/test_api.gd",
	"res://addons/terrainy/tests/cases/test_bake.gd",
	"res://addons/terrainy/tests/cases/test_async_pipeline.gd",
	"res://addons/terrainy/tests/cases/test_editor_tools.gd",
	"res://addons/terrainy/tests/cases/test_demo.gd",
	"res://addons/terrainy/tests/cases/test_namespace.gd",
	"res://addons/terrainy/tests/cases/test_gpu_parity.gd",
]

var _runner = null
var _ran: bool = false
var _settle_frames: int = 0

func _initialize() -> void:
	_runner = TestRunner.new()
	_runner.start_error_capture()
	_parse_user_args(_runner)

func _process(_delta: float) -> bool:
	if not _ran:
		_ran = true
		var start := Time.get_ticks_msec()
		for case_path in _get_case_paths():
			_runner.set_error_context("loading %s" % case_path)
			var case_script = load(case_path)
			if case_script is Script:
				_runner.run_case(case_script, self)
			else:
				_runner.fail_suite("Could not load test case: %s" % case_path)
		_runner.set_error_context("suite deferred processing / teardown")
		print("Suite finished in %d ms" % (Time.get_ticks_msec() - start))
		return false
	_settle_frames += 1
	if _settle_frames < SETTLE_FRAMES:
		return false
	_runner.set_error_context("suite final frame / tree shutdown")
	quit(1)
	return true

func _finalize() -> void:
	if _runner != null:
		quit(_runner.report())
		_runner.stop_error_capture()

func _get_case_paths() -> PackedStringArray:
	return CASES

func _parse_user_args(runner) -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--verbose":
			runner.verbose = true
		elif arg.begins_with("--filter="):
			runner.filters.append(arg.trim_prefix("--filter="))
