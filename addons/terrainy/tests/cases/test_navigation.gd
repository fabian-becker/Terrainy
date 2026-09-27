extends "res://addons/terrainy/tests/framework/test_case.gd"

## Tests for the navigation bake path of TerrainComposer.
##
## The composer used to have no navigation story at all, so every project that wanted a navmesh
## had to bake it in a tool script against the visual mesh: 500k triangles per chunk, rasterised
## into 0.25 unit cells. The bake now has its own hook on the composer, feeds the navigation
## server the decimated chunk surface (holes included) and lands the resulting mesh in an internal
## NavigationRegion3D that the server actually parses.
##
## The cases below pin the observable contract of the two halves: TerrainNavigationBuilder collects
## every chunk in terrain space (and decimates it), and TerrainComposer bakes that geometry into a
## fresh NavigationMesh - once per request, with the template settings copied over, and dropping
## the region again when the option is turned off.

const TerrainNavigationBuilder = preload("res://addons/terrainy/helpers/terrain_navigation_builder.gd")

const CHUNKS_PER_AXIS := 2
const CHUNK_SIZE := 32
const RESOLUTION := CHUNKS_PER_AXIS * CHUNK_SIZE
const TERRAIN_SIZE := Vector2(64.0, 64.0)
## Budget that forces a stride of 8 on a 33x33 chunk heightmap (2048 exact triangles).
const SMALL_BUDGET := 64
## The bake rasterises into cells and adds a border, so the polygon vertices are not exactly on
## the terrain extent.
const EXTENT_TOLERANCE := 1.5

var _plain: TerrainComposer = null
var _holed: TerrainComposer = null
var _baked: TerrainComposer = null
var _baked_meshes: Array[NavigationMesh] = []

func before_all() -> void:
	_plain = _make_composer(false, false, null)
	_holed = _make_composer(false, true, null)
	_baked = _make_composer(true, false, null)

func after_all() -> void:
	_baked_meshes.clear()
	for composer in [_plain, _holed, _baked]:
		if is_instance_valid(composer):
			composer.queue_free()
	_plain = null
	_holed = null
	_baked = null
	super.after_all()

func _make_composer(bake: bool, carve_hole: bool, template: NavigationMesh) -> TerrainComposer:
	var composer := TerrainComposer.new()
	composer.name = "NavigationTest"
	composer.auto_update = false
	composer.enable_lod = false
	composer.debug_logging = false
	composer.chunk_size = CHUNK_SIZE
	composer.resolution = RESOLUTION
	composer.terrain_size = TERRAIN_SIZE
	composer.use_multithreading = false
	composer.navigation_mesh_template = template
	# Set before _ready() so that the first rebuild already requests a bake.
	composer.generate_navigation_mesh = bake
	if carve_hole:
		var hole := HoleNode.new()
		hole.influence_size = Vector2(20.0, 20.0)
		composer.add_child(hole)
	composer.navigation_mesh_baked.connect(_on_baked)
	spawn(composer)
	settle(composer)
	return composer

func _on_baked(navigation_mesh: NavigationMesh) -> void:
	_baked_meshes.append(navigation_mesh)

func _chunks(composer: TerrainComposer) -> Array:
	return composer._chunk_manager.get_chunks().values()

func _source_geometry(composer: TerrainComposer, budget: int) -> NavigationMeshSourceGeometryData3D:
	var geometry := NavigationMeshSourceGeometryData3D.new()
	TerrainNavigationBuilder.append_chunks(geometry, _chunks(composer), budget)
	return geometry

## The navigation geometry is fed to a region that sits next to the chunk nodes, so it lives in
## composer space: the terrain is centred on the composer and spans exactly terrain_size.
func _check_extent(bounds: AABB, message: String) -> void:
	var half := TERRAIN_SIZE * 0.5
	t.check_almost_eq(bounds.position.x, -half.x, EXTENT_TOLERANCE, "%s: min x" % message)
	t.check_almost_eq(bounds.position.z, -half.y, EXTENT_TOLERANCE, "%s: min z" % message)
	t.check_almost_eq(bounds.end.x, half.x, EXTENT_TOLERANCE, "%s: max x" % message)
	t.check_almost_eq(bounds.end.z, half.y, EXTENT_TOLERANCE, "%s: max z" % message)

func test_the_builder_feeds_every_chunk_of_the_terrain() -> void:
	var chunks := _chunks(_plain)
	t.check_eq(chunks.size(), CHUNKS_PER_AXIS * CHUNKS_PER_AXIS, "the fixture has four chunks")
	var geometry := NavigationMeshSourceGeometryData3D.new()
	t.check_eq(
		TerrainNavigationBuilder.append_chunks(geometry, chunks, 0),
		chunks.size(),
		"every chunk contributes faces"
	)
	t.check(geometry.has_data(), "the geometry has faces")
	_check_extent(geometry.get_bounds(), "the exact geometry spans the terrain")

func test_the_builder_decimates_the_source_geometry() -> void:
	var exact := _source_geometry(_plain, 0).get_vertices().size()
	var coarse := _source_geometry(_plain, SMALL_BUDGET)
	t.check(
		coarse.get_vertices().size() < exact,
		"a small budget feeds fewer vertices (%d vs %d)" % [coarse.get_vertices().size(), exact]
	)
	t.check(coarse.get_vertices().size() > 0, "the decimated geometry still has faces")
	# Decimation keeps the outer ring, so the decimated source still covers the terrain.
	_check_extent(coarse.get_bounds(), "the decimated geometry spans the terrain")

