extends RefCounted

## Stage 7 application: turns a finished composition into chunk meshes, collision, navigation
## regions, scatter placement and LOD, spread across frames by `chunk_apply_budget_ms`.
##
## Extracted from TerrainGenerator. It owns the worker pipeline and the per-chunk work state;
## the host owns the composition (maps, holes), the material and the scene nodes. Every apply
## step checks the frame budget between results, never inside one, which is what makes the
## "generation never blocks the frame" contract hold.
##
## The host is duck-typed (a TerrainGenerator) and must provide:
##
##   properties: chunk_resolution, chunk_apply_budget_ms, use_multithreading, max_worker_threads,
##               collision_quality, collision_triangle_budget, collision_layer, collision_mask,
##               collision_range, navigation_enabled, navigation_mesh_template,
##               navigation_triangle_budget, navigation_debounce_ms, cast_shadows, enable_lod,
##               lod_distances, lod_auto, lod_pixel_error, lod_levels
##   methods:    get_grid(), get_final_map(), get_final_image(), get_hole_map(),
##               get_navigation_hole_map(), get_chunk_manager(), final_min(), final_max(),
##               current_material(), find_camera(), on_chunks_applied(),
##               effective_worker_threads()
##
## It emits:
##
##   region_updated(aabb)            the host re-emits its terrain_region_updated and the API
##   navigation_baked(mesh, key)     the host re-emits navigation_mesh_baked
##   all_applied                     no mesh work is pending; the host refreshes the material

const ChunkPipeline = preload("res://addons/terrainy/gen/build/chunk_pipeline.gd")
const ChunkJobs = preload("res://addons/terrainy/gen/build/chunk_jobs.gd")
const CollisionBuilder = preload("res://addons/terrainy/gen/build/collision_builder.gd")
const MeshGen = preload("res://addons/terrainy/gen/build/mesh_generator.gd")
const NavigationBuilder = preload("res://addons/terrainy/gen/build/navigation_builder.gd")
const ScatterBuilder = preload("res://addons/terrainy/gen/build/scatter_builder.gd")
const SeamBuilder = preload("res://addons/terrainy/gen/build/seam_builder.gd")
const ChunkScheduler = preload("res://addons/terrainy/gen/build/chunk_scheduler.gd")
const LodController = preload("res://addons/terrainy/gen/build/lod_controller.gd")

signal region_updated(aabb: AABB)
signal navigation_baked(mesh: NavigationMesh, key: Vector2i)
signal all_applied

var host = null
var pipeline = null
## Frame-budget accountant and the chunk work queue (design §10.3).
var scheduler = null
## Distance LOD, hysteresis and the skirt edge mask (design §10.4).
var lod = null
var diagnostics = null
var collision_refresh_pending: bool = false
## Chunk keys still waiting for a collision rebuild after [method refresh_all_collision] queued
## them; [method step_collision_refresh] drains a budgeted slice per frame (DESIGN.md §6.3).
var _collision_refresh_queue: Array = []
var scatter_dirty_all: bool = false
var nav_due_msec: int = 0
var nav_in_flight: int = 0
var scatter_queue: Array = []
## Rebuild id the queued mesh jobs belong to, set by [method dispatch].
var _rebuild_id: int = -1

## Last camera position the LOD pass ran at. Exposed because tools and tests force a re-evaluation
## by setting it to [constant Vector3.INF].
var _lod_camera: Vector3:
	get:
		return lod._camera_pos if lod != null else Vector3.INF
	set(value):
		if lod != null:
			lod._camera_pos = value

## Debug aid: when true, [member process] records the wall time of every step of the frame in
## [member _step_ms], so a trace tool can say which step broke the budget. Off by default, costs
## two clock reads per step when off.
var trace_steps: bool = false
var _step_ms: Dictionary = {}

## Start of the current budgeted apply window (monotonic usec) and whether it was budgeted at all.
## [method can_spend_tail] is answered against these, which is what lets the host push the
## `all_applied` tail (material refresh + rebuild report) to the next frame when this one is spent
## (DESIGN.md §7.4).
var _budget_start_usec: int = 0
var _budgeted_window: bool = false
## Set by [method shutdown]: the host is being torn down, so nothing may touch it any more.
var _detached: bool = false
## Set when the `all_applied` tail could not fit in the applying frame; the host drains it on the
## next frame (DESIGN.md §7.4).
var _tail_deferred: bool = false
## Rolling estimate of what one `all_applied` tail costs in milliseconds (material refresh +
## rebuild report), used by [method can_spend_tail].
var _tail_estimate_ms: float = 2.0

## Step timings of the last [method process] call (empty unless [member trace_steps] is on).
func last_step_ms() -> Dictionary:
	return _step_ms

func _init(p_host) -> void:
	host = p_host
	pipeline = ChunkPipeline.new()
	scheduler = ChunkScheduler.new()
	lod = LodController.new(host)

# --- Frame step -----------------------------------------------------------------------------

