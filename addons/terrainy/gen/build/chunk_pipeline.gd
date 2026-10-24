@tool
extends RefCounted

## Owns the asynchronous half of chunk generation.
##
## [TerrainGenerator] knows how to slice its composed heightmap into per-chunk jobs; this class
## takes those jobs and owns everything after that:
##
## - dispatching them to a [WorkerThreadPool] group task (or running them inline when threading is
##   disabled),
## - collecting the finished results without blocking the main thread,
## - and keeping them queued until the generator has drained the queue.
##
## The generator drains the queues itself, one result at a time, so it can spread the main-thread
## work (creating meshes, handing shapes to the physics server) over several frames.
##
## The workers only ever touch the refcounted holder dictionary handed to them, never the
## generator or this class, so an in-flight - or abandoned - task can never call back into a node
## that is being modified or freed.

const MeshGen = preload("res://addons/terrainy/gen/build/mesh_generator.gd")
const CollisionBuilder = preload("res://addons/terrainy/gen/build/collision_builder.gd")
const Diagnostics = preload("res://addons/terrainy/gen/build/diagnostics.gd")
const ChunkJobs = preload("res://addons/terrainy/gen/build/chunk_jobs.gd")
const NavigationBuilder = preload("res://addons/terrainy/gen/build/navigation_builder.gd")

## Wall time to wait for worker tasks when the caller cannot accept a blocking wait (teardown).
const SHUTDOWN_WAIT_MS := 5000

## Run the jobs on the worker pool; when false everything happens on the calling thread.
var use_threads: bool = true
## Upper bound of parallel tasks per group. `<= 0` means auto: [method effective_worker_threads]
## derives it from the machine.
var worker_threads: int = 0
## Optional diagnostics sink; receives the worker wall times and the job counts.
var diagnostics: Diagnostics = null

# Mesh group task.
var _mesh_group_id: int = -1
var _mesh_holder: Dictionary = {}
var _mesh_queue: Array = []
var _mesh_rebuild_id: int = 0
var _mesh_dispatch_ms: int = 0

# Collision-only group task (a collision setting changed, the chunk heightmaps are reused).
var _collision_group_id: int = -1
var _collision_holder: Dictionary = {}
var _collision_queue: Array = []

# Navigation group task (D4.11): the per-chunk navigation geometry is built on the worker and the
# main thread only kicks off the (asynchronous) bake.
var _nav_group_id: int = -1
var _nav_holder: Dictionary = {}
var _nav_queue: Array = []

## Group tasks abandoned by a superseding dispatch. Their holder is dropped, but the group id
## still has to be released with wait_for_group_task_completion() once it has finished, or the
## worker pool keeps the Group task allocated.
var _abandoned_groups: Array[int] = []


## Hands chunk mesh jobs to the worker pool. A job carries the *unsliced* inputs - the composed
## heightmap [Image] and the hole mask [Image] plus the chunk's sample [Rect2i] - so the slicing,
## the LOD downsampling and the normal border extraction happen on the worker instead of in one
## main-thread burst per rebuild. Keys: `key`, `rect`, `final_image`, `hole_map`, `grid_rect`,
## `normal_border`, `step`, `size`, `lod_level`, `collision`, `collision_budget`, `revision`;
## see [method run_mesh_job]. A pre-sliced job (`heightmap` instead of `final_image`/`rect`) is
## still accepted for callers that already copied the region.
## Jobs left over from a previous dispatch are dropped, they describe a superseded heightmap.
func dispatch_mesh_jobs(jobs: Array, rebuild_id: int, force_pool: bool = false) -> void:
	cancel_mesh_jobs()
	if jobs.is_empty():
		return
	_mesh_rebuild_id = rebuild_id
	_mesh_dispatch_ms = Time.get_ticks_msec()
	_dispatch(jobs, run_mesh_job, "Terrainy chunk meshes", "_mesh", force_pool)


