extends RefCounted

## Rebuild orchestration: debounce, the compose worker task, and stages 2-6 of the pipeline.
##
## Extracted from TerrainGenerator. It owns the rebuild lifecycle (request → plan scan → worker
## task → result) and the compose job itself; the host owns the commit step (`apply_composition`),
## which writes the result into the node's composition state and hands stage 7 to ChunkApplier.
##
## The host is duck-typed (a TerrainGenerator) and must provide:
##
##   properties: texture_layers, base_height, min_height, max_height, noise_seed,
##               preview_isolate_node, use_gpu_composition, use_gpu_feature_evaluation,
##               use_multithreading, paint_layer_grid
##   methods:    get_grid(), get_terrain_world_rect(), composition_context(grid, palette, owned),
##               get_procedural_map(), get_eval_cache(), get_unit_weights(),
##               get_compose_signature(), get_paint_signature(),
##               set_palette(palette, owned, capture), apply_composition(job)
##
## It emits:
##
##   compose_reused(plan)   nothing that shapes the terrain changed; the host commits the new
##                          plan and refreshes the material without a compose
##   build_failed(message)  the host re-emits terrain_build_failed

const PlanBuilder = preload("res://addons/terrainy/gen/eval/plan_builder.gd")
const Composer = preload("res://addons/terrainy/gen/eval/composer.gd")
const CompositionPlan = preload("res://addons/terrainy/gen/eval/composition_plan.gd")
const PaintStage = preload("res://addons/terrainy/gen/paint/paint_stage.gd")
const ControlMaps = preload("res://addons/terrainy/gen/build/control_maps.gd")
const MaterialBuilder = preload("res://addons/terrainy/gen/build/material_builder.gd")
const HMap = preload("res://addons/terrainy/gen/eval/hmap.gd")
const GpuCompositor = preload("res://addons/terrainy/gen/build/gpu/gpu_compositor.gd")
const GpuFieldEvaluator = preload("res://addons/terrainy/gen/build/gpu/gpu_field_evaluator.gd")

const EDITOR_DEBOUNCE_MS := 150

signal compose_reused(plan)
signal build_failed(message: String)

var host = null
var diagnostics = null

var job: Dictionary = {}
var task_id: int = -1
var requested: bool = false
var due_msec: int = 0
## A layout change (chunk_size) forces a recompose even when the signatures match.
var layout_dirty: bool = true
var rebuild_id: int = 0

var _gpu_fields = null

func _init(p_host) -> void:
	host = p_host

# --- Lifecycle ------------------------------------------------------------------------------

## Queue a rebuild, debounced in the editor so dragging a slider does not compose per frame.
func request(immediate: bool = false) -> void:
	requested = true
	var delay := EDITOR_DEBOUNCE_MS if Engine.is_editor_hint() and not immediate else 0
	due_msec = Time.get_ticks_msec() + delay
	host.set_process(true)

## One main-thread step: publish a finished task, then start the queued one when it is due.
func process(now_msec: int) -> void:
	poll_task()
	if requested and task_id < 0 and job.is_empty() and now_msec >= due_msec:
		requested = false
		start()

func is_rebuilding() -> bool:
	return requested or task_id >= 0 or not job.is_empty()

## Rebuild synchronously (bakes, tests, tools): composes on the calling thread. The host drains
## stage 7 afterwards.
func rebuild_now() -> void:
	wait_for_task()
	requested = false
	start(true)
	wait_for_task()
	poll_task()

func wait_for_task() -> void:
	if task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(task_id)

func poll_task() -> void:
	if job.is_empty():
		return
	if task_id >= 0:
		if not WorkerThreadPool.is_task_completed(task_id):
			return
		WorkerThreadPool.wait_for_task_completion(task_id)
		task_id = -1
	var finished := job
	job = {}
	if not finished.has("result"):
		var msg := "terrainy: composition failed (rebuild #%d)" % finished["rebuild_id"]
		push_error(msg)
		build_failed.emit(msg)
		return
	host.apply_composition(finished)

# --- Plan scan and job construction ---------------------------------------------------------