## One main-thread step. The budget (`chunk_apply_budget_ms`) is a *deadline* for every stage in
## it, not a per-stage allowance (design D7.1): each stage charges [member scheduler] before it
## starts another unit, so a stage that ran long leaves the next one no time instead of starting
## with a fresh allowance and blowing the frame.
func process(now_msec: int) -> void:
	if scheduler == null or host == null:
		return
	var start_us := Time.get_ticks_usec()
	scheduler.budget_ms = float(host.chunk_apply_budget_ms)
	scheduler.begin_frame(now_msec)
	# Work another stage of this frame already did (the compose commit) is spent before the first
	# unit here, so the apply window is what is *left* of the frame rather than a fresh budget.
	if _frame_charge_ms > 0.0:
		scheduler.spend(_frame_charge_ms)
		if trace_steps:
			# Reported so a trace can tell "the applier was cheap but started with a spent window"
			# from "the applier did nothing at all".
			_step_ms["frame_charge"] = _frame_charge_ms
		_frame_charge_ms = 0.0
	var t0 := start_us
	pipeline.poll()
	if trace_steps:
		_step_ms["poll"] = float(Time.get_ticks_usec() - t0) / 1000.0
	var t := Time.get_ticks_usec()
	if pipeline.has_mesh_results():
		apply_mesh_results(true)
	if trace_steps:
		_step_ms["mesh_apply"] = float(Time.get_ticks_usec() - t) / 1000.0
		t = Time.get_ticks_usec()
	if pipeline.has_collision_results():
		apply_collision_results(true)
	if collision_refresh_pending and not has_mesh_work():
		step_collision_refresh(true)
	if trace_steps:
		_step_ms["collision"] = float(Time.get_ticks_usec() - t) / 1000.0
		t = Time.get_ticks_usec()
	if host.collision_range > 0.0:
		update_collision_range()
	if not scatter_queue.is_empty() or scatter_dirty_all:
		process_scatter_queue()
	if trace_steps:
		_step_ms["scatter"] = float(Time.get_ticks_usec() - t) / 1000.0
		t = Time.get_ticks_usec()
	# LOD, residency and the queue drain run last, on whatever budget the apply stages left.
	if host.get_final_map() != null and (host.enable_lod or host.view_distance > 0.0):
		lod_step()
	if trace_steps:
		_step_ms["lod"] = float(Time.get_ticks_usec() - t) / 1000.0
	# The LOD pass is an O(chunks x neighbours) GDScript evaluation - 10.9 ms mean and 35.0 ms at worst
	# at 2048 cells (RESULTS.md §6) - and it runs before the queue drain. It charged nothing, so a
	# frame could spend it *plus* a fresh 8 ms apply window. Charging it is the same rule every other
	# stage follows (design D7.1 rule 2): what a stage used is gone for the next one.
	scheduler.spend(float(Time.get_ticks_usec() - t) / 1000.0)
	t = Time.get_ticks_usec()
	# The queue must drain even when there is no camera (headless tools, bakes, the first frames of
	# a scene before a viewport camera exists): a queued chunk that nobody dispatches keeps the
	# terrain "rebuilding" forever.
	_drain_queue(true)
	if trace_steps:
		_step_ms["queue"] = float(Time.get_ticks_usec() - t) / 1000.0
		t = Time.get_ticks_usec()
	if host.navigation_enabled and nav_due_msec > 0 and now_msec >= nav_due_msec and not host.is_rebuilding_meshes():
		bake_navigation_step()
	if trace_steps:
		_step_ms["nav"] = float(Time.get_ticks_usec() - t) / 1000.0
		t = Time.get_ticks_usec()
	if host.navigation_enabled:
		apply_navigation_results(true)
	if trace_steps:
		_step_ms["nav_commit"] = float(Time.get_ticks_usec() - t) / 1000.0
	if scheduler.budget_ms > 0.0 and scheduler.spent_ms() > scheduler.budget_ms:
		scheduler.note_overrun(true)
	host.note_frame_work_us(Time.get_ticks_usec() - start_us)
	if trace_steps:
		# What the applier's own step cost in total. Everything a >16 ms frame spends *outside* this
		# number belongs to another stage of the frame (the rebuild, the paint poll, the engine), which
		# is what [method TerrainGenerator.last_frame_phase_ms] and the soak's engine monitors split.
		_step_ms["applier_total"] = float(Time.get_ticks_usec() - start_us) / 1000.0

## Work another stage of this same frame already did (the compose commit, for example), in ms.
## Charged inside [method process] right after the frame's accountant is opened, so the job assembly
## that follows cannot spend a budget the earlier stage already used.
var _frame_charge_ms: float = 0.0

## Report work done by another stage of the current frame; consumed by the next [method process].
func charge_frame(ms: float) -> void:
	_frame_charge_ms += maxf(ms, 0.0)

## True while the terrain has work queued or in flight.
func is_busy() -> bool:
	return has_mesh_work() or collision_refresh_pending or not scatter_queue.is_empty() \
		or scatter_dirty_all or (scheduler != null and scheduler.has_work())

func has_mesh_work() -> bool:
	return pipeline != null and pipeline.has_pending_work()

## True while navigation regions are waiting for (or running) a bake.
func is_baking_navigation() -> bool:
	return nav_in_flight > 0 or nav_due_msec > 0

## True while navigation geometry is being built on the workers or waiting to be committed.
func has_nav_work() -> bool:
	return nav_in_flight > 0 or pipeline.has_nav_work()

## True while **any** worker task the applier started is alive - mesh, collision or navigation
## geometry, including groups abandoned by a superseding dispatch. This is the teardown-honest
## question (DESIGN.md §14); [method has_mesh_work] is only the "is the terrain visually complete"
## one, which is why a caller that reports "settled" must ask this instead.
func has_worker_work() -> bool:
	return pipeline != null and pipeline.has_worker_work()

## Block until every queued chunk mesh / collision result is built and applied, and until the
## scheduler queue is empty. This is the synchronous path (bakes, tests, `rebuild_now()`), so it
## ignores the frame budget by design (design D7.1 rule 6).
func drain() -> void:
	var guard := 0
	while true:
		guard += 1
		if guard > 200000:
			push_warning("[Terrainy] chunk drain did not settle, giving up after %d iterations" % guard)
			return
		if not has_mesh_work() and not scheduler.has_work():
			return
		pipeline.poll()
		if pipeline.has_mesh_results():
			apply_mesh_results(false)
		if pipeline.has_collision_results():
			apply_collision_results(false)
		if not has_mesh_work() and scheduler.has_work():
			_drain_queue(false)
		if pipeline.has_pending_work():
			OS.delay_usec(200)

