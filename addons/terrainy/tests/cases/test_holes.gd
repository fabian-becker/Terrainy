extends "res://addons/terrainy/tests/framework/test_case.gd"

## TerrainHoleNode: mesh + collision cutting, 3D tilt, opt-in navigation punching.

func test_hole_cuts_mesh_and_query() -> void:
	var hole := TerrainHoleNode.new()
	hole.size = Vector3(8, 100, 8)
	var gen := build(make_generator(), [hole])
	t.check(TerrainyAPI.get_hole_at(gen, Vector3(0, 0, 0)), "hole at center")
	t.check(not TerrainyAPI.get_hole_at(gen, Vector3(10, 0, 10)), "solid elsewhere")
	var chunk = gen.get_chunk_manager().chunk_at_world(Vector2(1, 1))
	t.check(chunk.has_holes, "chunk knows it is holed")
	var full := 2 * 32 * 32 * 3
	var indices: PackedInt32Array = chunk.mesh_instance.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	t.check(indices.size() < full, "triangles removed from the mesh")

func test_hole_above_the_surface_does_not_cut() -> void:
	var hole := TerrainHoleNode.new()
	hole.hole_shape = TerrainHoleNode.HoleShape.SPHERE
	hole.size = Vector3(8, 8, 8)
	hole.position = Vector3(0, 20, 0)
	var gen := build(make_generator(), [hole])
	t.check(not TerrainyAPI.get_hole_at(gen, Vector3.ZERO), "a 3D hole floating above the terrain cuts nothing")
	hole.position = Vector3(0, 0, 0)
	gen.rebuild_now()
	t.check(TerrainyAPI.get_hole_at(gen, Vector3.ZERO), "intersecting the surface it cuts")

func test_painted_masks_never_make_holes() -> void:
	var gen := make_generator()
	var m := TerrainPaintLayer.new()
	m.kind = TerrainPaintLayer.PaintKind.MASK
	gen.add_child(m)
	build(gen)
	gen.paint_stamps(m, [stamp(BrushStamp.StrokeOp.MASK, Vector3.ZERO, 8.0, 1.0)])
	gen.rebuild_now()
	t.check(gen.get_hole_map() == null, "no hole map from paint")

func test_punches_navigation_flag_filters_the_nav_hole_mask() -> void:
	var hole := TerrainHoleNode.new()
	hole.size = Vector3(8, 100, 8)
	var gen := build(make_generator(), [hole])
	t.check(gen._nav_holes == null, "navigation unaffected by default")
	hole.punches_navigation = true
	gen.rebuild_now()
	t.check(gen._nav_holes != null, "opt-in: hole mask feeds navigation")
