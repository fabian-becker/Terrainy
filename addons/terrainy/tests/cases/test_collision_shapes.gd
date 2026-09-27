extends "res://addons/terrainy/tests/framework/test_case.gd"

## Tests for the chunk collision path of TerrainComposer.
##
## Chunk collisions used to be rebuilt from scratch on the main thread on every rebuild: a holed
## chunk went through ArrayMesh.create_trimesh_shape(), which costs roughly 2 us per triangle and
## therefore more than a second for a 513x513 chunk. The collision soup is now built on a
## TerrainChunkPipeline worker (data only - creating a physics shape off the main thread
## deadlocks the process), the shape is cached on the chunk, and a triangle budget decimates the
## collision grid.
##
## The cases below pin the observable contract: hole free chunks keep their cheap HeightMapShape3D
## whatever the budget is, holed chunks get a ConcavePolygonShape3D that matches the visual
## geometry at the exact budget, the decimated grid stays aligned with the fine grid and on the
## world extent, and the shape instances survive rebuilds.

const TerrainCollisionBuilder = preload("res://addons/terrainy/helpers/terrain_collision_builder.gd")

const CHUNKS_PER_AXIS := 2
const CHUNK_SIZE := 32
const RESOLUTION := CHUNKS_PER_AXIS * CHUNK_SIZE
const TERRAIN_SIZE := Vector2(64.0, 64.0)
const TOLERANCE := 0.0002
## Budget that forces a stride of 4 on a 33x33 chunk heightmap (2048 exact triangles).
## TerrainCollisionBuilder.stride_for() is what turns it into the actual sample step.
const COARSE_BUDGET := 128

var _exact: TerrainComposer = null
var _coarse: TerrainComposer = null
var _plain: TerrainComposer = null

func before_all() -> void:
	_exact = _make_composer(0, true)
	_coarse = _make_composer(COARSE_BUDGET, true)
	_plain = _make_composer(COARSE_BUDGET, false)

func after_all() -> void:
	for composer in [_exact, _coarse, _plain]:
		if is_instance_valid(composer):
			composer.queue_free()
	_exact = null
	_coarse = null
	_plain = null
	super.after_all()

func _make_composer(budget: int, carve_hole: bool) -> TerrainComposer:
	var composer := TerrainComposer.new()
	composer.name = "CollisionTest"
	composer.auto_update = false
	composer.enable_lod = false
	composer.debug_logging = false
	composer.chunk_size = CHUNK_SIZE
	composer.resolution = RESOLUTION
	composer.terrain_size = TERRAIN_SIZE
	composer.use_multithreading = false
	# Set before _ready() so that the initial rebuild already uses the requested budget.
	composer.collision_triangle_budget = budget
	if carve_hole:
		var hole := HoleNode.new()
		hole.influence_size = Vector2(20.0, 20.0)
		composer.add_child(hole)
	spawn(composer)
	settle(composer)
	return composer

func _chunk(composer: TerrainComposer, key: Vector2i):
	return composer._chunk_manager.get_chunks().get(key)

func _chunk_keys(composer: TerrainComposer) -> Array:
	var keys: Array = composer._chunk_manager.get_chunks().keys()
	keys.sort()
	return keys

func _visual_arrays(composer: TerrainComposer, key: Vector2i) -> Array:
	var chunk = _chunk(composer, key)
	if chunk == null or chunk.mesh_instance == null or chunk.mesh_instance.mesh == null:
		return []
	return chunk.mesh_instance.mesh.surface_get_arrays(0)

func _is_holed(composer: TerrainComposer, key: Vector2i) -> bool:
	var chunk = _chunk(composer, key)
	return chunk != null and TerrainCollisionBuilder.mask_has_holes(chunk.hole_mask)

## The stride the composer's budget maps to for this chunk, so the assertions do not hardcode it.
func _stride_of(composer: TerrainComposer, key: Vector2i) -> int:
	var chunk = _chunk(composer, key)
	if chunk == null or chunk.heightmap == null:
		return 1
	return TerrainCollisionBuilder.stride_for(
		chunk.heightmap, composer._collision_budget_for(chunk), chunk.lod_level
	)