## Teardown: make the applier inert and block until the worker groups are done with their data.
##
## `remove_child()` + `free()` right after `is_rebuilding()` goes false used to segfault at 512
## cells (exit 139, no GDScript error): a group task could still be writing into its holder, and an
## async navigation bake could call back into the freed host. Cancelling first and waiting here is
## the ordering the generator's `_exit_tree()` relies on (DESIGN.md §14).
func shutdown(timeout_ms: int = 2000) -> void:
	_detached = true
	_tail_deferred = false
	scatter_queue.clear()
	scatter_dirty_all = false
	if pipeline == null:
		return
	pipeline.cancel_mesh_jobs()
	pipeline.cancel_collision_jobs()
	pipeline.cancel_navigation_jobs()
	pipeline.wait_for_pending(timeout_ms)
	nav_in_flight = 0
	nav_due_msec = 0
	_detach_refs()

## Drop the applier's references into the scheduler and the LOD controller. [ChunkScheduler] and
## [LodController] hold the host node and are held by it, so the cycle has to be broken explicitly
## or every generator leaks at exit.
func _detach_refs() -> void:
	if scheduler != null:
		scheduler.clear()
		scheduler.chunk_lookup = Callable()
		scheduler = null
	if lod != null:
		lod.host = null
		lod = null

## True after [method shutdown]: the host is going away, so no callback may touch it.
func is_detached() -> bool:
	return _detached

# --- Chunks ---------------------------------------------------------------------------------

## Queue mesh jobs for [param dirty]. Empty dirty still closes the stage so the host can finish.
##
## This only *queues*: dispatch itself is the scheduler's job (design D7.3), so a rebuild of 256
## chunks spreads over as many frames as the budget needs instead of stalling one.
##
## The jobs only carry references to the composed images plus the chunk's sample rect: the pixel
## copies, the mask scan, the LOD downsampling and the normal border slice all happen on the
## worker (see [method ChunkPipeline.run_mesh_job]). Preparing one copy per dirty chunk on the
## main thread was a single-frame burst that grew with the terrain.
func dispatch(dirty: Array, rebuild_id: int) -> void:
	if dirty.is_empty():
		all_applied.emit()
		return
	if rebuild_id >= 0:
		_rebuild_id = rebuild_id
	var chunks = host.get_chunk_manager()
	for chunk in dirty:
		if not chunk.streamed_in:
			# Outside the view distance: building it would be exactly the work streaming exists to
			# avoid. It keeps its dirty flag and is built when it streams back in (design D8.1).
			chunk.build_queued = true
			continue
		chunks.mark_dirty(chunk)
		# A rebuilt chunk is the newest truth the user is looking at, so it takes the top class.
		scheduler.enqueue(chunk, ChunkScheduler.Priority.EDIT)
	# No drain here: this runs inside the compose commit, which is itself a budgeted stage of the
	# frame. [method process] opens the accountant, charges the commit's cost and then assembles
	# jobs with whatever is left - draining here would hand the commit frame a fresh 8 ms window.

## Build queued chunk jobs, best class first, until the frame budget is spent, then hand them to the
## worker pool as one batch (the workers need several jobs at once to actually run in parallel).
## [param budgeted] false is the synchronous drain path and ignores the budget.
func _drain_queue(budgeted: bool) -> void:
	if has_mesh_work():
		# A batch in flight was sliced from the heightmap it describes; dispatching over it would
		# cancel it. Let it finish, then continue the queue on the next frame.
		return
	var jobs: Array = []
	var snapshot: Dictionary = {}
	var grid = host.get_grid()
	var job_rebuild_id: int = _rebuild_id if _rebuild_id >= 0 else host.get_rebuild_id()
	var start := Time.get_ticks_usec()
	while scheduler.has_work():
		if budgeted and not scheduler.can_spend():
			break
		var chunk = scheduler.take_next()
		if chunk == null:
			break
		if not chunk.streamed_in:
			# Streamed out between queueing and dispatch. Dropping it loses nothing: the chunk is
			# rebuilt from the current composition when it comes back.
			continue
		if snapshot.is_empty():
			# One snapshot per batch, shared by every job in it (DESIGN.md §4.4). The images it
			# holds stay read-only until the group task is collected (§4.6); workers only slice them.
			snapshot = ChunkJobs.make_snapshot(host.get_final_image(), host.get_hole_map(),
				grid.full_rect() if grid != null else Rect2i(), job_rebuild_id, collision_budget())
		var unit_start := Time.get_ticks_usec()
		jobs.append(ChunkJobs.build(snapshot, chunk, mesh_step(chunk)))
		# The unit is the main-thread job assembly (snapshot slice + downsampling), which is the
		# expensive part the budget exists to bound (hazard H3); the worker side is not main-thread
		# time.
		scheduler.spend(float(Time.get_ticks_usec() - unit_start) / 1000.0)
	if jobs.is_empty():
		return
	pipeline.use_threads = host.use_multithreading
	pipeline.worker_threads = _worker_threads()
	if diagnostics:
		diagnostics.record("chunk_jobs", (Time.get_ticks_usec() - start) / 1000)
	var dispatch_start := Time.get_ticks_usec()
	pipeline.dispatch_mesh_jobs(jobs, job_rebuild_id, budgeted)
	# Handing a batch to the pool is main-thread work too (one group task per job), so it is charged
	# like every other unit: a single 256-job batch used to be the biggest frame of the whole build.
	var dispatch_ms := float(Time.get_ticks_usec() - dispatch_start) / 1000.0
	scheduler.spend(dispatch_ms)
	if trace_steps:
		_step_ms["n_jobs"] = jobs.size()
		_step_ms["dispatch"] = dispatch_ms
	if not pipeline.use_threads or (jobs.size() <= 1 and not budgeted):
		# Inline build: the results are already here, so applying them cannot be deferred.
		apply_mesh_results(false)

