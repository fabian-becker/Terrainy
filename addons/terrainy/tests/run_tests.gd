extends SceneTree

## Dependency-free headless test runner for the Terrainy addon.
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

## Number of frames the tree keeps running after the tests so that the fixtures freed with
## queue_free() (and any rebuild threads they started) are torn down before quitting.
const SETTLE_FRAMES: int = 5

const TestRunner = preload("res://addons/terrainy/tests/framework/test_runner.gd")

const CASES: Array[Script] = [
	preload("res://addons/terrainy/tests/cases/test_heightmap_builder.gd"),
	preload("res://addons/terrainy/tests/cases/test_modifier_pipeline.gd"),
	preload("res://addons/terrainy/tests/cases/test_terrain_mesh_generator.gd"),
	preload("res://addons/terrainy/tests/cases/test_chunk_mesh_jobs.gd"),
	preload("res://addons/terrainy/tests/cases/test_collision_shapes.gd"),
	preload("res://addons/terrainy/tests/cases/test_navigation.gd"),
	preload("res://addons/terrainy/tests/cases/test_diagnostics.gd"),
	preload("res://addons/terrainy/tests/cases/test_material_builder.gd"),
	preload("res://addons/terrainy/tests/cases/test_scatter_manager.gd"),
	preload("res://addons/terrainy/tests/cases/test_deterministic_seeds.gd"),
	preload("res://addons/terrainy/tests/cases/test_height_queries.gd"),
	preload("res://addons/terrainy/tests/cases/test_gpu_parity.gd"),
]

var _runner = null
var _ran: bool = false
var _settle_frames: int = 0

func _initialize() -> void:
	_runner = TestRunner.new()
	_parse_user_args(_runner)

## Tests run in the first frame: a script used as the main loop is initialised before the
## scene tree is entered, so nodes added from _initialize() would never reach the tree and
## would never receive their _ready() callback.
func _process(_delta: float) -> bool:
	if not _ran:
		_ran = true
		var start := Time.get_ticks_msec()
		for case_script in CASES:
			_runner.run_case(case_script, self)
		print("Suite finished in %d ms" % (Time.get_ticks_msec() - start))
		return false
	# The fixtures are released with queue_free(), so let the tree run a couple of frames
	# before quitting: this flushes the deletion queue (and in-flight rebuild threads) and
	# keeps the shutdown free of leak reports.
	_settle_frames += 1
	if _settle_frames < SETTLE_FRAMES:
		return false
	quit(_runner.report())
	return true

func _parse_user_args(runner) -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--verbose":
			runner.verbose = true
		elif arg.begins_with("--filter="):
			runner.filters.append(arg.trim_prefix("--filter="))
