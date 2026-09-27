class_name TerrainChunkPipeline
extends RefCounted

## Owns the asynchronous half of chunk generation.
##
## [TerrainComposer] knows how to slice its composed heightmap into per-chunk jobs; this class
## takes those jobs and owns everything after that:
##
## - dispatching them to a [WorkerThreadPool] group task (or running them inline when threading is
##   disabled),
## - collecting the finished results without blocking the main thread,
## - and keeping them queued until the composer has drained the queue.
##
## The composer drains the queues itself, one result at a time, so it can spread the main-thread
## work (creating meshes, handing shapes to the physics server) over several frames.
##
## The workers only ever touch the refcounted holder dictionary handed to them, never the
## composer or this class, so an in-flight - or abandoned - task can never call back into a node
## that is being modified or freed.

const TerrainMeshGenerator = preload("res://addons/terrainy/helpers/terrain_mesh_generator.gd")
const TerrainCollisionBuilder = preload("res://addons/terrainy/helpers/terrain_collision_builder.gd")
const TerrainDiagnostics = preload("res://addons/terrainy/helpers/terrain_diagnostics.gd")

## Wall time to wait for worker tasks when the caller cannot accept a blocking wait (teardown).
const SHUTDOWN_WAIT_MS := 5000

## Run the jobs on the worker pool; when false everything happens on the calling thread.
var use_threads: bool = true
## Upper bound of parallel tasks per group.
var worker_threads: int = 4
## Optional diagnostics sink; receives the worker wall times and the job counts.
var diagnostics: TerrainDiagnostics = null

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


## Hands chunk mesh jobs to the worker pool. Each job is a dictionary with the keys the mesh
## worker reads (`key`, `heightmap`, `hole_mask`, `has_holes`, `size`, `lod_level`, `collision`,
## `collision_budget`); see [method run_mesh_job].
## Jobs left over from a previous dispatch are dropped, they describe a superseded heightmap.
func dispatch_mesh_jobs(jobs: Array, rebuild_id: int) -> void:
	cancel_mesh_jobs()
	if jobs.is_empty():
		return
	_mesh_rebuild_id = rebuild_id
	_mesh_dispatch_ms = Time.get_ticks_msec()
	_dispatch(jobs, run_mesh_job, "Terrainy chunk meshes", "_mesh")


## Hands collision-only jobs to the worker pool. Each job is a dictionary with the keys the
## collision worker reads (`key`, `heightmap`, `hole_mask`, `size`, `budget`, `lod_level`,
## `revision`); see [method run_collision_job].
func dispatch_collision_jobs(jobs: Array) -> void:
	cancel_collision_jobs()
	if jobs.is_empty():
		return
	_dispatch(jobs, run_collision_job, "Terrainy chunk collision", "_collision")


func _dispatch(jobs: Array, body: Callable, description: String, prefix: String) -> void:
	var holder := {
		"jobs": jobs,
		"results": [],
		"mutex": Mutex.new()
	}
	holder["results"].resize(jobs.size())

	# One job is not worth the pool round trip, and neither is anything when threading is off.
	if not use_threads or jobs.size() == 1:
		for i in jobs.size():
			body.call(i, holder)
		_publish(prefix, holder)
		return

	var tasks_needed := clampi(worker_threads, 1, jobs.size())
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
	else:
		_collision_queue.append_array(results)


## Collects finished worker results into the internal queues. Never blocks: a group task that is
## still running is simply left alone until the next call.
func poll() -> void:
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


func has_mesh_results() -> bool:
	return not _mesh_queue.is_empty()


func has_collision_results() -> bool:
	return not _collision_queue.is_empty()


func pop_mesh_result() -> Dictionary:
	return _mesh_queue.pop_front()


func pop_collision_result() -> Dictionary:
	return _collision_queue.pop_front()


## True while a group task is running or results are still waiting to be applied.
func has_pending_work() -> bool:
	return (
		_mesh_group_id >= 0
		or _collision_group_id >= 0
		or not _mesh_queue.is_empty()
		or not _collision_queue.is_empty()
	)


## Rebuild id the queued mesh results belong to, so the composer can drop results of a rebuild
## that a newer rebuild has already superseded.
func mesh_rebuild_id() -> int:
	return _mesh_rebuild_id


## Waits for the mesh jobs to finish and drops their results. Called when a rebuild supersedes
## them (the meshes are about to be regenerated anyway).
func cancel_mesh_jobs() -> void:
	if _mesh_group_id >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_mesh_group_id)
		_mesh_group_id = -1
		_mesh_holder = {}
	_mesh_queue.clear()


## Abandons an in-flight collision task without waiting. It only writes into its own refcounted
## holder, and the results carry the revision of the chunk data they were built from, so stale
## results are dropped when they are popped (see TerrainComposer._apply_pending_collision_results).
func cancel_collision_jobs() -> void:
	_collision_group_id = -1
	_collision_holder = {}
	_collision_queue.clear()


## Blocking wait used on teardown. Returns false when the tasks did not finish in time.
func wait_for_pending(timeout_ms: int = SHUTDOWN_WAIT_MS) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	for group_id in [_mesh_group_id, _collision_group_id]:
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
## given. It must stay that way, so it cannot reach the composer, the scene tree, the renderer or
## the physics server. Creating the [ArrayMesh] and the [ConcavePolygonShape3D] happens on the
## main thread when the result is applied: `ArrayMesh.create_trimesh_shape()` from a worker
## deadlocks the process and the renderer's RID table is not thread safe.
static func run_mesh_job(index: int, holder: Dictionary) -> void:
	var jobs: Array = holder["jobs"]
	if index < 0 or index >= jobs.size():
		return
	var job: Dictionary = jobs[index]
	var heightmap: Image = job.get("heightmap")
	if heightmap == null:
		return

	var mesh := TerrainMeshGenerator.generate_surface_arrays(
		heightmap, job["size"], job.get("hole_mask", null)
	)

	# Hole chunks need a triangle mesh for collision (a HeightMapShape3D cannot express carved
	# holes), so build that soup here while the heightmap is hot in cache, off the main thread.
	var collision_faces := PackedVector3Array()
	var has_holes: bool = job.get("has_holes", false)
	if job.get("collision", false) and has_holes:
		collision_faces = TerrainCollisionBuilder.build_faces(
			heightmap,
			job["size"],
			job.get("hole_mask", null),
			job.get("collision_budget", 0),
			job.get("lod_level", 0),
			mesh
		)

	var mutex: Mutex = holder["mutex"]
	mutex.lock()
	var results: Array = holder["results"]
	results[index] = {
		"key": job["key"],
		"arrays": mesh,
		"collision_faces": collision_faces,
		"heightmap": heightmap,
		"hole_mask": job.get("hole_mask", null),
		"has_holes": has_holes,
		"lod_level": job["lod_level"]
	}
	mutex.unlock()


## Builds one chunk's collision triangle soup from a heightmap the composer already has.
## Worker safe for the same reasons as [method run_mesh_job].
static func run_collision_job(index: int, holder: Dictionary) -> void:
	var jobs: Array = holder["jobs"]
	if index < 0 or index >= jobs.size():
		return
	var job: Dictionary = jobs[index]
	var heightmap: Image = job.get("heightmap")
	if heightmap == null:
		return

	var faces := TerrainCollisionBuilder.build_faces(
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