## Re-evaluate LOD targets and residency and queue what changed. The queue is drained at the end of
## the step with whatever budget is left, so a camera moving across ten chunks spreads its LOD churn
## over ten frames instead of one (design D5.5).
func lod_step() -> void:
	var chunks = host.get_chunk_manager()
	var camera: Camera3D = host.find_camera()
	if chunks == null or camera == null:
		return
	var t := Time.get_ticks_usec()
	var changed: Array = lod.update(camera, chunks.chunks, scheduler)
	if trace_steps:
		_step_ms["lod_update"] = float(Time.get_ticks_usec() - t) / 1000.0
		t = Time.get_ticks_usec()
	for chunk in changed:
		# A revision bump makes an in-flight build for the old level stale: it is dropped at commit
		# instead of fighting the newer one (design D5.5).
		chunk.edit_revision += 1
		chunks.mark_dirty(chunk)
	var cam_xz := Vector2(camera.global_position.x, camera.global_position.z)
	var restored: Array = chunks.evict_beyond(cam_xz, host.view_distance, host.lod_hysteresis)
	if trace_steps:
		_step_ms["lod_evict"] = float(Time.get_ticks_usec() - t) / 1000.0
	for chunk in restored:
		chunk.edit_revision += 1
		scheduler.enqueue(chunk, ChunkScheduler.Priority.NEAR)

## Worker thread count: the host's resolved setting when it exposes one (it derives "auto" from
## the processor count), else the generator's raw export.
func _worker_threads() -> int:
	if host.has_method("effective_worker_threads"):
		return host.effective_worker_threads()
	return int(host.max_worker_threads)

## Kept for callers that build a single job by hand; [method dispatch] shares one snapshot across
## every job of a rebuild instead.
func chunk_job(chunk) -> Dictionary:
	var grid = host.get_grid()
	var snapshot := ChunkJobs.make_snapshot(host.get_final_image(), host.get_hole_map(),
		grid.full_rect() if grid != null else chunk.sample_rect,
		pipeline.mesh_rebuild_id(), collision_budget())
	return ChunkJobs.build(snapshot, chunk, mesh_step(chunk))

func mesh_step(chunk, lod_level: int = -1) -> int:
	var cells: int = chunk.sample_rect.size.x - 1
	var base := 1
	if host.chunk_resolution > 0 and host.chunk_resolution < cells:
		base = maxi(cells / host.chunk_resolution, 1)
	var level: int = chunk.lod_level if lod_level < 0 else lod_level
	var step: int = base << level
	var w: int = chunk.sample_rect.size.x
	var h: int = chunk.sample_rect.size.y
	var fitted := mini(step, mini(w - 1, h - 1))
	while fitted > 1 and ((w - 1) % fitted != 0 or (h - 1) % fitted != 0):
		fitted -= 1
	return maxi(fitted, 1)

func collision_budget() -> int:
	if host.collision_triangle_budget > 0:
		return host.collision_triangle_budget
	return CollisionBuilder.budget_for_quality(host.collision_quality)

func apply_mesh_results(budgeted: bool) -> void:
	var start := Time.get_ticks_usec()
	var applied := 0
	var budget_usec: int = int(host.chunk_apply_budget_ms) * 1000
	var deadline_usec: int = start + budget_usec if (budgeted and budget_usec > 0) else 0
	_budget_start_usec = start
	_budgeted_window = budgeted and budget_usec > 0
	while pipeline.has_mesh_results():
		# The check sits *before* each commit, not once per batch (DESIGN.md §7.4). N chunks that
		# finished while the main thread was busy must not commit back to back: at 512 cells that
		# produced a 208 ms frame (H14). The unit rule still applies - one commit may overrun, since
		# the cost of a commit is only known after it ran - but never a whole burst.
		if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
			if diagnostics:
				diagnostics.count("apply_frames")
			break
		var t0 := Time.get_ticks_usec()
		apply_chunk_result(pipeline.pop_mesh_result())
		applied += 1
		# The commit unit is charged like every other unit in the frame (design D7.1 rule 2).
		scheduler.spend(float(Time.get_ticks_usec() - t0) / 1000.0)
	if diagnostics:
		diagnostics.count("chunks_applied", applied)
		diagnostics.record("chunk_apply", (Time.get_ticks_usec() - start) / 1000)
	if not pipeline.has_pending_work():
		# The `all_applied` tail (material refresh + rebuild report) is one budget unit of its own
		# (DESIGN.md §7.4). If this frame's apply window is spent, it waits for the next frame: the
		# terrain is visually complete either way, the signal is a notification.
		if can_spend_tail(applied):
			_tail_deferred = false
			_emit_tail()
		else:
			_tail_deferred = true
			if diagnostics:
				diagnostics.count("tail_deferred")

func _emit_tail() -> void:
	var tail_start := Time.get_ticks_usec()
	all_applied.emit()
	var tail_ms := float(Time.get_ticks_usec() - tail_start) / 1000.0
	# Self-tuning estimate of what the tail costs (material refresh + report) so [method
	# can_spend_tail] asks for the real number instead of a fixed guess.
	_tail_estimate_ms = lerpf(_tail_estimate_ms, tail_ms, 0.5)
	if trace_steps:
		_step_ms["tail"] = tail_ms

## True when an `all_applied` tail was deferred and is still waiting to run.
func tail_due() -> bool:
	return _tail_deferred and not pipeline.has_pending_work()

## Emit the deferred tail on a fresh frame. The host's frame step calls this; returns true when the
## tail actually ran.
func drain_tail() -> bool:
	if not _tail_deferred or pipeline.has_pending_work():
		return false
	_tail_deferred = false
	# A new frame: the tail is the first unit of it, so it is no longer measured against the
	# previous apply window.
	_budgeted_window = false
	_emit_tail()
	return true

