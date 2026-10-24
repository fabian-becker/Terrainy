extends "res://addons/terrainy/tests/framework/test_case.gd"

class DeferredFault extends Node:
	func fail_later() -> void:
		var missing = null
		missing.no_such_method()

class LateFrameFixture extends DeferredFault:
	var frames_left: int = 0
	var faulty: bool = false

	func _process(_delta: float) -> void:
		frames_left -= 1
		if frames_left == 0:
			set_process(false)
			print("HARNESS: final frame reached")
			if faulty:
				call_deferred("fail_later")

class ShutdownFixture extends Node:
	var faulty: bool = false

	func _exit_tree() -> void:
		print("HARNESS: shutdown _exit_tree reached")
		if faulty:
			var missing = null
			missing.no_such_method()

## Never register this case in the normal suite: its faults verify the harness itself.
func _scenario() -> String:
	return OS.get_cmdline_user_args()[0]

func _init() -> void:
	if _scenario() == "constructor_error":
		_runtime_error()

func before_all() -> void:
	if _scenario() == "setup_error":
		_runtime_error()

func after_all() -> void:
	if _scenario() == "teardown_error":
		_runtime_error()
	super.after_all()

func test_probe() -> void:
	match _scenario():
		"runtime_error":
			var missing = null
			missing.no_such_method()
		"bad_argument":
			# The exact navigation regression: dynamic receiver avoids a parse-time check.
			t.check_almost_eq(1.0, 1.0, 0.001, "wrong argument order")
		"nested_error":
			_runtime_error()
			t.check(true, "the caller resumes despite the nested script error")
		"skip_then_error":
			t.skip("a skip must not hide a script error")
			_runtime_error()
		"ordinary_skip":
			t.skip("intentional skip control")
			return
		"push_error":
			push_error("intentional engine error probe (not a script runtime error)")
			t.check(true, "expected engine diagnostics are allowed")
		"assertion_failure":
			t.check_almost_eq(0.0, 1.0, "readable mismatch", 0.0001)
		"deferred_error":
			# A case is RefCounted and expires after run_case(), so use a live fixture
			# node whose deferred call precedes its queued deletion.
			var fixture := DeferredFault.new()
			spawn(fixture)
			fixture.call_deferred("fail_later")
			t.check(true, "error arrives during settling, after the test body")
		"late_frame_error", "late_frame_clean":
			var fixture := LateFrameFixture.new()
			# Nodes process after the main-loop callback, including its quitting frame.
			fixture.frames_left = preload("res://addons/terrainy/tests/run_tests.gd").SETTLE_FRAMES + 1
			fixture.faulty = _scenario() == "late_frame_error"
			tree.root.add_child(fixture)
			t.check(true, "fixture defers its fault from the final processing frame")
		"shutdown_error", "shutdown_clean":
			# Deliberately bypass spawn(): this node must survive fixture settling and
			# only leave the tree when SceneTree.finalize() destroys the root.
			var fixture := ShutdownFixture.new()
			fixture.faulty = _scenario() == "shutdown_error"
			tree.root.add_child(fixture)
			t.check(true, "fixture remains alive until tree shutdown")
		"worker_error":
			var worker := Thread.new()
			worker.start(_runtime_error)
			worker.wait_to_finish()
			# A worker fault must fail the test even when an assertion still succeeds.
			t.check(true, "worker finished")
		"parse_error":
			var invalid_script := GDScript.new()
			invalid_script.source_code = "extends RefCounted\nfunc broken(:\n"
			invalid_script.reload()
			t.check(true, "error is detected without an assertion failure")
		_:
			t.check(true, "clean control / hook scenario")

func _runtime_error() -> void:
	var missing = null
	missing.no_such_method()