## A stride of s gives up to 1/s^2 of the exact collision triangles. The tolerance covers the
## hole boundary, whose marching squares triangles are relatively heavier on the coarse grid
## (measured: stride 4 on a 33x33 chunk keeps 6.5% instead of 6.25%).
func _check_decimated(composer: TerrainComposer, key: Vector2i, faces: PackedVector3Array, message: String) -> void:
	var chunk = _chunk(composer, key)
	var stride := _stride_of(composer, key)
	var exact := TerrainCollisionBuilder.build_faces(
		chunk.heightmap, composer._get_chunk_world_size(chunk), chunk.hole_mask, 0
	)
	t.check(stride > 1, "the fixture decimates chunk %s (stride %d)" % [key, stride])
	t.check(
		faces.size() < exact.size(),
		"%s: chunk %s is decimated (%d vs %d exact faces)" % [
			message, key, faces.size(), exact.size()
		]
	)
	t.check(
		faces.size() * stride * stride <= exact.size() * 2,
		"%s: stride %d of chunk %s keeps about 1/%d of the exact faces (%d vs %d)" % [
			message, stride, key, stride * stride, faces.size(), exact.size()
		]
	)

func _rebuild(composer: TerrainComposer) -> void:
	composer.force_rebuild()
	t.check(settle(composer), "the rebuild finished within the budget")

## Every composer starts at the exact geometry so nothing changes for existing projects.
func test_the_default_quality_keeps_the_exact_geometry() -> void:
	t.check_eq(_exact.collision_triangle_budget, 0, "the exact fixture runs without a budget")
	var default_composer := TerrainComposer.new()
	t.check_eq(
		default_composer.collision_quality, TerrainComposer.CollisionQuality.EXACT,
		"the exported default is the exact preset"
	)
	t.check_eq(
		default_composer._collision_budget_for(null), 0,
		"the exact preset has no triangle budget"
	)
	default_composer.collision_quality = TerrainComposer.CollisionQuality.BALANCED
	t.check(
		default_composer._collision_budget_for(null) > 0,
		"a decimating preset maps to a positive budget"
	)
	default_composer.free()

func test_the_quality_presets_are_ordered_by_detail() -> void:
	var exact := TerrainCollisionBuilder.budget_for_quality(TerrainCollisionBuilder.Quality.EXACT)
	var balanced := TerrainCollisionBuilder.budget_for_quality(TerrainCollisionBuilder.Quality.BALANCED)
	var fast := TerrainCollisionBuilder.budget_for_quality(TerrainCollisionBuilder.Quality.FAST)
	t.check_eq(exact, 0, "Exact keeps every triangle")
	t.check(balanced > fast, "Balanced keeps at least as many triangles as Fast (%d vs %d)" % [balanced, fast])
	t.check(fast > 0, "Fast still keeps a positive budget")
	# The composer and the builder expose their own enum; they are mapped one to one.
	t.check_eq(
		TerrainComposer.CollisionQuality.FAST, TerrainCollisionBuilder.Quality.FAST,
		"both enums share their order"
	)

## Hole free chunks keep the cheap HeightMapShape3D: decimating them would only move geometry
## away from the visual mesh for nothing.
func test_hole_free_chunks_use_a_heightmap_shape_at_every_budget() -> void:
	# _plain has no hole feature at all, and still runs with a coarse budget: every chunk must
	# keep the cheap heightmap shape.
	var holed := 0
	for key in _chunk_keys(_plain):
		var chunk = _chunk(_plain, key)
		if TerrainCollisionBuilder.mask_has_holes(chunk.hole_mask):
			holed += 1
			continue
		t.check(
			chunk.collision_shape.shape is HeightMapShape3D,
			"chunk %s keeps a heightmap shape under a decimating budget" % key
		)
		t.check(
			chunk.collision_trimesh == null,
			"chunk %s does not keep a trimesh it never needed" % key
		)
	t.check_eq(holed, 0, "a terrain without a hole feature has no holed chunk")

	# A terrain that mixes both: the carved chunks get a trimesh, the others keep their heightmap.
	holed = 0
	for key in _chunk_keys(_coarse):
		var chunk = _chunk(_coarse, key)
		var shape = chunk.collision_shape.shape
		if TerrainCollisionBuilder.mask_has_holes(chunk.hole_mask):
			holed += 1
			t.check(
				shape is ConcavePolygonShape3D,
				"the carved chunk %s gets a trimesh" % key
			)
			t.check(
				not shape.get_faces().is_empty(),
				"the carved chunk %s keeps collision geometry" % key
			)
		else:
			t.check(
				shape is HeightMapShape3D,
				"the untouched chunk %s keeps its heightmap shape" % key
			)
	t.check(holed > 0, "the hole feature carved at least one chunk (%d found)" % holed)