## True when the frame that just committed still has room for one more budget unit: the
## `all_applied` tail (DESIGN.md §7.4). The host asks this before refreshing the material and
## closing the rebuild, so the tail never rides on top of an exhausted apply window; an unbudgeted
## window or a zero budget always allows it.
##
## [param applied] is the number of chunks this frame committed. A frame that committed anything
## hands the tail to the next frame unconditionally: the tail is a unit of its own (the material
## refresh costs ~9 ms at 1024 cells, more than an 8 ms budget), so it can never share a frame with
## commits without breaking the budget by construction.
func can_spend_tail(applied: int = 0) -> bool:
	if not _budgeted_window:
		return true
	if applied > 0:
		return false
	var budget_usec: int = int(host.chunk_apply_budget_ms) * 1000
	var spent_usec := Time.get_ticks_usec() - _budget_start_usec
	var tail_ms: int = 2
	if "tail_budget_ms" in host:
		tail_ms = int(host.tail_budget_ms)
	# The tail's own cost is measured, not assumed (it is the material refresh at this scale, a few
	# milliseconds at 512 cells and ~9 ms at 1024 - DESIGN.md §7.4 calls it 0.2-0.4 ms because it
	# measured the report only). Asking for room for the measured cost is what keeps the tail from
	# riding on top of an exhausted apply window.
	var needed_ms: float = maxf(float(tail_ms), _tail_estimate_ms)
	var remaining_ms := float(budget_usec - spent_usec) / 1000.0
	return remaining_ms >= needed_ms

func apply_chunk_result(result: Dictionary) -> void:
	var chunks = host.get_chunk_manager()
	var chunk = chunks.chunks.get(result["key"])
	if chunk == null or result.get("revision", -1) != chunk.edit_revision:
		return
	if not chunk.streamed_in:
		# Streamed out while the job was in flight: drop the result instead of re-attaching a mesh
		# to a chunk nobody draws. The chunk is rebuilt when it comes back.
		return
	var lod_level: int = int(result.get("lod_level", chunk.lod_level))
	var mesh: ArrayMesh = MeshGen.mesh_from_arrays(result["arrays"])
	apply_skirts(mesh, chunk, result["arrays"], lod_level)
	chunk.mesh_instance.mesh = mesh
	chunk.mesh_instance.cast_shadow = host.cast_shadows
	chunk.heightmap = result["heightmap"]
	chunk.hole_mask = result.get("hole_mask")
	chunk.has_holes = result.get("has_holes", false)
	chunk.collision_revision += 1
	chunks.mark_clean(chunk, result["revision"])
	apply_collision(chunk, result.get("collision_faces", PackedVector3Array()),
		result.get("collision_heights", PackedFloat32Array()))
	chunk.nav_dirty = true
	if host.navigation_enabled:
		nav_due_msec = Time.get_ticks_msec() + host.navigation_debounce_ms
	queue_chunk_scatter(chunk)
	var material: Material = host.current_material()
	if material != null:
		chunk.mesh_instance.material_override = material
	var b: Rect2 = chunk.world_bounds
	var gy: float = host.global_position.y
	# The chunk's height bounds travel with the worker result (DESIGN.md §4.7). This used to call
	# the generator's `final_min()`/`final_max()`, a full-grid GDScript scan measured at 58-66 ms on
	# a 1024-cell terrain - paid inside the budgeted commit of the first chunk of every rebuild.
	var lo: float = result.get("min_y", 0.0)
	var hi: float = result.get("max_y", lo)
	if host.has_method("note_chunk_bounds"):
		host.note_chunk_bounds(lo, hi)
	var aabb := AABB(Vector3(b.position.x, gy + lo, b.position.y),
		Vector3(b.size.x, maxf(hi - lo, 0.001), b.size.y))
	region_updated.emit(aabb)

## Seal the chunk's LOD boundaries (design D5.4): a wall down from every edge whose neighbour
## samples the shared edge at a different resolution. Added as **surface 1**, so surface 0 stays
## exactly the arrays the mesh worker produced - collision, the bake exporter and the existing
## vertex-count/seam tests keep reading the same vertex set they always read.
## Returns the number of skirt vertices added.
func apply_skirts(mesh: ArrayMesh, chunk, arrays: Array, lod_level: int) -> int:
	if not host.seam_skirts or arrays == null or arrays.size() < Mesh.ARRAY_MAX:
		return 0
	var chunks = host.get_chunk_manager()
	var edges: int = lod.edges_for(chunk.key, chunks.chunks)
	if edges == 0:
		return 0
	var step := mesh_step(chunk, lod_level)
	var dims := mesh_dims(chunk, step)
	return SeamBuilder.append_skirt_surface(mesh, arrays, dims, lod.skirt_depth(step), edges)

## Vertex grid (samples per side) of the mesh a chunk builds at [param step].
func mesh_dims(chunk, step: int) -> Vector2i:
	var s := maxi(step, 1)
	return Vector2i(
		(chunk.sample_rect.size.x - 1) / s + 1,
		(chunk.sample_rect.size.y - 1) / s + 1)

# --- Collision ------------------------------------------------------------------------------

## True when [param chunk] is inside the physics range. `collision_range <= 0` keeps collision for
## every chunk (the 0.7/1.x behaviour), so existing scenes see no change.
func collision_in_range(chunk) -> bool:
	var limit: float = host.collision_range
	if limit <= 0.0:
		return true
	var reference: Vector3 = _collision_reference()
	var b: Rect2 = chunk.world_bounds
	var here := Vector2(reference.x, reference.z)
	var nearest := Vector2(clampf(here.x, b.position.x, b.end.x), clampf(here.y, b.position.y, b.end.y))
	return here.distance_to(nearest) <= limit

## Point the physics range is measured from: the LOD camera (editor viewport or game camera), or
## the generator itself when there is none (headless, tools, tests).
func _collision_reference() -> Vector3:
	var camera: Camera3D = host.find_camera()
	if camera != null and camera.is_inside_tree():
		return camera.global_position
	return host.global_position

