extends SceneTree

## LOD / streaming flythrough benchmark (track B, headless).
##
##     godot --headless --path . --script res://tests/perf/benchmark_lod_flythrough.gd -- --cells=2048
##
## The acceptance criterion for track B is not "a rebuild is fast" but "flying a camera across a
## large terrain never blocks the frame". This script builds a terrain, parks a camera at one edge
## and flies it across at a fixed speed, driving the applier's main-thread step by hand and timing
## it. Reported per frame:
##
##   * the applier step (mesh commit + collision commit + LOD/residency + job assembly), which is
##     the work `chunk_apply_budget_ms` bounds;
##   * how much of that the scheduler charged, and how many frames overshot the budget (one unit is
##     allowed to overshoot by design, D7.1 rule 2);
##   * LOD changes and flips, streamed-out chunks and queued work, so a thrashing LOD policy or a
##     queue that never drains shows up as a number instead of a rumour.
##
## Exit code is always 0: the numbers are the verdict, not the process status.

const CELLS := 2048
const CHUNK_CELLS := 128
const BUDGET_MS := 8
const FLY_FRAMES := 900
## Metres per frame at 60 fps: 40 m/frame = 2400 m/s, an aggressive flythrough.
const SPEED_PER_FRAME := 2.2
const CAMERA_HEIGHT := 120.0

var _cells := CELLS
var _budget_ms := BUDGET_MS
var _view_distance := 1200.0
var _gen: TerrainGenerator = null
var _camera: Camera3D = null
var _stage := 0
var _frame := 0
var _t0 := 0
var _frames_ms: Array[float] = []
var _charged_ms: Array[float] = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cells="):
			_cells = int(arg.split("=")[1])
		elif arg.begins_with("--budget="):
			_budget_ms = int(arg.split("=")[1])
		elif arg.begins_with("--view="):
			_view_distance = float(arg.split("=")[1])
		elif arg.begins_with("--frames="):
			_frame = -int(arg.split("=")[1])  # encoded, see _process

func _process(_delta: float) -> bool:
	match _stage:
		0:
			_build()
			_stage = 1
		1:
			# One frame after the build so the generator's _ready has run and the camera is current.
			_camera = Camera3D.new()
			_camera.fov = 70.0
			root.add_child(_camera)
			var half := float(_cells) * 0.5
			_camera.global_position = Vector3(-half + 60.0, CAMERA_HEIGHT, -half + 60.0)
			_camera.look_at(Vector3(-half + 600.0, 0.0, -half + 60.0))
			_camera.current = true
			_gen._applier.lod.invalidate()
			_stage = 2
			_print_header()
		2:
			_tick()
			if _frame >= FLY_FRAMES:
				_report()
				quit(0)
				return true
	return false

func _build() -> void:
	_gen = TerrainGenerator.new()
	_gen.terrain_resolution = _cells
	_gen.terrain_size = float(_cells)
	_gen.chunk_size = CHUNK_CELLS
	_gen.chunk_apply_budget_ms = _budget_ms
	_gen.enable_lod = true
	_gen.lod_auto = true
	_gen.lod_levels = 3
	_gen.lod_hysteresis = 0.15
	_gen.view_distance = _view_distance
	root.add_child(_gen)
	# Unbudgeted first build: the point of the measurement is the steady state, not the load.
	_gen.rebuild_now()
	_gen.set_process(false)

func _tick() -> void:
	var now := Time.get_ticks_msec()
	# Fly along +X, so the camera crosses chunk columns one after another.
	_camera.global_position.x += SPEED_PER_FRAME
	_camera.look_at(Vector3(_camera.global_position.x + 600.0, 0.0, _camera.global_position.z))
	var t0 := Time.get_ticks_usec()
	_gen._applier.process(now)
	_frames_ms.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	_charged_ms.append(_gen._applier.scheduler.spent_ms())
	_frame += 1

func _print_header() -> void:
	var chunks: int = _gen.get_chunk_manager().chunks.size()
	print("================================================================")
	print("Terrainy 2 LOD / streaming flythrough")
	print("resolution=%d cells (%.0f m) | %d chunks | chunk=%d cells | lod_levels=3 | hysteresis=0.15" % [
		_cells, float(_cells), chunks, CHUNK_CELLS])
	print("budget=%d ms | view_distance=%.0f m | %d frames at %.0f m/frame" % [
		_budget_ms, _view_distance, FLY_FRAMES, SPEED_PER_FRAME])
	print("================================================================")

func _report() -> void:
	_frames_ms.sort()
	var total := 0.0
	var peak := 0.0
	var over := 0
	for ms in _frames_ms:
		total += ms
		peak = maxf(peak, ms)
	var n := _frames_ms.size()
	var mean := total / maxf(float(n), 1.0)
	var p95: float = _frames_ms[clampi(int(float(n) * 0.95), 0, n - 1)]
	var over_budget := 0
	for ms in _frames_ms:
		if ms > float(_budget_ms):
			over_budget += 1
	var charged_peak := 0.0
	for ms in _charged_ms:
		charged_peak = maxf(charged_peak, ms)
	var diag := _gen.get_diagnostics()
	var sched: Dictionary = diag["scheduler"]
	var lod: Dictionary = diag["lod"]
	var streaming: Dictionary = diag.get("streaming", {})
	print("applier step per frame: mean %.3f ms | p95 %.3f ms | peak %.3f ms" % [mean, p95, peak])
	print("frames over budget (%d ms): %d of %d (%.1f %%)" % [_budget_ms, over_budget, n,
		100.0 * float(over_budget) / maxf(float(n), 1.0)])
	print("scheduler charged: peak %.3f ms | %s" % [charged_peak, str(sched)])
	print("lod: %s" % str(lod))
	print("streaming: resident=%d streamed_out=%d" % [
		int(diag["resident_chunks"]), int(diag["streamed_out_chunks"])])
	print("worst frame <= budget + one unit (%.1f ms)?  %s" % [
		float(_budget_ms) * 2.0, "yes" if peak <= float(_budget_ms) * 2.0 else "NO"])
	print("mean under budget?  %s" % ("yes" if mean <= float(_budget_ms) else "NO"))
	print("no LOD flips?  %s" % ("yes" if int(lod["flips"]) == 0 else "NO (%d)" % int(lod["flips"])))
