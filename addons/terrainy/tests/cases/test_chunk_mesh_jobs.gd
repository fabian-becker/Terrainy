extends "res://addons/terrainy/tests/framework/test_case.gd"

## Tests for the parallel chunk mesh path of TerrainComposer.
##
## Chunk meshes used to be built by a single dedicated Thread that looped over the chunks one
## after another. They are now spread over WorkerThreadPool group tasks owned by
## TerrainChunkPipeline, whose body is static and only touches a refcounted holder - which is
## also what makes abandoning an in-flight task during teardown safe. The cases below pin the
## observable contract: every chunk is filled for both the parallel and the serial path, the
## worker body needs no composer instance, and repeated feature scans do not stack signal
## connections.

const TerrainCollisionBuilder = preload("res://addons/terrainy/helpers/terrain_collision_builder.gd")
const TerrainChunkPipeline = preload("res://addons/terrainy/helpers/terrain_chunk_pipeline.gd")

const CHUNKS_PER_AXIS := 2
const CHUNK_SIZE := 32
const RESOLUTION := CHUNKS_PER_AXIS * CHUNK_SIZE
const TERRAIN_SIZE := Vector2(64.0, 64.0)

var _parallel: TerrainComposer = null
var _serial: TerrainComposer = null

func before_all() -> void:
	_parallel = _make_composer(true)
	_serial = _make_composer(false)

func after_all() -> void:
	for composer in [_parallel, _serial]:
		if is_instance_valid(composer):
			composer.queue_free()
	_parallel = null
	_serial = null
	super.after_all()

func _make_composer(multithreaded: bool) -> TerrainComposer:
	var composer := TerrainComposer.new()
	composer.name = "ChunkTest"
	composer.auto_update = false
	composer.enable_lod = false
	composer.debug_logging = false
	composer.chunk_size = CHUNK_SIZE
	composer.resolution = RESOLUTION
	composer.terrain_size = TERRAIN_SIZE
	composer.max_worker_threads = CHUNKS_PER_AXIS * CHUNKS_PER_AXIS
	composer.use_multithreading = multithreaded
	# The same fixture on both paths so their meshes can be compared byte for byte.
	var hole := HoleNode.new()
	hole.influence_size = Vector2(20.0, 20.0)
	composer.add_child(hole)
	spawn(composer)
	# _ready() starts the initial rebuild; drain it before the test drives the composer.
	settle(composer)
	return composer

func _chunk_array(composer: TerrainComposer, key: Vector2i, array_type: int):
	var chunk = composer._chunk_manager.get_chunks().get(key)
	if chunk == null or chunk.mesh_instance == null or chunk.mesh_instance.mesh == null:
		return null
	return chunk.mesh_instance.mesh.surface_get_arrays(0)[array_type]

func _mesh_keys(composer: TerrainComposer) -> Array:
	var keys: Array = []
	for key in composer._chunk_manager.get_chunks().keys():
		if _chunk_array(composer, key, Mesh.ARRAY_VERTEX) != null:
			keys.append(key)
	keys.sort()
	return keys

func test_every_chunk_gets_a_mesh_and_its_tangents() -> void:
	_parallel.force_rebuild()
	t.check(settle(_parallel), "the chunk group task finished within the budget")
	t.check_eq(
		_parallel._chunk_manager.get_chunks().size(), CHUNKS_PER_AXIS * CHUNKS_PER_AXIS,
		"the terrain is split into the expected number of chunks"
	)
	t.check(not _parallel._pipeline.has_pending_work(), "nothing is left in flight")
	t.check_eq(_parallel._pipeline._mesh_group_id, -1, "the group id is released once collected")
	t.check(_parallel._pipeline._mesh_holder.is_empty(), "the holder is released after collection")
	var worst: float = 0.0
	for key in _parallel._chunk_manager.get_chunks().keys():
		var vertices: PackedVector3Array = _chunk_array(_parallel, key, Mesh.ARRAY_VERTEX)
		var tangents: PackedFloat32Array = _chunk_array(_parallel, key, Mesh.ARRAY_TANGENT)
		var normals: PackedVector3Array = _chunk_array(_parallel, key, Mesh.ARRAY_NORMAL)
		t.check(vertices != null, "chunk %s received a mesh" % key)
		if vertices == null:
			continue
		t.check_eq(
			tangents.size(), vertices.size() * 4,
			"chunk %s has a tangent for every vertex" % key
		)
		for i in vertices.size():
			var tangent := Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2])
			worst = maxf(worst, absf(tangent.length() - 1.0))
			worst = maxf(worst, absf(tangent.dot(normals[i])))
	t.check_almost_eq(worst, 0.0, "worker built meshes carry a valid tangent frame", 0.0002)