## Add/remove collision shapes as chunks cross the physics range. Cheap when nothing changed: one
## distance test per chunk, and a shape is only (re)built for the chunks that crossed.
func update_collision_range() -> void:
	if host.collision_range <= 0.0:
		return
	var chunks = host.get_chunk_manager()
	if chunks == null:
		return
	var start := Time.get_ticks_usec()
	var changed := 0
	for chunk in chunks.chunks.values():
		if chunk.heightmap == null:
			continue
		var wanted := collision_in_range(chunk)
		var active: bool = chunk.collision_shape != null \
			and chunk.collision_shape.shape != null and not chunk.collision_shape.disabled
		if wanted == active:
			continue
		apply_collision(chunk, chunk.collision_faces, chunk.collision_heights)
		changed += 1
	if changed > 0 and diagnostics:
		diagnostics.count("collision_range_flips", changed)
		diagnostics.record("collision", (Time.get_ticks_usec() - start) / 1000)
	# The pass itself walks every chunk (one distance test each) and can flip shapes: it is main-thread
	# work like any other unit, so it charges the frame accountant instead of leaving the apply window
	# its full 8 ms afterwards (design D7.1 rule 2).
	scheduler.spend(float(Time.get_ticks_usec() - start) / 1000.0)

## Build the chunk's collision shape. [param heights] / [param faces] come from the worker for a
## freshly built chunk; without them the CPU-side copy stored on the chunk is used, which is what
## lets a chunk outside the physics range restore its shape without rebuilding anything.
func apply_collision(chunk, faces: PackedVector3Array, heights: PackedFloat32Array = PackedFloat32Array()) -> void:
	if chunk.heightmap == null:
		return
	chunk.static_body.collision_layer = host.collision_layer
	chunk.static_body.collision_mask = host.collision_mask
	if not heights.is_empty():
		chunk.collision_heights = heights
	if not faces.is_empty():
		chunk.collision_faces = faces
	if not chunk.has_holes and chunk.collision_heights.is_empty():
		# Nothing handed over (collision-only refresh of a chunk built before the cache existed).
		chunk.collision_heights = chunk.heightmap.get_data().to_float32_array()
	if not collision_in_range(chunk):
		# Out of the physics range: drop the shape (and the physics-side heightfield with it). The
		# CPU data stays on the chunk, so re-entering the range is a plain re-assignment.
		chunk.collision_shape.shape = null
		chunk.collision_shape.disabled = true
		chunk.height_shape = null
		chunk.collision_trimesh = null
		return
	chunk.collision_shape.disabled = false
	if not chunk.has_holes:
		var shape: HeightMapShape3D = chunk.height_shape if chunk.height_shape else HeightMapShape3D.new()
		chunk.height_shape = shape
		var w: int = chunk.heightmap.get_width()
		var d: int = chunk.heightmap.get_height()
		shape.map_width = w
		shape.map_depth = d
		shape.map_data = chunk.collision_heights
		chunk.collision_shape.shape = shape
		chunk.collision_shape.scale = Vector3(chunk.world_bounds.size.x / float(w - 1), 1.0, chunk.world_bounds.size.y / float(d - 1))
		chunk.collision_trimesh = null
		return
	if chunk.collision_faces.is_empty():
		chunk.collision_faces = CollisionBuilder.build_faces(chunk.heightmap, chunk.world_bounds.size, chunk.hole_mask, collision_budget(), 0)
	var trimesh: ConcavePolygonShape3D = chunk.collision_trimesh if chunk.collision_trimesh else ConcavePolygonShape3D.new()
	chunk.collision_trimesh = trimesh
	trimesh.set_faces(chunk.collision_faces)
	chunk.collision_shape.shape = trimesh
	chunk.collision_shape.scale = Vector3.ONE

func refresh_all_collision() -> void:
	# Queue every chunk instead of rebuilding them all now (DESIGN.md §6.3 / D7.1). A collision
	# quality or layer change used to redo every shape in one frame: 114.9 ms at 2048 cells in the
	# LOD flythrough. `step_collision_refresh()` spreads the same work over frames under the budget.
	var chunks = host.get_chunk_manager()
	if chunks == null:
		return
	_collision_refresh_queue.clear()
	for chunk in chunks.chunks.values():
		# Streamed-out chunks have no heightmap and no shape left: nothing to refresh.
		if chunk.heightmap != null and chunk.streamed_in:
			_collision_refresh_queue.append(chunk.key)
	if _collision_refresh_queue.is_empty():
		collision_refresh_pending = false

## One budgeted slice of [method refresh_all_collision]: rebuilds shapes until the frame budget is
## spent, then leaves the rest of the queue for the next frame. Hole-free chunks only re-assign
## their cached heightfield; holed ones get their face soup rebuilt on the worker pool.
func step_collision_refresh(budgeted: bool = true) -> void:
	var chunks = host.get_chunk_manager()
	if chunks == null:
		_collision_refresh_queue.clear()
		collision_refresh_pending = false
		return
	if _collision_refresh_queue.is_empty():
		# Nothing queued yet: the pending flag means someone asked for a full refresh, so build the
		# queue here (`refresh_all_collision` only queues, it does not build shapes).
		refresh_all_collision()
		if _collision_refresh_queue.is_empty():
			return
	var start := Time.get_ticks_usec()
	var budget_usec: int = int(host.chunk_apply_budget_ms) * 1000
	var jobs: Array = []
	while not _collision_refresh_queue.is_empty():
		var chunk = chunks.chunks.get(_collision_refresh_queue.pop_front())
		if chunk == null or chunk.heightmap == null or not chunk.streamed_in:
			continue
		if not chunk.has_holes:
			# Reuses the cached heights; only the shape assignment is physics-side work.
			apply_collision(chunk, PackedVector3Array(), chunk.collision_heights)
		else:
			jobs.append({"key": chunk.key, "heightmap": chunk.heightmap, "hole_mask": chunk.hole_mask,
				"size": chunk.world_bounds.size, "budget": collision_budget(), "lod_level": 0,
				"revision": chunk.collision_revision})
		if budgeted and budget_usec > 0 and Time.get_ticks_usec() - start >= budget_usec:
			break
	if not jobs.is_empty():
		pipeline.use_threads = host.use_multithreading
		pipeline.dispatch_collision_jobs(jobs)
	if diagnostics:
		diagnostics.record("collision", (Time.get_ticks_usec() - start) / 1000)
		diagnostics.count("collision_refresh_chunks", _collision_refresh_queue.size())
	if _collision_refresh_queue.is_empty():
		collision_refresh_pending = false