func start(synchronous: bool = false) -> void:
	rebuild_id += 1
	diagnostics.begin_rebuild(rebuild_id)
	var t0 := Time.get_ticks_msec()
	var grid = host.get_grid()
	var palette: Array = []
	for layer in host.texture_layers:
		palette.append(layer)
	# PlanBuilder appends contribution-owned palette indices into this array (shared by
	# reference), so it must be the same array capture_palette() then reads.
	var owned: Array = []
	var plan = PlanBuilder.build(host, host.composition_context(grid, palette, owned))
	var gen_y: float = host.global_position.y if host.is_inside_tree() else host.position.y
	var palette_capture: Array = MaterialBuilder.capture_palette(palette, owned, gen_y)
	host.set_palette(palette, owned, palette_capture)
	diagnostics.record("plan", Time.get_ticks_msec() - t0)
	diagnostics.count("units", plan.unit_count)
	var compose_sig := "%s|%s|%s|%s|%s|%s|%d" % [
		var_to_str(grid.signature()), var_to_str(host.base_height), var_to_str(host.min_height),
		var_to_str(host.max_height), var_to_str(gen_y), plan.signature, int(host.use_gpu_composition) ]
	var paint_parts := PackedStringArray()
	for layer in plan.paint_layers:
		paint_parts.append(layer["signature"])
	var paint_sig := ",".join(paint_parts) + "|holes:" + str(plan.holes.map(func(h): return h["signature"])) \
		+ "|palette:" + var_to_str(palette_capture) + "|pg:%d" % host.paint_layer_grid
	var procedural = host.get_procedural_map()
	var reuse_procedural: bool = compose_sig == host.get_compose_signature() and procedural != null
	if reuse_procedural and paint_sig == host.get_paint_signature() and not layout_dirty:
		# Nothing that shapes the terrain changed (e.g. a scatter or material-only edit).
		diagnostics.count("compose_reused")
		compose_reused.emit(plan)
		return
	# Field snapshot signatures do not include the grid, so maps evaluated on a different grid
	# must not be reused (they are in that grid's sample coordinates).
	var same_grid: bool = var_to_str(grid.signature()) == host.get_eval_grid_signature()
	var eval_cache: Dictionary = host.get_eval_cache() if same_grid else {}
	var new_job := {
		"plan": plan, "grid": grid, "base_height": host.base_height, "min_height": host.min_height,
		"max_height": host.max_height, "previous_cache": eval_cache, "reuse_procedural": reuse_procedural,
		"procedural": procedural if reuse_procedural else null,
		"unit_weights": host.get_unit_weights() if reuse_procedural else {},
		"world": host.get_terrain_world_rect(), "palette": palette_capture, "paint_grid": host.paint_layer_grid,
		"generator_y": gen_y, "compose_sig": compose_sig, "paint_sig": paint_sig,
		"paint_epoch": host.get_paint_epoch(), "rebuild_id": rebuild_id,
		"injected": {}, "gpu_blend": false,
	}
	# GPU field evaluation runs on the main thread (local RenderingDevices are main-thread only)
	# before the worker starts; its maps are injected into the composer's cache.
	if not reuse_procedural and host.use_gpu_feature_evaluation and GpuFieldEvaluator.is_available():
		if _gpu_fields == null:
			_gpu_fields = GpuFieldEvaluator.new()
		var injected := {}
		for unit in plan.all_units():
			if unit.kind == CompositionPlan.UnitKind.FIELD and unit.snap.is_gpu_capable() \
					and not eval_cache.has(unit.snap.signature) and not injected.has(unit.snap.signature):
				var ev = _gpu_fields.evaluate(unit.snap, grid)
				if not ev.is_empty():
					injected[unit.snap.signature] = ev
		new_job["injected"] = injected
		diagnostics.count("gpu_fields", injected.size())
	var threaded: bool = host.use_multithreading and not synchronous
	if not threaded and host.use_gpu_composition and GpuCompositor.is_available():
		new_job["gpu_blend"] = true
	job = new_job
	if threaded:
		task_id = WorkerThreadPool.add_task(run_compose_job.bind(job), false, "terrainy compose")
	else:
		run_compose_job(job)
		poll_task()

# --- Stages 2-6 -----------------------------------------------------------------------------

## Worker safe: only touches the job dictionary and the immutable plan snapshots.
static func run_compose_job(job: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	var grid = job["grid"]
	var plan = job["plan"]
	var procedural
	var unit_weights: Dictionary
	var cache: Dictionary
	if job["reuse_procedural"]:
		procedural = job["procedural"]
		unit_weights = job["unit_weights"]
		cache = job["previous_cache"]
	else:
		var composer := Composer.new()
		composer.previous_cache = job["previous_cache"]
		composer.injected = job["injected"]
		if job.get("gpu_blend", false):
			composer.gpu_blend_hook = GpuCompositor.blend
		procedural = composer.compose(plan, grid, job["base_height"], job["min_height"], job["max_height"])
		unit_weights = composer.unit_weights
		cache = composer.cache
		job["evaluated"] = composer.evaluated
		job["reused"] = composer.reused
	var t1 := Time.get_ticks_msec()
	var world: Rect2 = job["world"]
	var final_map
	if PaintStage.has_height_layers(plan.paint_layers):
		final_map = PaintStage.apply_region(procedural, grid, plan.paint_layers, grid.full_rect(), world)
	else:
		final_map = procedural.duplicate_map()
	var t2 := Time.get_ticks_msec()
	var holes = compute_holes(plan.holes, final_map, grid, job["generator_y"], false)
	var nav_holes = compute_holes(plan.holes, final_map, grid, job["generator_y"], true)
	var units: Array = []
	for unit in plan.all_units():
		if not unit.contributions.is_empty():
			units.append({"node_id": unit.node_id, "contributions": unit.contributions})
	var planes := ControlMaps.build(grid, world, final_map, units, unit_weights, plan.paint_layers, job["palette"], job["paint_grid"])
	planes["units"] = units
	var t3 := Time.get_ticks_msec()
	job["result"] = {
		"procedural": procedural, "final": final_map, "holes": holes, "nav_holes": nav_holes,
		"planes": planes, "unit_weights": unit_weights, "cache": cache,
		"timings": {"compose": t1 - t0, "paint": t2 - t1, "controls": t3 - t2},
	}

## Hole masks (1 = hole) over the full grid, or null when no hole carves anything.
static func compute_holes(holes: Array, final_map, grid, generator_y: float, navigation_only: bool):
	var mask = null
	for snap in holes:
		if navigation_only and not snap["punches_navigation"]:
			continue
		var rect: Rect2i = grid.rect_for_world(snap["bounds"], 1)
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		if mask == null:
			mask = HMap.new(grid.full_rect())
		var md: PackedFloat32Array = mask.data
		for y in rect.size.y:
			var gy := rect.position.y + y
			var wz: float = grid.origin.y + gy * grid.cell
			for x in rect.size.x:
				var gx := rect.position.x + x
				var i: int = gy * grid.samples + gx
				var world := Vector3(grid.origin.x + gx * grid.cell, generator_y + final_map.data[i], wz)
				if TerrainHoleNode.snapshot_contains(snap, world):
					md[i] = 1.0
	return mask