## A HeightMapShape3D cannot express a carved hole (it would fill the hole back in), so holed
## chunks need a triangle mesh - and with the exact budget that mesh is exactly the visible one.
func test_holed_chunks_match_the_visual_geometry_when_exact() -> void:
	var holed := 0
	for key in _chunk_keys(_exact):
		var chunk = _chunk(_exact, key)
		if not _is_holed(_exact, key):
			t.check(
				chunk.collision_shape.shape is HeightMapShape3D,
				"chunk %s without hole pixels keeps the heightmap shape" % key
			)
			continue
		holed += 1
		var shape = chunk.collision_shape.shape
		t.check(
			shape is ConcavePolygonShape3D,
			"the holed chunk %s gets a trimesh shape" % key
		)
		if not (shape is ConcavePolygonShape3D):
			continue
		var visual: Array = _visual_arrays(_exact, key)
		var expected := TerrainCollisionBuilder.surface_arrays_to_faces(visual)
		var faces: PackedVector3Array = shape.get_faces()
		t.check_eq(
			faces.size(), visual[Mesh.ARRAY_INDEX].size(),
			"the collision mesh has one face per visual triangle on chunk %s" % key
		)
		t.check_eq(faces, expected, "chunk %s collides with exactly the visible surface" % key)
		t.check_eq(
			chunk.collision_shape.scale, Vector3.ONE, "the collision shape is not scaled"
		)
	t.check(holed > 0, "the hole feature carved at least one chunk (%d found)" % holed)

## The decimated grid has to stay on the fine grid and cover the same world extent, otherwise
## players would walk through geometry the renderer draws somewhere else.
func test_decimated_collision_stays_on_the_grid_and_on_the_extent() -> void:
	var holed := 0
	for key in _chunk_keys(_coarse):
		if not _is_holed(_coarse, key):
			continue
		holed += 1
		var chunk = _chunk(_coarse, key)
		var visual: Array = _visual_arrays(_coarse, key)
		var faces: PackedVector3Array = chunk.collision_shape.shape.get_faces()
		var stride := _stride_of(_coarse, key)
		t.check(not faces.is_empty(), "chunk %s still has collision geometry" % key)
		_check_decimated(_coarse, key, faces, "on the grid")
		# The decimated surface must stay inside the visible one: it may miss detail, but it
		# must not be shifted, scaled up or leak the hole sentinel height.
		var collision_bounds := _bounds_of(faces)
		var visual_bounds := _bounds_of(visual[Mesh.ARRAY_VERTEX])
		for axis in [0, 2]:
			t.check(
				collision_bounds[axis] >= visual_bounds[axis] - TOLERANCE
				and collision_bounds[axis + 3] <= visual_bounds[axis + 3] + TOLERANCE,
				"chunk %s collision stays inside the visible area on axis %d" % [key, axis]
			)
		t.check(
			collision_bounds[1] >= visual_bounds[1] - TOLERANCE
			and collision_bounds[4] <= visual_bounds[4] + TOLERANCE,
			"chunk %s collision heights stay in the visible height range (%f..%f vs %f..%f)" % [
				key, collision_bounds[1], collision_bounds[4], visual_bounds[1], visual_bounds[4]
			]
		)
		# Sample step of this chunk: resolution + 1 samples spread over 32 world units. Marching
		# squares boundary vertices sit exactly half a coarse cell away from the grid.
		var step := TERRAIN_SIZE.x / float(CHUNKS_PER_AXIS) / float(CHUNK_SIZE)
		var coarse_step := step * stride
		var half := TERRAIN_SIZE.x * 0.25
		var worst := 0.0
		for vertex in faces:
			for position in [vertex.x, vertex.z]:
				var frac := fposmod((position + half) / coarse_step, 1.0)
				worst = maxf(worst, minf(frac, minf(absf(frac - 0.5), 1.0 - frac)))
		t.check_almost_eq(
			worst, 0.0,
			"chunk %s collision vertices land on the decimated grid" % key, TOLERANCE
		)
	t.check(holed > 0, "the hole feature carved at least one chunk (%d found)" % holed)

