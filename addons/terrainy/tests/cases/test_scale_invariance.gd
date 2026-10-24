extends "res://addons/terrainy/tests/framework/test_case.gd"

## Scale invariance: growing terrain_size must cost more chunks, not more meters per cell.
##
## Every quality number the pipeline consumes - mesh triangle size, LOD switch distance, navigation
## rasterization - is derived from the world-space cell size, so these tests pin the derivation
## rather than the individual stages.

const TerrainGrid = preload("res://addons/terrainy/gen/eval/terrain_grid.gd")
const NavigationBuilder = preload("res://addons/terrainy/gen/build/navigation_builder.gd")

class FakeChunk:
	var key := Vector2i.ZERO
	var sample_rect := Rect2i()
	var world_bounds := Rect2()

func test_defaults_are_one_meter_cells() -> void:
	var gen := TerrainGenerator.new()
	t.check_almost_eq(gen.terrain_size, 256.0, "default size")
	t.check_eq(gen.terrain_resolution, 256, "default resolution")
	t.check_almost_eq(gen.cell_size, 1.0, "default cell size")
	t.check(gen.preserve_cell_size, "resizing keeps the cell size by default")
	var grid = gen.get_grid()
	t.check_almost_eq(grid.cell, 1.0, "1 m cells")
	gen.free()

func test_resizing_keeps_the_cell_size() -> void:
	var gen := TerrainGenerator.new()
	gen.terrain_size = 4096.0
	t.check_eq(gen.terrain_resolution, 4096, "resolution follows the world size")
	t.check_almost_eq(gen.cell_size, 1.0, "cells stay 1 m")
	t.check_almost_eq(gen.get_grid().cell, 1.0, "grid cells stay 1 m")
	gen.terrain_size = 1024.0
	t.check_eq(gen.terrain_resolution, 1024, "resolution follows a shrink too")
	t.check_almost_eq(gen.get_grid().cell, 1.0, "cells still 1 m")
	gen.free()

func test_cell_size_derives_the_resolution() -> void:
	var gen := TerrainGenerator.new()
	gen.terrain_size = 4096.0
	gen.cell_size = 2.0
	t.check_eq(gen.terrain_resolution, 2048, "2 m cells over 4 km")
	t.check_almost_eq(gen.get_grid().cell, 2.0, "grid agrees")
	gen.cell_size = 0.5
	t.check_eq(gen.terrain_resolution, 4096, "clamped at MAX_RESOLUTION")
	t.check_almost_eq(gen.cell_size, 1.0, "cell size snaps to what the clamped grid can represent")
	gen.free()

func test_manual_mode_keeps_the_cell_count() -> void:
	var gen := TerrainGenerator.new()
	gen.preserve_cell_size = false
	gen.terrain_size = 4096.0
	t.check_eq(gen.terrain_resolution, 256, "fixed cell count kept")
	t.check_almost_eq(gen.get_grid().cell, 16.0, "the 0.x coarsening, now opt-in")
	t.check_almost_eq(gen.cell_size, 16.0, "cell size reports the truth")
	gen.free()

func test_resizing_only_adds_chunks() -> void:
	var gen := build(make_generator(64, 64.0), [make_field(5.0, Vector2(64, 64))])
	var before: Vector2 = gen.get_chunk_manager().chunks.values()[0].world_bounds.size
	gen.preserve_cell_size = true
	gen.terrain_size = 128.0
	gen.rebuild_now()
	t.check_almost_eq(gen.cell_size, 1.0, "cells stay 1 m")
	t.check_eq(gen.get_chunk_manager().chunks.size(), 16, "4x4 chunks")
	for chunk in gen.get_chunk_manager().chunks.values():
		t.check_almost_eq(chunk.world_bounds.size.x, before.x, "chunk keeps its world size")
		t.check_almost_eq(chunk.world_bounds.size.y, before.y, "chunk keeps its world size")

func test_resizing_reports_a_single_change() -> void:
	# The size setter derives the resolution internally; signals must not fire once per derived
	# property (the editor keys its paint-resample prompt off them).
	var gen := build(make_generator(64, 64.0), [make_field(5.0, Vector2(64, 64))])
	var resized: Array = []
	var rebuilt: Array = []
	gen.terrain_resized.connect(func(): resized.append(1))
	gen.terrain_region_updated.connect(func(_aabb): rebuilt.append(1))
	gen.preserve_cell_size = true
	gen.terrain_size = 128.0
	t.check_eq(resized.size(), 1, "one terrain_resized per size change")
	t.check_eq(gen.get_grid().samples, 129, "grid rebuilt for the new resolution")