func apply_collision_results(budgeted: bool) -> void:
	var chunks = host.get_chunk_manager()
	var applied := 0
	var start := Time.get_ticks_usec()
	var budget_usec: int = int(host.chunk_apply_budget_ms) * 1000
	while pipeline.has_collision_results():
		var t0 := Time.get_ticks_usec()
		var result: Dictionary = pipeline.pop_collision_result()
		var chunk = chunks.chunks.get(result["key"])
		# A streamed-out chunk has no shape to fill: its commit slot is spent, its shape is not.
		if chunk and chunk.streamed_in and result.get("revision", 0) == chunk.collision_revision:
			apply_collision(chunk, result.get("collision_faces", PackedVector3Array()))
		applied += 1
		scheduler.spend(float(Time.get_ticks_usec() - t0) / 1000.0)
		if budgeted and (not scheduler.can_spend() or (budget_usec > 0 and Time.get_ticks_usec() - start >= budget_usec)):
			break

func apply_collision_layers() -> void:
	var chunks = host.get_chunk_manager()
	if chunks == null:
		return
	for chunk in chunks.chunks.values():
		chunk.static_body.collision_layer = host.collision_layer
		chunk.static_body.collision_mask = host.collision_mask

# --- Navigation -----------------------------------------------------------------------------

## Re-bake every chunk's navigation region now (manual schedule). [param synchronous] blocks.
func bake_navigation(synchronous: bool = false) -> void:
	mark_all_nav_dirty()
	nav_due_msec = Time.get_ticks_msec()
	if synchronous:
		bake_navigation_step(true)

func mark_all_nav_dirty() -> void:
	var chunks = host.get_chunk_manager()
	if chunks == null:
		return
	for chunk in chunks.chunks.values():
		chunk.nav_dirty = true
	if host.navigation_enabled:
		nav_due_msec = Time.get_ticks_msec() + host.navigation_debounce_ms

func clear_navigation() -> void:
	var chunks = host.get_chunk_manager()
	if chunks == null:
		return
	for chunk in chunks.chunks.values():
		if chunk.nav_region:
			chunk.nav_region.queue_free()
			chunk.nav_region = null
	nav_due_msec = 0

## Turn every dirty chunk into a navigation geometry job on the worker pool.
##
## The geometry build (grown extract, decimated face soup, `min_max` over the grown rect) is
## ~34 ms per chunk at the reference scale, so the old inline loop was 2 153 ms in one frame for a
## 1024-cell terrain - the default-on freeze users report above 512 cells. The main thread now only
## allocates the job dictionaries; the bake is kicked off in [method apply_navigation_results].
func bake_navigation_step(synchronous: bool = false) -> void:
	nav_due_msec = 0
	var final_map = host.get_final_map()
	if final_map == null:
		return
	var chunks = host.get_chunk_manager()
	if chunks == null:
		return
	var grid = host.get_grid()
	var template: NavigationMesh = host.navigation_mesh_template
	var jobs: Array = []
	for chunk in chunks.chunks.values():
		if not chunk.nav_dirty or chunk.nav_baking or chunk.heightmap == null:
			continue
		# The chunk is claimed here so a second call cannot queue it twice; `nav_revision` is what
		# lets a result that arrives after the chunk was invalidated be discarded (see below).
		chunk.nav_dirty = false
		chunk.nav_revision += 1
		chunk.nav_baking = true
		nav_in_flight += 1
		jobs.append({
			"kind": ChunkJobs.JobKind.NAVIGATION,
			"key": chunk.key,
			"revision": chunk.nav_revision,
			"chunk": chunk,
			"grid": grid,
			"final_map": final_map,
			"nav_holes": host.get_navigation_hole_map(),
			"template": template,
			"nav_budget": host.navigation_triangle_budget,
		})
	if jobs.is_empty():
		return
	if synchronous or not host.use_multithreading:
		for job in jobs:
			var built := NavigationBuilder.make_job(job["chunk"], grid, final_map, job["nav_holes"],
				template, int(job["nav_budget"]))
			_commit_nav_geometry(job["key"], job["revision"], built.get("mesh"), built.get("geometry"), true)
		return
	pipeline.use_threads = host.use_multithreading
	pipeline.worker_threads = _worker_threads()
	pipeline.dispatch_navigation_jobs(jobs)

## Commit finished navigation geometry, at most one bake per budget window: the bake itself runs on
## the navigation server's own threads, so the frame cost here is one call.
func apply_navigation_results(budgeted: bool = true) -> void:
	if not pipeline.has_navigation_results():
		return
	var start := Time.get_ticks_usec()
	var budget_usec: int = int(host.chunk_apply_budget_ms) * 1000
	while pipeline.has_navigation_results():
		var result: Dictionary = pipeline.pop_navigation_result()
		_commit_nav_geometry(result["key"], result["revision"],
			result.get("nav_mesh"), result.get("nav_geometry"), false)
		if budgeted and budget_usec > 0 and Time.get_ticks_usec() - start >= budget_usec:
			break

## Kick off the bake of one chunk's finished geometry, or drop it when the chunk was invalidated
## while the job was in flight (its `nav_revision` moved on), which is the cancellation rule for the
## navigation kind.
func _commit_nav_geometry(key: Vector2i, revision: int, mesh, geometry, synchronous: bool) -> void:
	var chunks = host.get_chunk_manager()
	var chunk = chunks.chunks.get(key) if chunks else null
	if chunk == null or mesh == null or geometry == null or revision != chunk.nav_revision:
		if chunk != null:
			chunk.nav_baking = false
		nav_in_flight = maxi(nav_in_flight - 1, 0)
		return
	if synchronous or not host.use_multithreading:
		NavigationServer3D.bake_from_source_geometry_data(mesh, geometry)
		on_nav_baked(key, revision, mesh)
		return
	NavigationServer3D.bake_from_source_geometry_data_async(mesh, geometry,
		_nav_trampoline.bind(weakref(self), key, revision, mesh))