## Hands collision-only jobs to the worker pool. Each job is a dictionary with the keys the
## collision worker reads (`key`, `heightmap`, `hole_mask`, `size`, `budget`, `lod_level`,
## `revision`); see [method run_collision_job].
func dispatch_collision_jobs(jobs: Array) -> void:
	cancel_collision_jobs()
	if jobs.is_empty():
		return
	_dispatch(jobs, run_collision_job, "Terrainy chunk collision", "_collision")


## Hands navigation geometry jobs to the worker pool. Each job is a dictionary with the keys the
## navigation worker reads (`key`, `revision`, `chunk`, `grid`, `final_map`, `nav_holes`,
## `template`, `nav_budget`); see [method run_nav_job].
##
## The geometry build (grown extract, decimated face soup, `min_max`) is ~34 ms per chunk at the
## reference scale, so it must not run on the main thread: a whole terrain's worth of it was one
## multi-second frame and is the default-on freeze users hit above 512 cells.
func dispatch_navigation_jobs(jobs: Array) -> void:
	cancel_navigation_jobs()
	if jobs.is_empty():
		return
	_dispatch(jobs, run_nav_job, "Terrainy chunk navigation", "_nav")


## Number of worker threads the jobs may run on: [member worker_threads] when set, otherwise one
## less than the machine's processor count (so the main thread always keeps a core), at least 1.
func effective_worker_threads() -> int:
	if worker_threads > 0:
		return worker_threads
	return maxi(OS.get_processor_count() - 1, 1)


func _dispatch(jobs: Array, body: Callable, description: String, prefix: String,
		force_pool: bool = false) -> void:
	var holder := {
		"jobs": jobs,
		"results": [],
		"mutex": Mutex.new()
	}
	holder["results"].resize(jobs.size())

	# One job is not worth the pool round trip, and neither is anything when threading is off.
	# `force_pool` exists for the budgeted frame path: a single chunk mesh is ~15 ms of main-thread
	# work at 2048 cells, so the caller that is spending a frame budget must not take this shortcut.
	if not use_threads or (jobs.size() == 1 and not force_pool):
		for i in jobs.size():
			body.call(i, holder)
		_publish(prefix, holder)
		return

	var tasks_needed := clampi(effective_worker_threads(), 1, jobs.size())
	var group_id := WorkerThreadPool.add_group_task(
		body.bind(holder), jobs.size(), tasks_needed, false, description
	)
	if group_id < 0:
		push_error("[TerrainChunkPipeline] Failed to queue '%s' tasks, falling back to main thread" % description)
		for i in jobs.size():
			body.call(i, holder)
		_publish(prefix, holder)
		return

	if prefix == "_mesh":
		_mesh_holder = holder
		_mesh_group_id = group_id
	elif prefix == "_nav":
		_nav_holder = holder
		_nav_group_id = group_id
	else:
		_collision_holder = holder
		_collision_group_id = group_id


## Moves the collected results of a holder that is already finished into the matching queue.
func _publish(prefix: String, holder: Dictionary) -> void:
	var results := _collect(holder)
	if prefix == "_mesh":
		if diagnostics:
			diagnostics.record("chunk_workers", Time.get_ticks_msec() - _mesh_dispatch_ms)
			diagnostics.count("chunks_generated", results.size())
		_mesh_queue.append_array(results)
	elif prefix == "_nav":
		if diagnostics:
			diagnostics.count("nav_jobs", results.size())
		_nav_queue.append_array(results)
	else:
		_collision_queue.append_array(results)


## Collects finished worker results into the internal queues. Never blocks: a group task that is
## still running is simply left alone until the next call.
func poll() -> void:
	_release_abandoned()
	if _mesh_group_id >= 0 and WorkerThreadPool.is_group_task_completed(_mesh_group_id):
		WorkerThreadPool.wait_for_group_task_completion(_mesh_group_id)
		var finished := _mesh_holder
		_mesh_group_id = -1
		_mesh_holder = {}
		_publish("_mesh", finished)

	if _collision_group_id >= 0 and WorkerThreadPool.is_group_task_completed(_collision_group_id):
		WorkerThreadPool.wait_for_group_task_completion(_collision_group_id)
		var finished := _collision_holder
		_collision_group_id = -1
		_collision_holder = {}
		_publish("_collision", finished)

	if _nav_group_id >= 0 and WorkerThreadPool.is_group_task_completed(_nav_group_id):
		WorkerThreadPool.wait_for_group_task_completion(_nav_group_id)
		var finished := _nav_holder
		_nav_group_id = -1
		_nav_holder = {}
		_publish("_nav", finished)