func test_worker_and_serial_results_are_identical() -> void:
	_parallel.force_rebuild()
	_serial.force_rebuild()
	t.check(settle(_parallel), "the parallel build finished")
	t.check(settle(_serial), "the serial build finished")
	var parallel_keys := _mesh_keys(_parallel)
	t.check_eq(
		parallel_keys, _mesh_keys(_serial),
		"both paths produce a mesh for the same chunks"
	)
	for key in parallel_keys:
		for array_type in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_INDEX]:
			t.check_eq(
				_chunk_array(_parallel, key, array_type), _chunk_array(_serial, key, array_type),
				"chunk %s array %d is identical on both paths" % [key, array_type]
			)

func test_chunks_are_clean_and_reported_after_the_task() -> void:
	_parallel.force_rebuild()
	t.check(settle(_parallel), "the build finished")
	t.check(not _parallel._pipeline.has_mesh_results(), "collected results are applied and cleared")
	t.check(not _parallel._chunk_manager.has_dirty_chunks(), "no chunk is left marked dirty")
	t.check(_parallel._final_heightmap != null, "the composed heightmap is kept for queries")
	t.check(not _parallel.is_rebuilding(), "a settled composer reports that it is idle")

## Rebuilding over and over is what used to corrupt the renderer's RID table once the meshes
## were created on worker threads ("Attempting to initialize the wrong RID"), which surfaced as
## an access violation while shutting the process down. Repeated rebuilds keep that path hot.
func test_repeated_parallel_rebuilds_stay_consistent() -> void:
	var baseline := -1
	for rebuild in 6:
		_parallel.force_rebuild()
		t.check(settle(_parallel), "rebuild %d finished" % rebuild)
		var keys := _mesh_keys(_parallel)
		t.check_eq(
			keys.size(), CHUNKS_PER_AXIS * CHUNKS_PER_AXIS,
			"rebuild %d filled every chunk" % rebuild
		)
		var vertices: PackedVector3Array = _chunk_array(_parallel, Vector2i(0, 0), Mesh.ARRAY_VERTEX)
		if baseline < 0:
			baseline = vertices.size()
		t.check_eq(
			vertices.size(), baseline,
			"rebuild %d produced the same chunk again" % rebuild
		)

func test_hole_chunk_uses_marching_squares_boundary_vertices() -> void:
	_parallel.force_rebuild()
	t.check(settle(_parallel), "the build finished")
	var flat_chunk_vertices := (CHUNK_SIZE + 1) * (CHUNK_SIZE + 1)
	var holed_chunks := 0
	for key in _mesh_keys(_parallel):
		var vertices: PackedVector3Array = _chunk_array(_parallel, key, Mesh.ARRAY_VERTEX)
		if vertices.size() > flat_chunk_vertices:
			holed_chunks += 1
	t.check(
		holed_chunks > 0,
		"the hole feature adds boundary vertices to at least one chunk (%d found)" % holed_chunks
	)
	var holes_seen := false
	for key in _parallel._chunk_manager.get_chunks().keys():
		var chunk = _parallel._chunk_manager.get_chunks()[key]
		var mask_has_holes: bool = TerrainCollisionBuilder.mask_has_holes(chunk.hole_mask)
		holes_seen = holes_seen or mask_has_holes
		# The composer caches that answer on the chunk when the mask slice is extracted, so the
		# collision update does not have to rescan the mask.
		t.check_eq(
			chunk.has_holes, mask_has_holes,
			"chunk %s caches the same hole answer as the mask scan" % key
		)
	t.check(holes_seen, "at least one chunk reports a hole mask with holes")