## The shapes are cached per chunk: a rebuild updates the existing resources instead of
## allocating new ones (and, for the trimesh, instead of letting the engine rebuild the mesh
## shape from the ArrayMesh).
func test_collision_shapes_are_reused_across_rebuilds() -> void:
	var holed_key := Vector2i(-1, -1)
	for key in _chunk_keys(_exact):
		if _is_holed(_exact, key):
			holed_key = key
			break
	t.check(holed_key != Vector2i(-1, -1), "one chunk carries a hole")
	var trimesh = _chunk(_exact, holed_key).collision_trimesh
	# The hole free fixture is the one that has chunks on the heightmap path.
	var height_shape = _chunk(_plain, _chunk_keys(_plain)[0]).height_shape
	t.check(trimesh != null, "the holed chunk caches its trimesh")
	t.check(height_shape != null, "the hole free chunk caches its heightmap shape")
	var faces_before: PackedVector3Array = trimesh.get_faces()
	_rebuild(_exact)
	_rebuild(_exact)
	t.check(
		is_same(_chunk(_exact, holed_key).collision_trimesh, trimesh),
		"rebuilds keep the same trimesh instance"
	)
	t.check_eq(
		_chunk(_exact, holed_key).collision_trimesh.get_faces(), faces_before,
		"rebuilds refresh the same faces"
	)
	_rebuild(_plain)
	t.check(
		is_same(_chunk(_plain, _chunk_keys(_plain)[0]).height_shape, height_shape),
		"rebuilds keep the same heightmap shape instance"
	)

## Toggling the collision on and off re-applies the shapes without a rebuild: the trimesh path
## then has to build its own soup (no worker result to reuse), decimating it when asked to.
func test_toggling_collision_re_applies_shapes_without_a_rebuild() -> void:
	for composer in [_exact, _coarse]:
		composer.generate_collision = false
		# The setter only queues the refresh (dropping the shapes needs no worker), so the
		# shapes go away with the next frame - which is what a batch of property writes wants.
		t.check(settle(composer), "the queued collision refresh finished")
		for key in _chunk_keys(composer):
			var chunk = _chunk(composer, key)
			t.check(chunk.collision_shape.shape == null, "chunk %s loses its shape" % key)
			t.check(chunk.collision_trimesh == null, "chunk %s drops its cached trimesh" % key)
		composer.generate_collision = true
		# Rebuilding the soups is worker work, so the shapes land over the next frames.
		t.check(settle(composer), "the collision refresh finished")
		var holed := 0
		for key in _chunk_keys(composer):
			var chunk = _chunk(composer, key)
			t.check(chunk.collision_shape.shape != null, "chunk %s gets a shape back" % key)
			if not _is_holed(composer, key):
				continue
			holed += 1
			var faces: PackedVector3Array = chunk.collision_shape.shape.get_faces()
			var visual: Array = _visual_arrays(composer, key)
			var stride := _stride_of(composer, key)
			t.check(not faces.is_empty(), "chunk %s collides again" % key)
			if stride > 1:
				_check_decimated(composer, key, faces, "without a worker result")
			else:
				t.check_eq(
					faces, TerrainCollisionBuilder.surface_arrays_to_faces(visual),
					"the exact budget re-applies the visible surface on chunk %s" % key
				)
		t.check(holed > 0, "the fixture has a holed chunk to check (%d found)" % holed)