## Releases abandoned group tasks that have finished. Non-blocking; called from poll().
func _release_abandoned() -> void:
	for i in range(_abandoned_groups.size() - 1, -1, -1):
		var group_id: int = _abandoned_groups[i]
		if WorkerThreadPool.is_group_task_completed(group_id):
			WorkerThreadPool.wait_for_group_task_completion(group_id)
			_abandoned_groups.remove_at(i)


func has_mesh_results() -> bool:
	return not _mesh_queue.is_empty()


func has_collision_results() -> bool:
	return not _collision_queue.is_empty()


func pop_mesh_result() -> Dictionary:
	return _mesh_queue.pop_front()


func pop_collision_result() -> Dictionary:
	return _collision_queue.pop_front()


func has_navigation_results() -> bool:
	return not _nav_queue.is_empty()


func pop_navigation_result() -> Dictionary:
	return _nav_queue.pop_front()


## True while navigation geometry is being built or its results still wait to be applied.
func has_nav_work() -> bool:
	return _nav_group_id >= 0 or not _nav_queue.is_empty()


## Abandons an in-flight navigation task and drops its results. The results carry the chunk's
## `nav_revision`, so a superseded one would be discarded on commit anyway; dropping them here only
## saves the queue. Non-blocking for the same reason as the mesh jobs.
func cancel_navigation_jobs() -> void:
	if _nav_group_id >= 0:
		_abandoned_groups.append(_nav_group_id)
	_nav_group_id = -1
	_nav_holder = {}
	_nav_queue.clear()


## True while a group task is running or results are still waiting to be applied.
func has_pending_work() -> bool:
	return (
		_mesh_group_id >= 0
		or _collision_group_id >= 0
		or not _mesh_queue.is_empty()
		or not _collision_queue.is_empty()
	)


## Rebuild id the queued mesh results belong to, so the generator can drop results of a rebuild
## that a newer rebuild has already superseded.
func mesh_rebuild_id() -> int:
	return _mesh_rebuild_id


## Abandons in-flight mesh jobs and drops their results. Called when a rebuild supersedes them
## (the meshes are about to be regenerated anyway). Like collision, the worker only writes into
## its own refcounted holder, so no wait is needed - blocking here would stall the main thread
## for the duration of the superseded jobs.
func cancel_mesh_jobs() -> void:
	if _mesh_group_id >= 0:
		_abandoned_groups.append(_mesh_group_id)
	_mesh_group_id = -1
	_mesh_holder = {}
	_mesh_queue.clear()


## Abandons an in-flight collision task without waiting. It only writes into its own refcounted
## holder, and the results carry the revision of the chunk data they were built from, so stale
## results are dropped when they are popped (see TerrainGenerator._apply_pending_collision_results).
func cancel_collision_jobs() -> void:
	if _collision_group_id >= 0:
		_abandoned_groups.append(_collision_group_id)
	_collision_group_id = -1
	_collision_holder = {}
	_collision_queue.clear()


## Blocking wait used on teardown. Returns false when the tasks did not finish in time.
func wait_for_pending(timeout_ms: int = SHUTDOWN_WAIT_MS) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var groups: Array = [_mesh_group_id, _collision_group_id, _nav_group_id]
	groups.append_array(_abandoned_groups)
	for group_id in groups:
		if group_id < 0:
			continue
		while not WorkerThreadPool.is_group_task_completed(group_id):
			if Time.get_ticks_msec() > deadline:
				return false
			OS.delay_msec(10)
		WorkerThreadPool.wait_for_group_task_completion(group_id)
	_mesh_group_id = -1
	_mesh_holder = {}
	_collision_group_id = -1
	_collision_holder = {}
	_nav_group_id = -1
	_nav_holder = {}
	_abandoned_groups.clear()
	return true


