extends SceneTree

## Terrainy 2 frame-budget benchmark (headless).
##
## Usage:
##     godot --headless --path . --script res://tests/perf/benchmark_frame_budget.gd
##     godot --headless --path . --script res://tests/perf/benchmark_frame_budget.gd -- --cells=1024
##
## The design's performance contract is not "a rebuild finishes in N seconds" but "generation
## never blocks the game/editor frame": a full recompose may take as long as it likes over many
## frames as long as each frame's main-thread work stays inside `chunk_apply_budget_ms`. This
## script measures exactly that side: it queues a full recompose, then drives the generator's
## main-thread step by hand and times it, so the reported numbers are the generator's own
## per-frame cost rather than the whole loop's.
##
## `benchmark.gd` measures the other side (total stage cost). Exit code is always 0.
##
## The generator is stepped with `set_process(false)` + a manual `_process()` call, which is the
## same thing the headless test harness does to drive a rebuild deterministically.

const CELLS := 512
const SIZE := 512.0
const BUDGET_MS := 8
const FRAME_MS := 16.0
## Frames to allow before giving up, so a stuck rebuild cannot hang the tool.
const MAX_FRAMES := 60000

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cells="):
			_cells = int(arg.split("=")[1])
		elif arg.begins_with("--budget="):
			_budget_ms = int(arg.split("=")[1])

var _cells := CELLS
var _budget_ms := BUDGET_MS
var _gen: TerrainGenerator = null
var _frames: Array[float] = []
var _started_usec := 0

func _process(_delta: float) -> bool:
	if _gen == null:
		_start()
		return false
	return _step()

func _start() -> void:
	_gen = _make_terrain()
	_gen.chunk_apply_budget_ms = _budget_ms
	_gen.rebuild_now()  # settle the initial build first
	# Now a full recompose, applied across frames exactly as the editor would.
	_gen.force_rebuild()
	_gen.set_process(false)  # this script drives the main-thread step instead
	print("================================================================")
	print("Terrainy 2 frame-budget benchmark")
	print("scale=%d cells / %.0f m | chunk_apply_budget_ms=%d | RenderingDevice=%s" % [
		_cells, SIZE, _budget_ms,
		"yes" if RenderingServer.get_rendering_device() != null else "no (CPU worst case)"])
	print("================================================================")
	_started_usec = Time.get_ticks_usec()

## Drive one main-thread step, time it, then pad the frame out to FRAME_MS so the rebuild sees
## realistic frame spacing (spinning frames as fast as possible would both starve the compose
## worker and report a frame cadence no game has).
func _step() -> bool:
	var t0 := Time.get_ticks_usec()
	_gen._process(FRAME_MS / 1000.0)
	_frames.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	var spent_usec := Time.get_ticks_usec() - t0
	var pad_usec := int(FRAME_MS * 1000.0) - spent_usec
	if pad_usec > 0:
		OS.delay_usec(pad_usec)
	if _gen.is_rebuilding() and _frames.size() < MAX_FRAMES:
		return false
	_report()
	quit(0)
	return true

func _report() -> void:
	var total_ms := float(Time.get_ticks_usec() - _started_usec) / 1000.0
	var sorted := _frames.duplicate()
	sorted.sort()
	var over := 0
	var worst := 0.0
	var sum := 0.0
	for f in _frames:
		sum += f
		worst = maxf(worst, f)
		if f > float(_budget_ms):
			over += 1
	var diag: Dictionary = _gen.get_diagnostics()
	var counters: Dictionary = diag["counters"]
	print("")
	print("frames driven:      %d (apply_frames counter: %d)" % [_frames.size(), int(counters.get("apply_frames", 0))])
	print("wall clock:         %.1f ms" % total_ms)
	print("per-frame step (ms): best %.2f | median %.2f | mean %.2f | worst %.2f" % [
		sorted[0], sorted[sorted.size() / 2], sum / float(sorted.size()), worst])
	print("frames over budget: %d of %d (%.1f%%)" % [over, _frames.size(), 100.0 * float(over) / float(_frames.size())])
	print("chunks applied:     %d of %d generated" % [
		int(counters.get("chunks_applied", 0)), int(counters.get("chunks_generated", 0))])
	print("")
	print("The contract is about the *worst* frame: `worst` should sit at or under the budget plus")
	print("the cost of one already-finished result (the budget is checked between results, not")
	print("inside one). A worst frame far above the budget means an unbudgeted step crept back in.")

func _make_terrain() -> TerrainGenerator:
	var gen := TerrainGenerator.new()
	gen.name = "BenchTerrain"
	# Benchmark an exact grid: no "keep the meters per cell" derivation on resize.
	gen.preserve_cell_size = false
	gen.terrain_resolution = _cells
	gen.terrain_size = SIZE
	gen.chunk_size = 128
	gen.navigation_enabled = false
	gen.use_gpu_composition = false
	gen.use_gpu_feature_evaluation = false
	gen.use_gpu_paint = false
	root.add_child(gen)
	var layer := TerrainyTextureLayer.new()
	layer.layer_name = "Grass"
	gen.texture_layers = [layer] as Array[TerrainyTextureLayer]

	var base := TerrainFieldNode.new()
	base.name = "RollingHills"
	base.domain_kind = TerrainTypes.DomainKind.GLOBAL
	base.profile_height = 0.0
	var noise := TerrainReliefSource.new()
	noise.weight = 5.0
	noise.noise.frequency = 0.012
	base.relief_layers = [noise] as Array[TerrainReliefSource]
	gen.add_child(base)

	# A Region field with relief: the shape that dominates real scenes and costs the most per unit.
	var hill := TerrainFieldNode.new()
	hill.name = "Hill"
	hill.position = Vector3(40, 0, 40)
	hill.region_size = Vector2(180, 180)
	hill.profile_height = 40.0
	var hill_noise := TerrainReliefSource.new()
	hill_noise.weight = 8.0
	hill_noise.noise.frequency = 0.03
	hill.relief_layers = [hill_noise] as Array[TerrainReliefSource]
	gen.add_child(hill)
	return gen