static func _nav_trampoline(ref: WeakRef, key: Vector2i, revision: int, mesh: NavigationMesh) -> void:
	var applier = ref.get_ref()
	if is_instance_valid(applier):
		applier.on_nav_baked(key, revision, mesh, true)

func on_nav_baked(key: Vector2i, revision: int, mesh: NavigationMesh, was_async: bool = false) -> void:
	if was_async:
		nav_in_flight = maxi(nav_in_flight - 1, 0)
	# An async bake can land after the generator left the tree; touching the host then is a
	# use-after-free (DESIGN.md §14).
	if _detached:
		return
	var chunks = host.get_chunk_manager()
	var chunk = chunks.chunks.get(key) if chunks else null
	if chunk == null:
		return
	chunk.nav_baking = false
	if revision != chunk.nav_revision or not host.navigation_enabled or not host.is_inside_tree():
		return
	if chunk.nav_region == null or not is_instance_valid(chunk.nav_region):
		chunk.nav_region = NavigationRegion3D.new()
		chunk.nav_region.name = "Navigation"
		chunk.root.add_child(chunk.nav_region, false, Node.INTERNAL_MODE_BACK)
	chunk.nav_region.navigation_mesh = mesh
	navigation_baked.emit(mesh, key)
	if chunk.nav_dirty:
		nav_due_msec = Time.get_ticks_msec() + host.navigation_debounce_ms

## Navigation meshes of every chunk that has one (chunk key -> NavigationMesh).
func navigation_meshes() -> Dictionary:
	var out := {}
	var chunks = host.get_chunk_manager()
	if chunks:
		for chunk in chunks.chunks.values():
			if chunk.nav_region and chunk.nav_region.navigation_mesh:
				out[chunk.key] = chunk.nav_region.navigation_mesh
	return out

# --- LOD ------------------------------------------------------------------------------------

## LOD switch distances in meters, one per further level (each level halves the mesh resolution).
## With `lod_auto` the distances are derived from the world-space cell size and the camera
## projection: level n starts where one cell still covers `lod_pixel_error` pixels of the viewport.
## That is scale independent - the fixed meter distances of 0.x made every chunk of a 4 km terrain
## jump straight to the coarsest level and turned the terrain into countable triangles.
func lod_distances_for(camera: Camera3D) -> PackedFloat32Array:
	return lod.distances_for(camera, host.get_grid())

## Distance from [param point] (XZ) to the nearest point of the chunk rectangle.
static func _distance_to_bounds(bounds: Rect2, point: Vector2) -> float:
	var nearest := Vector2(
		clampf(point.x, bounds.position.x, bounds.end.x),
		clampf(point.y, bounds.position.y, bounds.end.y))
	return point.distance_to(nearest)

## Re-evaluate LOD targets and residency now and build everything the queue holds, ignoring the
## frame budget. The per-frame path is [method lod_step]; this entry point exists for tools and
## tests that need the switch to happen synchronously.
func update_lod() -> void:
	lod_step()
	drain()

# --- Scatter --------------------------------------------------------------------------------

func scatter_nodes() -> Array:
	var out: Array = []
	_collect_scatter(host, out)
	return out

func _collect_scatter(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is TerrainScatterNode:
			if child.enabled and child.visible:
				out.append(child)
		elif child is Node3D and not (child is TerrainPaintLayer):
			_collect_scatter(child, out)

## True when any chunk still carries scatter instances - the one case where an empty scatter-node list
## still leaves something to clean up (an instance whose node was deleted).
func _chunks_have_scatter(chunks) -> bool:
	for chunk in chunks.chunks.values():
		if not chunk.scatter.is_empty():
			return true
	return false

func queue_chunk_scatter(chunk) -> void:
	if not scatter_queue.has(chunk.key):
		scatter_queue.append(chunk.key)

func process_scatter_queue(unbudgeted: bool = false) -> void:
	var final_map = host.get_final_map()
	var chunks = host.get_chunk_manager()
	if final_map == null or chunks == null:
		return
	var scatters := scatter_nodes()
	# A terrain with no scatter nodes has nothing to place, but a rebuild still marks every chunk
	# dirty and the loop below then calls refresh_chunk() for each of them - on a contended frame that
	# measured 21.5 ms at 1024 cells for work that cannot produce a single instance (RESULTS.md §6).
	# One pass with an empty-dictionary test replaces it.
	if scatters.is_empty() and not _chunks_have_scatter(chunks):
		scatter_dirty_all = false
		scatter_queue.clear()
		return
	if scatter_dirty_all:
		scatter_dirty_all = false
		scatter_queue.clear()
		for key in chunks.chunks.keys():
			scatter_queue.append(key)
	while not scatter_queue.is_empty():
		var unit_start := Time.get_ticks_usec()
		var item = scatter_queue.pop_front()
		if item is int:
			# A scatter node changed: every chunk refreshes that node only.
			var node := instance_from_id(item) as TerrainScatterNode
			for chunk in chunks.chunks.values():
				ScatterBuilder.refresh_chunk(host, chunk, [node] if node and scatters.has(node) else [],
					host.get_grid(), final_map, host.get_hole_map(), item)
		else:
			var chunk = chunks.chunks.get(item)
			# A streamed-out chunk has no instances to refresh.
			if chunk and chunk.streamed_in:
				ScatterBuilder.refresh_chunk(host, chunk, scatters, host.get_grid(), final_map, host.get_hole_map())
		scheduler.spend(float(Time.get_ticks_usec() - unit_start) / 1000.0)
		if not unbudgeted and not scheduler.can_spend():
			break
