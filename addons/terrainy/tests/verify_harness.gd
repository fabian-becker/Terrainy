extends SceneTree

## End-to-end fault injection: each child uses run_tests.gd's real execution path.
## A successful verification exits 0 even though the faulty children must exit 1.
const SCENARIOS: PackedStringArray = [
	"clean", "ordinary_skip", "push_error", "assertion_failure",
	"runtime_error", "bad_argument", "nested_error", "skip_then_error",
	"constructor_error", "setup_error", "teardown_error", "deferred_error",
	"worker_error", "parse_error", "case_load_parse_error",
	"shutdown_error", "shutdown_clean", "late_frame_error", "late_frame_clean",
]
var _ran: bool = false

func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	var failures: int = 0
	for scenario in SCENARIOS:
		var output: Array = []
		var exit_code: int = OS.execute(OS.get_executable_path(), [
			"--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--script", "res://addons/terrainy/tests/regression/run_harness_probe.gd",
			"--", scenario,
		], output, true)
		var log: String = "\n".join(output)
		var expected_success: bool = scenario in ["clean", "ordinary_skip", "push_error", "shutdown_clean", "late_frame_clean"]
		var valid: bool = exit_code == (0 if expected_success else 1)
		var expected_result: String = "  result:  PASS" if expected_success else "  result:  FAIL"
		var unexpected_result: String = "  result:  FAIL" if expected_success else "  result:  PASS"
		# Exactly one definitive report, never a premature PASS before shutdown faults.
		valid = valid and log.count(expected_result) == 1 and not log.contains(unexpected_result)
		if scenario == "ordinary_skip":
			valid = valid and log.contains("0 passed, 0 failed, 1 skipped")
		elif expected_success:
			valid = valid and log.contains("1 passed, 0 failed, 0 skipped")
		elif scenario == "assertion_failure":
			valid = valid and log.contains("readable mismatch (expected 1.000000 +/- 0.0001, got 0.000000)")
			valid = valid and log.contains("1 failed, 0 skipped")
		else:
			valid = valid and log.contains("SCRIPT ERROR:")
			valid = valid and not log.contains("  script errors: 0")
			if scenario in ["runtime_error", "bad_argument", "nested_error", "skip_then_error", "worker_error", "parse_error"]:
				valid = valid and log.contains("0 passed, 1 failed, 0 skipped")
		if scenario in ["shutdown_error", "shutdown_clean", "late_frame_error", "late_frame_clean"]:
			var marker: String = "HARNESS: shutdown _exit_tree reached" if scenario.begins_with("shutdown_") else "HARNESS: final frame reached"
			valid = valid and log.contains(marker) and log.find(marker) < log.find("Terrainy 2 test suite")
			if not expected_success:
				valid = valid and log.contains("suite final frame / tree shutdown: SCRIPT ERROR:")
				valid = valid and log.contains("1 passed, 0 failed, 0 skipped")
		elif scenario == "case_load_parse_error":
			valid = valid and log.contains("loading user://terrainy_harness_invalid_case_")
			valid = valid and log.contains("SCRIPT ERROR: Parse Error:")
			valid = valid and log.contains("case script cannot be instantiated")
			valid = valid and log.contains("0 passed, 0 failed, 0 skipped") and log.contains("  checks:  0")
		if expected_success or scenario == "assertion_failure":
			valid = valid and log.contains("  script errors: 0")
		if valid:
			print("ok    harness %s (child exit %d)" % [scenario, exit_code])
		else:
			failures += 1
			printerr("FAIL  harness %s (child exit %d)\n%s" % [scenario, exit_code, log])
	print("Harness verification: %d scenarios, %d failures" % [SCENARIOS.size(), failures])
	quit(0 if failures == 0 else 1)
	return true