## Collision properties are assigned in batches (scene load, inspector drag), and building the soup
## of a holed chunk is worker work, so a setter only marks the collision dirty: the refresh lands
## once per frame, for the last value that was assigned.
func test_collision_setters_only_queue_and_coalesce() -> void:
	var composer := _make_composer(COARSE_BUDGET, true)
	var holed_key := Vector2i(-1, -1)
	for key in _chunk_keys(composer):
		if _is_holed(composer, key):
			holed_key = key
			break
	t.check(holed_key != Vector2i(-1, -1), "the fixture has a holed chunk")
	var before: PackedVector3Array = _chunk(composer, holed_key).collision_shape.shape.get_faces()
	t.check(not before.is_empty(), "the holed chunk starts with collision geometry")

	var shape = _chunk(composer, holed_key).collision_shape.shape
	composer.collision_triangle_budget = 0
	composer.collision_quality = TerrainComposer.CollisionQuality.FAST
	composer.collision_layer = 5
	t.check(composer._collision_refresh_pending, "the setters only queue the collision refresh")
	t.check(composer._collision_layer_pending, "a layer change is queued as its own step")
	t.check(composer.is_rebuilding(), "queued collision work counts as a pending rebuild")
	t.check_eq(
		_chunk(composer, holed_key).collision_shape.shape.get_faces(), before,
		"no setter rebuilds anything before the frame pump"
	)

	t.check(settle(composer), "the queued refresh lands over the next frames")
	t.check(not composer._collision_refresh_pending, "the refresh flag is consumed")
	t.check(not composer._collision_layer_pending, "the layer flag is consumed")
	t.check(not composer.is_rebuilding(), "nothing is left pending")

	# The refresh used the last values: the coarse budget is gone, so the trimesh is exact again.
	t.check_eq(
		composer._collision_budget_for(_chunk(composer, holed_key)),
		TerrainCollisionBuilder.budget_for_quality(TerrainCollisionBuilder.Quality.FAST),
		"the last quality assignment won"
	)
	t.check_eq(
		_chunk(composer, holed_key).static_body.collision_layer, 5,
		"the queued layer change was applied"
	)
	t.check(
		is_same(_chunk(composer, holed_key).collision_shape.shape, shape),
		"a layer change reuses the existing shape instance"
	)
	var faces: PackedVector3Array = _chunk(composer, holed_key).collision_shape.shape.get_faces()
	t.check_eq(
		faces, TerrainCollisionBuilder.surface_arrays_to_faces(_visual_arrays(composer, holed_key)),
		"the coalesced refresh rebuilt the soup of the holed chunk"
	)

## (min x, min y, min z, max x, max y, max z) of a vertex list, so bounds can be compared with a
## single almost-equal check.
func _bounds_of(vertices: PackedVector3Array) -> PackedFloat32Array:
	var bounds := PackedFloat32Array([INF, INF, INF, -INF, -INF, -INF])
	for vertex in vertices:
		bounds[0] = minf(bounds[0], vertex.x)
		bounds[1] = minf(bounds[1], vertex.y)
		bounds[2] = minf(bounds[2], vertex.z)
		bounds[3] = maxf(bounds[3], vertex.x)
		bounds[4] = maxf(bounds[4], vertex.y)
		bounds[5] = maxf(bounds[5], vertex.z)
	return bounds

func _check_same_bounds(
	actual: PackedFloat32Array, expected: PackedFloat32Array, message: String
) -> void:
	var worst := 0.0
	for i in 6:
		worst = maxf(worst, absf(actual[i] - expected[i]))
	t.check_almost_eq(worst, 0.0, "%s (%s vs %s)" % [message, actual, expected], TOLERANCE)

# --- TerrainCollisionBuilder level (deterministic, no scene tree) ----------------------------

const RAMP_GRID := Vector2i(9, 9)
## make_ramp_image() spreads RAMP_HEIGHT over (x + y), so a 9x9 grid with a height of 80 gives
## exactly 5 * (x + y) - which makes the sampled heights predictable.
const RAMP_HEIGHT := 80.0
const RAMP_HEIGHT_STEP := RAMP_HEIGHT / 16.0
const RAMP_SIZE := Vector2(8.0, 8.0)
## Budgets that make stride_for() pick 2, respectively 4, on the 9x9 ramp above (128 triangles).
const RAMP_BUDGET_STRIDE_2 := 64
const RAMP_BUDGET_STRIDE_4 := 12

