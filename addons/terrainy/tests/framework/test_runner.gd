extends RefCounted

## Minimal dependency-free assertion and reporting helper for the Terrainy 2 headless tests.
##
## Deliberately tiny (no vendored test framework) so that the suite can run in CI with a
## plain Godot binary:
##
##     godot --headless --path . --script res://addons/terrainy/tests/run_tests.gd
##
## Test cases extend addons/terrainy/tests/framework/test_case.gd and expose methods
## prefixed with `test_`.

## Assertions executed so far.
var total_checks: int = 0
## One entry per failed assertion, formatted as "<case>::<test>: <message>".
var failures: Array[String] = []
var passed_tests: int = 0
var failed_tests: int = 0
var skipped_tests: int = 0
var skipped_reasons: Array[String] = []
## Print a line for every test instead of only for failures.
var verbose: bool = false
## Only run tests whose "<case>::<test>" label contains one of these substrings.
var filters: PackedStringArray = PackedStringArray()

var _case_name: String = ""
var _test_name: String = ""
var _test_failed: bool = false
var _test_skipped: bool = false
var _script_errors = null
var runtime_errors: int = 0

## Register before loading cases so parse/load errors are observed as well as runtime
## errors. The entry point keeps this active through fixture settling and root teardown.
func start_error_capture() -> void:
	if _script_errors != null:
		return
	_script_errors = preload("res://addons/terrainy/tests/framework/script_error_logger.gd").new()
	OS.add_logger(_script_errors)

func stop_error_capture() -> void:
	if _script_errors != null:
		OS.remove_logger(_script_errors)
		_script_errors = null

func set_error_context(context: String) -> void:
	if _script_errors != null:
		_script_errors.set_context(context)

func fail_suite(message: String) -> void:
	failures.append(message)

func _collect_script_errors() -> void:
	if _script_errors == null:
		return
	for error in _script_errors.take_errors():
		runtime_errors += 1
		_test_failed = true
		failures.append(error)

## Run every `test_*` method of `case_script` and report per-test results.
func run_case(case_script: Script, tree: SceneTree) -> void:
	# Direct framework callers also get capture; the suite starts it earlier to cover load().
	start_error_capture()
	_collect_script_errors()
	_case_name = case_script.resource_path.get_file().get_basename()
	_test_name = "new"
	_test_failed = false
	set_error_context("%s::%s" % [_case_name, _test_name])
	if not case_script.can_instantiate():
		_fail("case script cannot be instantiated")
		return
	var test_case = case_script.new()
	_collect_script_errors()
	if test_case == null:
		_fail("case script returned a null instance")
		return
	test_case.t = self
	test_case.tree = tree
	_test_name = "before_all"
	set_error_context("%s::%s" % [_case_name, _test_name])
	test_case.before_all()
	_collect_script_errors()
	# Do not turn tests with broken fixture setup into apparent passes.
	if not _test_failed:
		for method in test_case.get_method_list():
			var method_name: String = method["name"]
			if not method_name.begins_with("test_"):
				continue
			_test_name = method_name
			if not _matches_filter():
				continue
			_test_failed = false
			_test_skipped = false
			set_error_context("%s::%s" % [_case_name, _test_name])
			var checks_before: int = total_checks
			test_case.call(method_name)
			_collect_script_errors()
			var new_checks: int = total_checks - checks_before
			# A skip never masks an assertion failure or a script error.
			if _test_failed:
				failed_tests += 1
				print("FAIL  %s::%s" % [_case_name, _test_name])
			elif _test_skipped:
				skipped_tests += 1
				print("SKIP  %s::%s" % [_case_name, _test_name])
			else:
				passed_tests += 1
				if verbose:
					print("ok    %s::%s (%d checks)" % [_case_name, _test_name, new_checks])
	_test_name = "after_all"
	set_error_context("%s::%s" % [_case_name, _test_name])
	test_case.after_all()
	_collect_script_errors()
	set_error_context("suite deferred processing / teardown")

## Print the final summary and return the process exit code.
func report() -> int:
	_collect_script_errors()
	print("")
	print("Terrainy 2 test suite")
	print("  tests:   %d passed, %d failed, %d skipped" % [passed_tests, failed_tests, skipped_tests])
	print("  checks:  %d" % total_checks)
	print("  script errors: %d" % runtime_errors)
	if not skipped_reasons.is_empty():
		print("  skipped reasons:")
		for reason in skipped_reasons:
			print("    - %s" % reason)
	if failures.is_empty():
		print("  result:  PASS")
		return 0
	print("  failures:")
	for failure in failures:
		print("    - %s" % failure)
	print("  result:  FAIL")
	return 1

