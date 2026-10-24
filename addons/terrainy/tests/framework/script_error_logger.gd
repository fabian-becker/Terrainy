extends Logger

## Only script errors are fatal to the test harness. Engine diagnostics from intentional
## push_error() probes, warnings, and renderer shutdown leak reports are not script errors.
## Godot can call this logger on worker threads: never call the runner or print here.
var _mutex := Mutex.new()
var _context: String = "suite startup"
var _errors: Array[String] = []

func set_context(context: String) -> void:
	_mutex.lock()
	_context = context
	_mutex.unlock()

func take_errors() -> Array[String]:
	_mutex.lock()
	var errors: Array[String] = _errors
	_errors = []
	_mutex.unlock()
	return errors

func _log_error(function: String, file: String, line: int, code: String,
		rationale: String, _editor_notify: bool, error_type: int,
		_script_backtraces: Array[ScriptBacktrace]) -> void:
	if error_type != Logger.ERROR_TYPE_SCRIPT:
		return
	var detail: String = rationale if not rationale.is_empty() else code
	_mutex.lock()
	_errors.append("%s: SCRIPT ERROR: %s (%s:%d in %s)" % [
		_context, detail, file, line, function
	])
	_mutex.unlock()