func _ramp() -> Image:
	return make_ramp_image(RAMP_GRID, RAMP_HEIGHT)

func test_downsample_exact_samples_every_nth_pixel() -> void:
	var source := _ramp()
	var small := TerrainCollisionBuilder.downsample_exact(source, 2)
	t.check_eq(small.get_width(), 5, "the decimated image is (res / stride) + 1 wide")
	t.check_eq(small.get_height(), 5, "and as tall as it is wide")
	var worst := 0.0
	for y in small.get_height():
		for x in small.get_width():
			worst = maxf(worst, absf(small.get_pixel(x, y).r - source.get_pixel(x * 2, y * 2).r))
	t.check_almost_eq(worst, 0.0, "every sample is exactly a source pixel", TOLERANCE)
	t.check_almost_eq(
		small.get_pixel(2, 3).r, RAMP_HEIGHT_STEP * (2 * 2 + 3 * 2),
		"the sample keeps the ramped height", TOLERANCE
	)
	t.check(
		is_same(TerrainCollisionBuilder.downsample_exact(source, 3), source),
		"a stride that does not divide the grid keeps the source image"
	)
	t.check(
		is_same(TerrainCollisionBuilder.downsample_exact(source, 1), source),
		"stride 1 keeps the source image"
	)

func test_budget_turns_into_a_stride_and_stays_inside_the_maximum() -> void:
	var grid := make_ramp_image(Vector2i(17, 17), RAMP_HEIGHT)
	t.check_eq(
		TerrainCollisionBuilder.stride_for(grid, 0), 1, "a budget of 0 keeps exact geometry"
	)
	t.check_eq(
		TerrainCollisionBuilder.stride_for(null, 64), 1,
		"a missing heightmap falls back to exact geometry"
	)
	# A 17x17 grid has 16x16x2 = 512 triangles, so a budget of 512 needs no decimation at all.
	t.check_eq(
		TerrainCollisionBuilder.stride_for(grid, 512), 1,
		"a budget that already fits keeps the exact geometry"
	)
	t.check_eq(
		TerrainCollisionBuilder.stride_for(grid, 128), 2,
		"a budget of a quarter of the triangles uses stride 2"
	)
	# stride_for() reduces a step that does not divide the grid, so the coarse grid cannot drift.
	t.check_eq(
		TerrainCollisionBuilder.fit_stride(17, 17, 3), 2,
		"a stride that does not divide the grid is reduced until it does"
	)
	t.check_eq(
		TerrainCollisionBuilder.fit_stride(17, 17, 1), 1, "stride 1 stays exact"
	)
	t.check_eq(
		TerrainCollisionBuilder.fit_stride(17, 17, 99), TerrainCollisionBuilder.MAX_STRIDE,
		"the stride is capped to the maximum"
	)
	# Tighter and tighter budgets must never increase the triangle count.
	var previous := 0
	for budget in [4096, 1024, 256, 64, 16, 1]:
		var stride := TerrainCollisionBuilder.stride_for(grid, budget)
		var faces := TerrainCollisionBuilder.build_faces(grid, RAMP_SIZE, null, budget)
		if previous > 0:
			t.check(
				faces.size() <= previous,
				"a budget of %d keeps at most as many faces as the previous one (%d vs %d)" % [
					budget, faces.size(), previous
				]
			)
		previous = faces.size()
		t.check(stride <= TerrainCollisionBuilder.MAX_STRIDE, "stride %d stays capped" % stride)

