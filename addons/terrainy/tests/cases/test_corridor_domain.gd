extends "res://addons/terrainy/tests/framework/test_case.gd"

## Corridor domain: Path3D route x width x cross-section profile x elevation origin.

func _corridor(points: Array, width: float = 8.0) -> TerrainFieldNode:
	var f := TerrainFieldNode.new()
	f.domain_kind = TerrainTypes.DomainKind.CORRIDOR
	f.domain_width = width
	f.domain_falloff = null
	var path := Path3D.new()
	path.name = "Route"
	var curve := Curve3D.new()
	for p in points:
		curve.add_point(p)
	path.curve = curve
	f.add_child(path)
	return f

func test_corridor_follows_route_with_width() -> void:
	var f := _corridor([Vector3(-30, 0, 0), Vector3(30, 0, 0)], 8.0)
	f.profile_height = -3.0
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 0, 0), -3.0, "carved on the center line")
	t.check_almost_eq(h_at(gen, 10, 3), -3.0, "inside the half width")
	t.check_almost_eq(h_at(gen, 0, 6), 0.0, "outside the half width")

func test_cross_section_profile_runs_across_width() -> void:
	var f := _corridor([Vector3(0, 0, -30), Vector3(0, 0, 30)], 10.0)
	var p := Curve.new()
	p.add_point(Vector2(0, 1))
	p.add_point(Vector2(1, 0))
	f.profile = p  # trench walls: 1 at the edge, 0 at the center line
	f.profile_height = 4.0
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "center of the cross-section", 0.05)
	t.check(h_at(gen, 4, 0) > 2.0, "near the edge the profile is high")

func test_curve_elevation_origin_follows_route_height() -> void:
	var f := _corridor([Vector3(-30, 2, 0), Vector3(30, 8, 0)], 6.0)
	f.profile_height = 0.0
	f.elevation_origin = TerrainTypes.ElevationOrigin.CURVE
	f.blend_mode = TerrainTypes.BlendMode.REPLACE
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, -30, 0), 2.0, "road start height", 0.15)
	t.check_almost_eq(h_at(gen, 0, 0), 5.0, "road mid height", 0.15)
	t.check_almost_eq(h_at(gen, 29, 0), 7.9, "road end height", 0.2)

## The gizmo follows the route sample-by-sample; this is the anchor it uses.
func test_curve_anchor_tracks_route_elevation() -> void:
	var f := _corridor([Vector3(-30, 2, 0), Vector3(30, 8, 0)], 6.0)
	f.profile_height = 0.0
	f.elevation_origin = TerrainTypes.ElevationOrigin.CURVE
	f.blend_mode = TerrainTypes.BlendMode.REPLACE
	var gen := build(make_generator(), [f])
	t.check_almost_eq(f.elevation_anchor_world_y(0.0), 2.0, "anchor at the route start", 0.1)
	t.check_almost_eq(f.elevation_anchor_world_y(0.5), 5.0, "anchor at the route middle", 0.1)
	t.check_almost_eq(f.elevation_anchor_world_y(1.0), 8.0, "anchor at the route end", 0.1)
	# Additive blends sit on the composite datum, so base_height lifts the route anchor.
	f.blend_mode = TerrainTypes.BlendMode.ADD
	gen.base_height = 40.0
	gen.rebuild_now()
	t.check_almost_eq(f.elevation_anchor_world_y(0.5), 45.0,
		"additive curve anchor includes the datum", 0.1)

func test_editing_the_curve_rebuilds() -> void:
	var f := _corridor([Vector3(-30, 0, 0), Vector3(30, 0, 0)], 6.0)
	f.profile_height = 2.0
	var gen := build(make_generator(), [f])
	t.check_almost_eq(h_at(gen, 0, 10), 0.0, "before the edit")
	var path: Path3D = f.get_domain_path_node()
	path.curve.set_point_position(1, Vector3(30, 0, 20))
	path.curve.set_point_position(0, Vector3(-30, 0, 0))
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 10), 2.0, "after the edit the route moved", 0.01)

func test_road_equivalence_flat_bed_pinned_to_curve() -> void:
	# Road recipe: flat profile, Curve elevation, Replace: the bed equals the route height
	# regardless of the terrain under it.
	var hills := TerrainFieldNode.new()
	hills.domain_kind = TerrainTypes.DomainKind.GLOBAL
	hills.profile_height = 0.0
	var r := TerrainReliefSource.new()
	r.weight = 6.0
	hills.relief_layers = [r]
	var road := _corridor([Vector3(-30, 1, -5), Vector3(30, 1, 5)], 6.0)
	road.profile_height = 0.0
	road.elevation_origin = TerrainTypes.ElevationOrigin.CURVE
	road.blend_mode = TerrainTypes.BlendMode.REPLACE
	var gen := build(make_generator(), [hills, road])
	for x in [-20.0, -5.0, 10.0, 25.0]:
		t.check_almost_eq(h_at(gen, x, x / 6.0), 1.0, "road bed at x=%s" % x, 0.05)