## Mark the current test as skipped (call `return` right after).
func skip(reason: String) -> void:
	_test_skipped = true
	skipped_reasons.append("%s::%s: %s" % [_case_name, _test_name, reason])

func check(condition: bool, message: String) -> void:
	total_checks += 1
	if not condition:
		_fail(message)

func check_eq(actual, expected, message: String) -> void:
	total_checks += 1
	if actual != expected:
		_fail("%s (expected %s, got %s)" % [message, _to_text(expected), _to_text(actual)])

func check_not_eq(actual, unexpected, message: String) -> void:
	total_checks += 1
	if actual == unexpected:
		_fail("%s (value should differ from %s)" % [message, _to_text(unexpected)])

func check_almost_eq(actual: float, expected: float, message: String, tolerance: float = 0.001) -> void:
	total_checks += 1
	if not is_finite(actual) or absf(actual - expected) > tolerance:
		_fail("%s (expected %.6f +/- %s, got %.6f)" % [message, expected, str(tolerance), actual])

func check_in_range(value: float, minimum: float, maximum: float, message: String) -> void:
	total_checks += 1
	if not is_finite(value) or value < minimum or value > maximum:
		_fail("%s (expected %.6f..%.6f, got %.6f)" % [message, minimum, maximum, value])

## Compare two single-channel heightmaps pixel by pixel.
func check_images_match(actual: Image, expected: Image, message: String, tolerance: float = 0.001) -> void:
	total_checks += 1
	if actual == null or expected == null:
		_fail("%s (null image: actual valid=%s, expected valid=%s)" % [message, actual != null, expected != null])
		return
	if actual.get_width() != expected.get_width() or actual.get_height() != expected.get_height():
		_fail("%s (size mismatch %dx%d vs %dx%d)" % [
			message, actual.get_width(), actual.get_height(), expected.get_width(), expected.get_height()
		])
		return
	var actual_data := actual.get_data().to_float32_array()
	var expected_data := expected.get_data().to_float32_array()
	if actual_data.size() != expected_data.size():
		_fail("%s (data size mismatch %d vs %d)" % [message, actual_data.size(), expected_data.size()])
		return
	var worst_diff: float = 0.0
	var worst_index: int = -1
	for i in actual_data.size():
		var diff: float = absf(actual_data[i] - expected_data[i])
		if diff > worst_diff:
			worst_diff = diff
			worst_index = i
	if worst_diff > tolerance:
		_fail("%s (max difference %.6f at index %d: %.6f vs %.6f)" % [
			message, worst_diff, worst_index, actual_data[worst_index], expected_data[worst_index]
		])

## Difference statistics of two heightmaps, used by the CPU/GPU parity cases.
## Returns {"max": float, "mean": float, "count": int}.
func image_difference(a: Image, b: Image) -> Dictionary:
	if a == null or b == null or a.get_size() != b.get_size():
		return {"max": INF, "mean": INF, "count": 0}
	var a_data := a.get_data().to_float32_array()
	var b_data := b.get_data().to_float32_array()
	var worst: float = 0.0
	var total: float = 0.0
	var count: int = mini(a_data.size(), b_data.size())
	for i in count:
		var diff: float = absf(a_data[i] - b_data[i])
		worst = maxf(worst, diff)
		total += diff
	return {"max": worst, "mean": total / maxf(float(count), 1.0), "count": count}

func image_max(image: Image) -> float:
	if image == null:
		return NAN
	var data := image.get_data().to_float32_array()
	var result: float = -INF
	for value in data:
		result = maxf(result, value)
	return result

func image_min(image: Image) -> float:
	if image == null:
		return NAN
	var data := image.get_data().to_float32_array()
	var result: float = INF
	for value in data:
		result = minf(result, value)
	return result

## Number of distinct values, grouped with a tolerance (used to verify terracing steps).
func image_count_distinct(image: Image, tolerance: float = 0.001) -> int:
	if image == null:
		return 0
	var data := image.get_data().to_float32_array()
	var buckets := PackedFloat32Array()
	for value in data:
		var found := false
		for bucket in buckets:
			if absf(bucket - value) <= tolerance:
				found = true
				break
		if not found:
			buckets.append(value)
	return buckets.size()

func _fail(message: String) -> void:
	_test_failed = true
	failures.append("%s::%s: %s" % [_case_name, _test_name, message])

func _matches_filter() -> bool:
	if filters.is_empty():
		return true
	var label := "%s::%s" % [_case_name, _test_name]
	for filter in filters:
		if label.contains(filter):
			return true
	return false

func _to_text(value) -> String:
	if value is float:
		return "%.6f" % value
	return str(value)