func test_worker_body_needs_no_composer_instance() -> void:
	# TerrainChunkPipeline.run_mesh_job() is static and only touches the holder: this is the
	# property that lets an abandoned in-flight task outlive the node it was started from.
	var heightmaps := [
		make_ramp_image(Vector2i(17, 17), 40.0),
		make_ramp_image(Vector2i(17, 17), 80.0),
	]
	var holder := {
		"jobs": [],
		"results": [],
		"mutex": Mutex.new(),
	}
	holder["jobs"].append({
		"key": Vector2i(0, 0),
		"heightmap": heightmaps[0],
		"hole_mask": null,
		"has_holes": false,
		"size": Vector2(16.0, 16.0),
		"lod_level": 0,
	})
	holder["jobs"].append({
		"key": Vector2i(1, 0),
		"heightmap": heightmaps[1],
		"hole_mask": null,
		"has_holes": false,
		"size": Vector2(16.0, 16.0),
		"lod_level": 0,
	})
	# A carved mask and a mask that is allocated but empty, both asking for collision soup.
	var carved := make_flat_image(Vector2i(17, 17), 0.0)
	carved.set_pixel(8, 8, Color(1.0, 0.0, 0.0, 1.0))
	holder["jobs"].append({
		"key": Vector2i(0, 1),
		"heightmap": heightmaps[0],
		"hole_mask": carved,
		"has_holes": true,
		"size": Vector2(16.0, 16.0),
		"lod_level": 0,
		"collision": true,
		"collision_budget": 0,
	})
	holder["jobs"].append({
		"key": Vector2i(1, 1),
		"heightmap": heightmaps[1],
		"hole_mask": make_flat_image(Vector2i(17, 17), 0.0),
		"has_holes": false,
		"size": Vector2(16.0, 16.0),
		"lod_level": 0,
		"collision": true,
		"collision_budget": 0,
	})
	holder["results"].resize(4)
	TerrainChunkPipeline.run_mesh_job(0, holder)
	TerrainChunkPipeline.run_mesh_job(1, holder)
	TerrainChunkPipeline.run_mesh_job(2, holder)
	TerrainChunkPipeline.run_mesh_job(3, holder)
	t.check(holder["results"][0] != null, "job 0 published a result")
	t.check(holder["results"][1] != null, "job 1 published a result")
	# The collision soup is built on the worker too: only the shape itself has to be created on
	# the main thread, because creating a physics shape from a worker deadlocks the process.
	t.check(
		holder["results"][2]["collision_faces"].size() > 0,
		"a carved chunk gets its collision soup from the worker"
	)
	t.check_eq(
		holder["results"][2]["collision_faces"].size(),
		holder["results"][2]["arrays"][Mesh.ARRAY_INDEX].size(),
		"an exact collision budget reuses the visual geometry"
	)
	t.check_eq(
		holder["results"][3]["collision_faces"].size(), 0,
		"a chunk without holes needs no collision soup"
	)
	# The worker must publish plain surface arrays, never an ArrayMesh: creating a renderer
	# resource (RID) off the main thread corrupts the renderer's RID table, which shows up as
	# "Attempting to initialize the wrong RID" and ends in a shutdown access violation.
	t.check_eq(
		typeof(holder["results"][0]["arrays"]), TYPE_ARRAY,
		"the worker publishes surface arrays"
	)
	t.check(
		not holder["results"][0].has("mesh"),
		"the worker does not create renderer resources"
	)
	t.check_eq(holder["results"][0]["key"], Vector2i(0, 0), "results keep their job key")
	t.check_eq(
		holder["results"][1]["heightmap"], heightmaps[1],
		"results keep the heightmap they were built from"
	)