func test_lod_scales_the_collision_budget_down() -> void:
	var grid := make_ramp_image(Vector2i(129, 129), RAMP_HEIGHT)
	# 128x128x2 = 32768 exact triangles; a budget of 8192 is stride 2 at LOD 0.
	var base_budget := 8192
	t.check_eq(
		TerrainCollisionBuilder.stride_for(grid, base_budget, 0), 2,
		"the budget is the only thing decimating at LOD 0"
	)
	t.check_eq(
		TerrainCollisionBuilder.stride_for(grid, base_budget, 1), 4,
		"a LOD step quarters the budget and therefore doubles the stride"
	)
	# A floor keeps collision alive however far away the chunk is.
	var far := TerrainCollisionBuilder.stride_for(grid, 1, 8)
	t.check(far <= TerrainCollisionBuilder.MAX_STRIDE, "even a tiny budget stays capped")
	t.check_eq(
		TerrainCollisionBuilder.stride_for(grid, 0, 6), 1,
		"the exact budget stays exact at every LOD"
	)

func test_build_collision_faces_decimates_and_keeps_the_heights() -> void:
	var heightmap := _ramp()
	var exact := TerrainCollisionBuilder.build_faces(heightmap, RAMP_SIZE, null, 0)
	t.check_eq(
		exact.size(), (RAMP_GRID.x - 1) * (RAMP_GRID.y - 1) * 6,
		"an exact budget turns every cell into two triangles"
	)
	t.check_eq(
		exact,
		TerrainCollisionBuilder.surface_arrays_to_faces(
			TerrainMeshGenerator.generate_surface_arrays(heightmap, RAMP_SIZE)
		),
		"the exact budget is the visual surface"
	)
	for budget in [RAMP_BUDGET_STRIDE_2, RAMP_BUDGET_STRIDE_4]:
		var stride := TerrainCollisionBuilder.stride_for(heightmap, budget)
		var faces := TerrainCollisionBuilder.build_faces(heightmap, RAMP_SIZE, null, budget)
		var cells: int = 8 / stride
		t.check(
			stride > 1,
			"a budget of %d decimates the grid (stride %d)" % [budget, stride]
		)
		t.check_eq(
			faces.size(), cells * cells * 6,
			"stride %d keeps %dx%d cells" % [stride, cells, cells]
		)
		t.check_eq(faces.size(), exact.size() / (stride * stride), "faces scale with the stride")
		var half := RAMP_SIZE.x * 0.5
		var step: float = stride
		var worst := 0.0
		for vertex in faces:
			var gx: float = (vertex.x + half) / step
			var gy: float = (vertex.z + half) / step
			worst = maxf(worst, absf(gx - roundf(gx)))
			worst = maxf(worst, absf(gy - roundf(gy)))
			worst = maxf(worst, absf(vertex.y - RAMP_HEIGHT_STEP * stride * (gx + gy)))
		t.check_almost_eq(
			worst, 0.0,
			"stride %d vertices sit on the sampled grid with the sampled heights" % stride,
			TOLERANCE
		)
		# The coarse grid has to span the same world extent as the visual one, otherwise the
		# collision surface would be scaled down around the chunk origin.
		_check_same_bounds(
			_bounds_of(faces),
			PackedFloat32Array([-half, 0.0, -half, half, RAMP_HEIGHT, half]),
			"stride %d collision keeps the full extent" % stride
		)

## A caller that already generated the surface arrays (the chunk mesh worker) can hand them over
## instead of making the builder generate the same geometry a second time.
func test_build_collision_faces_reuses_supplied_visual_arrays() -> void:
	var heightmap := _ramp()
	var visual := TerrainMeshGenerator.generate_surface_arrays(heightmap, RAMP_SIZE)
	t.check_eq(
		TerrainCollisionBuilder.build_faces(heightmap, RAMP_SIZE, null, 0, 0, visual),
		TerrainCollisionBuilder.surface_arrays_to_faces(visual),
		"the supplied arrays are used as they are"
	)
	t.check_eq(
		TerrainCollisionBuilder.build_faces(heightmap, RAMP_SIZE, null, 0),
		TerrainCollisionBuilder.surface_arrays_to_faces(visual),
		"without them the same geometry is generated"
	)