func test_holes_leave_the_terrain_out_of_the_navigation_geometry() -> void:
	var plain := _source_geometry(_plain, 0).get_vertices().size()
	var holed := _source_geometry(_holed, 0)
	t.check(holed.has_data(), "the carved terrain still has faces")
	t.check(
		holed.get_vertices().size() < plain,
		"the carved surface feeds fewer vertices (%d vs %d)" % [holed.get_vertices().size(), plain]
	)
	_check_extent(holed.get_bounds(), "the carved geometry spans the terrain")

func test_chunks_are_placed_at_their_own_position() -> void:
	# 2x2 chunks on a 64 unit terrain centred on the composer: the four chunk origins are the
	# quarter points. An unapplied transform would pile all four up on the origin.
	var expected := [
		Vector3(-16.0, 0.0, -16.0),
		Vector3(16.0, 0.0, -16.0),
		Vector3(-16.0, 0.0, 16.0),
		Vector3(16.0, 0.0, 16.0),
	]
	var chunks := _chunks(_plain)
	t.check_eq(chunks.size(), expected.size(), "the fixture has four chunks")
	for chunk in chunks:
		var transform := TerrainNavigationBuilder.chunk_transform(chunk)
		t.check(
			expected.has(transform.origin),
			"chunk %s is placed at a quarter point of the terrain (%s)" % [
				chunk.position, transform.origin
			]
		)
		t.check_eq(
			transform.origin, chunk.root.position,
			"chunk %s keeps the position of its node" % chunk.position
		)

func test_the_composer_bakes_a_navigation_mesh() -> void:
	t.check(_baked.generate_navigation_mesh, "the fixture asks for a navigation mesh")
	var navigation_mesh := _baked.get_navigation_mesh()
	t.check(navigation_mesh != null, "the bake produced a navigation mesh")
	if navigation_mesh == null:
		return
	t.check(navigation_mesh.get_vertices().size() > 0, "the mesh has vertices")
	t.check(navigation_mesh.get_polygon_count() > 0, "the mesh has polygons")
	t.check(not _baked.is_baking_navigation_mesh(), "the bake is done")
	t.check(
		_baked_meshes.has(navigation_mesh), "the completed bake was announced"
	)

	var region := _baked._navigation_region
	t.check(region is NavigationRegion3D, "an internal navigation region was created")
	if region is NavigationRegion3D:
		t.check(region.get_parent() == _baked, "the region belongs to the composer")
		t.check(region.navigation_mesh == navigation_mesh, "the region carries the baked mesh")

	var bounds := AABB(navigation_mesh.get_vertices()[0], Vector3.ZERO)
	for vertex in navigation_mesh.get_vertices():
		bounds = bounds.expand(vertex)
	_check_extent(bounds, "the baked polygons cover the terrain")

func test_the_bake_copies_the_template_settings() -> void:
	var template := NavigationMesh.new()
	template.cell_size = 1.5
	template.agent_radius = 3.0
	var composer := _make_composer(true, false, template)
	var navigation_mesh := composer.get_navigation_mesh()
	t.check(navigation_mesh != null, "the templated fixture baked a mesh")
	if navigation_mesh == null:
		return
	t.check(navigation_mesh != template, "the bake does not write into the template")
	t.check_almost_eq(navigation_mesh.cell_size, 1.5, 0.0001, "cell size is copied")
	t.check_almost_eq(navigation_mesh.agent_radius, 3.0, 0.0001, "agent radius is copied")
	t.check_eq(
		template.get_polygon_count(), 0, "the template keeps the polygons it had (none)"
	)

func test_a_bake_is_queued_once_per_request() -> void:
	var composer := _make_composer(true, false, null)
	var seen: Array[NavigationMesh] = []
	composer.navigation_mesh_baked.connect(func(mesh: NavigationMesh) -> void: seen.append(mesh))
	var first := composer.get_navigation_mesh()
	composer.rebuild_navigation_mesh()
	composer.rebuild_navigation_mesh()
	t.check(composer.is_baking_navigation_mesh(), "the bake is queued, not run inline")
	composer._process(0.0)
	t.check(not composer.is_baking_navigation_mesh(), "one _process frame runs the queued bake")
	t.check_eq(seen.size(), 1, "the two requests coalesce into one bake")
	t.check(composer.get_navigation_mesh() != null, "the composer kept a baked mesh")
	t.check(composer.get_navigation_mesh() != first, "every bake hands the region a fresh mesh")

func test_turning_the_option_off_drops_the_region() -> void:
	var composer := _make_composer(true, false, null)
	t.check(composer.get_navigation_mesh() != null, "the fixture baked a mesh")
	composer.generate_navigation_mesh = false
	t.check(composer._navigation_region == null, "the region is dropped with the option")
	t.check(composer.get_navigation_mesh() == null, "and so is the baked mesh")
	composer.rebuild_navigation_mesh()
	t.check(not composer.is_baking_navigation_mesh(), "no bake is queued while the option is off")

	composer.generate_navigation_mesh = true
	t.check(composer.is_baking_navigation_mesh(), "turning the option back on queues a bake")
	composer.rebuild_navigation_mesh()
	t.check(settle(composer), "the re-bake finished")
	t.check(composer.get_navigation_mesh() != null, "a mesh is baked again")
	t.check(composer._navigation_region != null, "and the region is back")