func test_collision_worker_decimates_to_the_budget() -> void:
	var holder := {
		"jobs": [{
			"key": Vector2i(0, 0),
			"heightmap": make_ramp_image(Vector2i(65, 65), 30.0),
			"hole_mask": null,
			"size": Vector2(64.0, 64.0),
			"budget": 512,
			"lod_level": 0,
			"revision": 3,
		}],
		"results": [],
		"mutex": Mutex.new(),
	}
	holder["results"].resize(1)
	TerrainChunkPipeline.run_collision_job(0, holder)
	var result: Dictionary = holder["results"][0]
	var exact_faces := 2 * 64 * 64
	t.check(result["collision_faces"].size() > 0, "the collision worker built a soup")
	t.check(
		result["collision_faces"].size() < exact_faces,
		"a budget decimates the soup (%d of %d faces)" % [result["collision_faces"].size(), exact_faces]
	)
	t.check_eq(result["revision"], 3, "the soup carries the revision it was built from")
	t.check_eq(result["key"], Vector2i(0, 0), "the soup keeps its job key")

func test_out_of_range_and_null_jobs_are_ignored() -> void:
	var holder := {
		"jobs": [{"key": Vector2i.ZERO, "heightmap": null, "size": Vector2(8.0, 8.0), "lod_level": 0}],
		"results": [],
		"mutex": Mutex.new(),
	}
	holder["results"].resize(1)
	TerrainChunkPipeline.run_mesh_job(0, holder)
	TerrainChunkPipeline.run_mesh_job(5, holder)
	TerrainChunkPipeline.run_mesh_job(-1, holder)
	t.check_eq(holder["results"][0], null, "a job without a heightmap publishes nothing")

func test_collect_group_results_skips_abandoned_slots() -> void:
	# Abandoning a group task on teardown leaves null slots behind; collecting them must not
	# hand nulls to _apply_pending_chunk_results().
	var pipeline: TerrainChunkPipeline = _parallel._pipeline
	var holder := {
		"jobs": [{}, {}, {}],
		"results": [{"key": Vector2i(0, 0)}, null, {"key": Vector2i(1, 0)}],
		"mutex": Mutex.new(),
	}
	var collected: Array = pipeline._collect(holder)
	t.check_eq(collected.size(), 2, "only completed slots are collected")
	t.check_eq(collected[0]["key"], Vector2i(0, 0), "collection keeps the job order")
	t.check_eq(collected[1]["key"], Vector2i(1, 0), "collection keeps the job order")

func test_rescanning_features_does_not_stack_signal_connections() -> void:
	# Regression: the connection used to be made with a bound callable while is_connected()
	# and disconnect() used the unbound one, so every rescan added another connection and
	# every feature edit triggered one more rebuild.
	var composer := TerrainComposer.new()
	composer.name = "SignalTest"
	composer.auto_update = false
	composer.use_multithreading = false
	composer.resolution = 16
	composer.chunk_size = 16
	composer.terrain_size = Vector2(32.0, 32.0)
	var feature := HillNode.new()
	feature.influence_size = Vector2(8.0, 8.0)
	composer.add_child(feature)
	spawn(composer)
	var feature_signal := feature.parameters_changed
	t.check(feature_signal.is_connected(composer._feature_changed_callable(feature)), "the feature is subscribed")
	var baseline: int = feature_signal.get_connections().size()
	for i in 3:
		composer.force_rebuild()
	t.check_eq(
		feature_signal.get_connections().size(), baseline,
		"three rebuilds do not add connections (%d connections)" % feature_signal.get_connections().size()
	)
	t.check_eq(baseline, 1, "a single feature holds a single connection")