## Results are pre-sized by task index, so only abandoned slots can be null.
func _collect(holder: Dictionary) -> Array:
	var collected: Array = []
	var jobs: Array = holder.get("jobs", [])
	var results: Array = holder.get("results", [])
	if results.size() != jobs.size():
		# Defensive: a holder that was never resized has nothing to hand over.
		return collected
	for result in results:
		if result != null:
			collected.append(result)
	return collected


## Builds one chunk's surface arrays and - for a holed chunk with collision enabled - its
## collision triangle soup, and publishes both into the holder.
##
## **Worker safe**: this is a static function that only touches the job data and the holder it is
## given. It must stay that way, so it cannot reach the generator, the scene tree, the renderer or
## the physics server. Creating the [ArrayMesh] and the [ConcavePolygonShape3D] happens on the
## main thread when the result is applied: `ArrayMesh.create_trimesh_shape()` from a worker
## deadlocks the process and the renderer's RID table is not thread safe.
##
## Everything that copies pixels lives in [ChunkJobs.run] on purpose: slicing the composed
## heightmap ([method Image.get_region]), the LOD downsampling, the one-sample normal border and the
## chunk's height bounds all used to run on the main thread for every chunk of a rebuild, which is
## the burst that made 1024-cell terrains hitch even though the mesh build itself was already
## off-thread. This function only owns the holder publication.
static func run_mesh_job(index: int, holder: Dictionary) -> void:
	var jobs: Array = holder["jobs"]
	if index < 0 or index >= jobs.size():
		return
	var result: Dictionary = ChunkJobs.run(jobs[index])
	if result.is_empty():
		return
	var mutex: Mutex = holder["mutex"]
	mutex.lock()
	var results: Array = holder["results"]
	results[index] = result
	mutex.unlock()


## Builds one chunk's navigation geometry (bake settings + source geometry data) on the worker and
## publishes it. **Worker safe** for the same reasons as [method run_mesh_job]: it only reads the
## job dictionary. [NavigationMesh] and [NavigationMeshSourceGeometryData3D] are documented
## thread-safe; the bake itself is kicked off from the main thread by the applier.
static func run_nav_job(index: int, holder: Dictionary) -> void:
	var jobs: Array = holder["jobs"]
	if index < 0 or index >= jobs.size():
		return
	var job: Dictionary = jobs[index]
	var built: Dictionary = NavigationBuilder.make_job(
		job["chunk"], job["grid"], job["final_map"], job.get("nav_holes"),
		job["template"], int(job.get("nav_budget", 0))
	)
	var mutex: Mutex = holder["mutex"]
	mutex.lock()
	var results: Array = holder["results"]
	results[index] = {
		"kind": ChunkJobs.JobKind.NAVIGATION,
		"key": job["key"],
		"revision": job.get("revision", 0),
		"nav_mesh": built.get("mesh"),
		"nav_geometry": built.get("geometry"),
	}
	mutex.unlock()


## Builds one chunk's collision triangle soup from a heightmap the generator already has.
## Worker safe for the same reasons as [method run_mesh_job].
static func run_collision_job(index: int, holder: Dictionary) -> void:
	var jobs: Array = holder["jobs"]
	if index < 0 or index >= jobs.size():
		return
	var job: Dictionary = jobs[index]
	var heightmap: Image = job.get("heightmap")
	if heightmap == null:
		return

	var faces := CollisionBuilder.build_faces(
		heightmap,
		job["size"],
		job.get("hole_mask", null),
		job.get("budget", 0),
		job.get("lod_level", 0)
	)

	var mutex: Mutex = holder["mutex"]
	mutex.lock()
	var results: Array = holder["results"]
	results[index] = {
		"key": job["key"],
		"collision_faces": faces,
		"revision": job.get("revision", 0)
	}
	mutex.unlock()