func test_resizing_keeps_the_world_shape() -> void:
	var gen := build(make_generator(64, 64.0), [make_field(10.0, Vector2(32, 32))])
	var center: float = h_at(gen, 0, 0)
	var edge: float = h_at(gen, 15, 15)
	gen.preserve_cell_size = true
	gen.terrain_size = 128.0
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), center, "peak stays at the world center", 0.25)
	t.check_almost_eq(h_at(gen, 15, 15), edge, "feature keeps its world extent", 0.25)
	t.check_almost_eq(h_at(gen, 50, 0), 0.0, "new area stays empty", 0.01)

func test_navigation_rasterization_fits_the_chunk() -> void:
	var template := NavigationMesh.new()
	t.check_almost_eq(NavigationBuilder.scaled_cell_size(template, 128.0), template.cell_size,
		"a 128 m chunk keeps the template cell size")
	var coarse := NavigationBuilder.scaled_cell_size(template, 1024.0)
	t.check(coarse > 1.0, "a 1 km chunk coarsens the cells (%.3f m)" % coarse)
	t.check_almost_eq(NavigationBuilder.scaled_cell_size(template, 2048.0) / coarse, 2.0,
		"the cell size scales linearly with the chunk", 0.01)

func test_navigation_job_stays_within_the_voxel_budget() -> void:
	var grid = TerrainGrid.new(256, 4096.0, Vector2.ZERO)
	var chunk := FakeChunk.new()
	chunk.sample_rect = Rect2i(0, 0, 129, 129)
	chunk.world_bounds = grid.world_of_rect(chunk.sample_rect)
	var map = HMap.new(grid.full_rect(), 10.0)
	var job: Dictionary = NavigationBuilder.make_job(chunk, grid, map, null, null, 0)
	t.check(not job.is_empty(), "job built")
	if job.is_empty():
		return
	var mesh: NavigationMesh = job["mesh"]
	var aabb: AABB = mesh.filter_baking_aabb
	var voxels := int(ceil(aabb.size.x / mesh.cell_size)) * int(ceil(aabb.size.z / mesh.cell_size))
	t.check(voxels <= NavigationBuilder.NAV_MAX_VOXELS,
		"bake stays inside the budget (%d voxels of %d)" % [voxels, NavigationBuilder.NAV_MAX_VOXELS])
	t.check(voxels < 25_000_000, "far below Godot's crash-prevention abort")
	t.check_almost_eq(fmod(mesh.border_size, mesh.cell_size), 0.0, "border is whole cells", 0.0001)

## The headless root window is 64x64, which would make the derived LOD distances depend on the
## test host. Size it like a real window (restored in after_all) and install a current camera.
var _root_size_before: Vector2i = Vector2i.ZERO

func after_all() -> void:
	if _root_size_before != Vector2i.ZERO:
		tree.root.size = _root_size_before
		_root_size_before = Vector2i.ZERO
	super.after_all()

func _root_camera(viewport_size: Vector2i = Vector2i(1920, 1080)) -> Camera3D:
	if _root_size_before == Vector2i.ZERO:
		_root_size_before = tree.root.size
	tree.root.size = viewport_size
	var camera := Camera3D.new()
	camera.fov = 70.0
	spawn(camera)
	camera.current = true
	return camera

func test_lod_distances_follow_the_cell_size() -> void:
	var gen := TerrainGenerator.new()
	var camera := _root_camera()
	var fine: PackedFloat32Array = gen._applier.lod_distances_for(camera)
	gen.cell_size = 4.0
	var coarse: PackedFloat32Array = gen._applier.lod_distances_for(camera)
	t.check_eq(fine.size(), 3, "one distance per derived level")
	t.check_almost_eq(coarse[0] / fine[0], 4.0, "distances scale with the cell size", 0.01)
	t.check_almost_eq(coarse[1] / coarse[0], 2.0, "each level doubles the distance", 0.01)
	gen.free()

func test_lod_auto_overrides_the_fixed_distances() -> void:
	var gen := build(make_generator(64, 64.0), [make_field(5.0, Vector2(64, 64))])
	gen.enable_lod = true
	var camera := _root_camera()
	camera.global_position = Vector3(0, 200, 200)
	gen.lod_distances = PackedFloat32Array([100.0, 200.0, 300.0])
	gen.lod_auto = false
	gen._applier.update_lod()
	var fixed_lod: int = gen.get_chunk_manager().chunks.values()[0].lod_level
	gen.lod_auto = true
	gen._applier._lod_camera = Vector3.INF
	var auto_distances: PackedFloat32Array = gen._applier.lod_distances_for(camera)
	t.check(auto_distances[0] > 200.0,
		"1 m cells stay LOD0 well past the old fixed threshold (%.0f m)" % auto_distances[0])
	gen._applier.update_lod()
	var auto_lod: int = gen.get_chunk_manager().chunks.values()[0].lod_level
	t.check(auto_lod < fixed_lod, "auto keeps detail where the fixed distances already coarsened (%d < %d)" % [
		auto_lod, fixed_lod])