func test_build_collision_faces_keeps_carved_holes() -> void:
	var heightmap := make_ramp_image(Vector2i(33, 33), RAMP_HEIGHT * 4.0)
	var mask := make_flat_image(Vector2i(33, 33), 0.0)
	for y in range(12, 21):
		for x in range(12, 21):
			mask.set_pixel(x, y, Color(1.0, 0.0, 0.0, 1.0))
	t.check(TerrainCollisionBuilder.mask_has_holes(mask), "the test mask carves a hole")
	var solid := TerrainCollisionBuilder.build_faces(heightmap, TERRAIN_SIZE, null, COARSE_BUDGET)
	var holed := TerrainCollisionBuilder.build_faces(heightmap, TERRAIN_SIZE, mask, COARSE_BUDGET)
	t.check(
		holed.size() < solid.size(),
		"the carved hole removes collision faces (%d vs %d)" % [holed.size(), solid.size()]
	)
	t.check(holed.size() % 3 == 0, "the soup stays a list of triangles")
	var exact := TerrainCollisionBuilder.build_faces(heightmap, TERRAIN_SIZE, mask, 0)
	t.check(
		holed.size() < exact.size(),
		"the decimated hole mesh is smaller than the exact one (%d vs %d)" % [
			holed.size(), exact.size()
		]
	)

func test_mask_has_holes_follows_the_mesh_generators_threshold() -> void:
	t.check(
		not TerrainCollisionBuilder.mask_has_holes(null),
		"a missing mask has no holes"
	)
	t.check(
		not TerrainCollisionBuilder.mask_has_holes(make_flat_image(Vector2i(4, 4), 0.0)),
		"an allocated but empty mask has no holes"
	)
	var mask := make_flat_image(Vector2i(4, 4), 0.0)
	mask.set_pixel(2, 3, Color(TerrainMeshGenerator.HOLE_THRESHOLD, 0.0, 0.0, 1.0))
	t.check(
		TerrainCollisionBuilder.mask_has_holes(mask),
		"a pixel on the threshold counts as a hole, like in the mesh generator"
	)
	mask.set_pixel(2, 3, Color(0.0, 0.0, 0.0, 1.0))
	t.check(not TerrainCollisionBuilder.mask_has_holes(mask), "the hole can be cleared again")

## The per-chunk scan is what lets the composer answer "does this chunk have holes?" once, when
## the chunk mask slice is extracted, instead of rescanning the whole mask on every update.
func test_mask_has_holes_in_rect_only_looks_at_the_rect() -> void:
	var mask := make_flat_image(Vector2i(8, 8), 0.0)
	mask.set_pixel(6, 6, Color(1.0, 0.0, 0.0, 1.0))
	t.check(
		not TerrainCollisionBuilder.mask_has_holes_in_rect(mask, Rect2i(0, 0, 4, 4)),
		"a rect that does not cover the hole reports no holes"
	)
	t.check(
		TerrainCollisionBuilder.mask_has_holes_in_rect(mask, Rect2i(6, 6, 1, 1)),
		"the rect around the hole reports it"
	)
	t.check(
		TerrainCollisionBuilder.mask_has_holes_in_rect(mask, Rect2i(0, 0, 8, 8)),
		"the whole mask reports it"
	)
	t.check(
		not TerrainCollisionBuilder.mask_has_holes_in_rect(mask, Rect2i(20, 20, 4, 4)),
		"a rect outside the mask reports nothing"
	)
	t.check(
		not TerrainCollisionBuilder.mask_has_holes_in_rect(mask, Rect2i(0, 0, 0, 0)),
		"an empty rect reports nothing"
	)
	t.check(
		not TerrainCollisionBuilder.mask_has_holes_in_rect(null, Rect2i(0, 0, 4, 4)),
		"a missing mask reports nothing"
	)

func test_surface_arrays_to_faces_maps_indices_to_vertices() -> void:
	var vertices := PackedVector3Array([Vector3.ZERO, Vector3(1, 2, 3), Vector3(4, 5, 6)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([2, 0, 1])
	t.check_eq(
		TerrainCollisionBuilder.surface_arrays_to_faces(arrays),
		PackedVector3Array([Vector3(4, 5, 6), Vector3.ZERO, Vector3(1, 2, 3)]),
		"the soup follows the index order"
	)
	t.check(
		TerrainCollisionBuilder.surface_arrays_to_faces([]).is_empty(),
		"missing arrays produce an empty soup"
	)
