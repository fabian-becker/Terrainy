extends "res://addons/terrainy/tests/framework/test_case.gd"

## Tests for ScatterManager: signature based refresh, instance replacement (regression for
## instances stacking up because internal children were skipped), inactive clearing and the
## MultiMesh path.

const BOUNDS := Rect2(-64.0, -64.0, 128.0, 128.0)
const HEIGHTMAP_SIZE := Vector2i(16, 16)
const TERRAIN_HEIGHT := 10.0

var _composer: Node3D = null
var _manager = null
var _scene: PackedScene = null

func before_all() -> void:
	_composer = Node3D.new()
	_composer.name = "Terrain"
	spawn(_composer)
	_manager = ScatterManager.new(_composer)
	_scene = _make_mesh_scene()
	_manager.set_terrain_data(make_flat_image(HEIGHTMAP_SIZE, TERRAIN_HEIGHT), BOUNDS, 0.0, 16, true)

func _make_mesh_scene() -> PackedScene:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Instance"
	mesh_instance.mesh = BoxMesh.new()
	var packed := PackedScene.new()
	var error := packed.pack(mesh_instance)
	mesh_instance.free()  # pack() keeps no reference to the template node
	t.check_eq(error, OK, "test fixture scene packs successfully")
	return packed

func _make_scatter(node_name: String, density: float = 0.005) -> ScatterNode:
	var scatter := ScatterNode.new()
	scatter.name = node_name
	scatter.scene = _scene
	scatter.density = density
	scatter.seed = 7
	scatter.allow_overlap = true
	scatter.align_to_normal = false
	scatter.min_instances = 0
	scatter.max_instances = 2500
	_composer.add_child(scatter)
	return scatter

## Instances are added as internal children, so only get_children(true) sees them.
## Nodes queued for deletion are ignored: the manager uses queue_free().
func _live_instances(scatter: ScatterNode) -> Array:
	var container = scatter.get_node_or_null("ScatterInstances")
	var result: Array = []
	if container == null:
		return result
	for child in container.get_children(true):
		if not child.is_queued_for_deletion():
			result.append(child)
	return result

func _instance_ids(scatter: ScatterNode) -> Array:
	var ids: Array = []
	for instance in _live_instances(scatter):
		ids.append(instance.get_instance_id())
	return ids

func _expected_count(density: float) -> int:
	return int(round(BOUNDS.size.x * BOUNDS.size.y * density))

func test_refresh_places_instances_and_is_idempotent() -> void:
	var scatter := _make_scatter("Scatter_A")
	_manager.refresh_scatter([scatter])
	var first_ids := _instance_ids(scatter)
	t.check_eq(
		first_ids.size(), _expected_count(scatter.density),
		"all requested instances are placed"
	)

	_manager.refresh_scatter([scatter])
	t.check_eq(_instance_ids(scatter), first_ids, "an unchanged scatter keeps its instances")

func test_changed_settings_replace_instances_instead_of_stacking() -> void:
	var scatter := _make_scatter("Scatter_B")
	_manager.refresh_scatter([scatter])
	var first_ids := _instance_ids(scatter)

	scatter.density = 0.0025
	_manager.refresh_scatter([scatter])
	var second_ids := _instance_ids(scatter)
	t.check_eq(
		second_ids.size(), _expected_count(scatter.density),
		"the new instance count replaces the old one"
	)
	t.check_not_eq(second_ids, first_ids, "placements are regenerated for the new density")

func test_invalidate_only_rebuilds_the_requested_scatter() -> void:
	var first := _make_scatter("Scatter_C")
	var second := _make_scatter("Scatter_D")
	_manager.refresh_scatter([first, second])
	var first_ids := _instance_ids(first)
	var second_ids := _instance_ids(second)
	t.check(first_ids.size() > 0 and second_ids.size() > 0, "both scatters placed instances")

	_manager.invalidate_scatter(first)
	_manager.refresh_scatter([first, second])
	t.check_not_eq(_instance_ids(first), first_ids, "the invalidated scatter is rebuilt")
	t.check_eq(_instance_ids(second), second_ids, "the untouched scatter keeps its instances")

func test_new_terrain_content_rebuilds_placements() -> void:
	var scatter := _make_scatter("Scatter_E")
	_manager.refresh_scatter([scatter])
	var first_ids := _instance_ids(scatter)

	_manager.set_terrain_data(make_flat_image(HEIGHTMAP_SIZE, TERRAIN_HEIGHT), BOUNDS, 0.0, 16, true)
	_manager.refresh_scatter([scatter])
	t.check_not_eq(
		_instance_ids(scatter), first_ids,
		"changed heightmap content regenerates the placements"
	)

func test_inactive_scatters_are_cleared() -> void:
	var scatter := _make_scatter("Scatter_F")
	_manager.refresh_scatter([scatter])
	t.check(_live_instances(scatter).size() > 0, "instances exist before deactivating")

	scatter.visible = false
	_manager.refresh_scatter([scatter])
	t.check_eq(_live_instances(scatter).size(), 0, "hiding a scatter clears its instances")

	scatter.visible = true
	_manager.refresh_scatter([scatter])
	t.check(_live_instances(scatter).size() > 0, "showing a scatter places instances again")

	scatter.density = 0.0
	_manager.refresh_scatter([scatter])
	t.check_eq(_live_instances(scatter).size(), 0, "a zero density scatter has no instances")

func test_instances_follow_the_terrain_height() -> void:
	var scatter := _make_scatter("Scatter_G", 0.01)
	_manager.refresh_scatter([scatter])
	var instances := _live_instances(scatter)
	t.check(instances.size() > 0, "instances were placed")
	for instance in instances:
		t.check_almost_eq(
			instance.global_position.y, TERRAIN_HEIGHT,
			"instances sit on the sampled terrain height", 0.01
		)

func test_multimesh_mode_builds_one_multimesh() -> void:
	var scatter := _make_scatter("Scatter_H")
	scatter.render_mode = 1
	_manager.refresh_scatter([scatter])
	var instances := _live_instances(scatter)
	t.check_eq(instances.size(), 1, "MultiMesh mode creates a single node")
	if instances.size() == 1:
		t.check(instances[0] is MultiMeshInstance3D, "the node is a MultiMeshInstance3D")
		t.check_eq(
			instances[0].multimesh.instance_count, _expected_count(scatter.density),
			"the multimesh holds every placement"
		)

func test_clear_scatter_removes_instances() -> void:
	var scatter := _make_scatter("Scatter_I")
	_manager.refresh_scatter([scatter])
	t.check(_live_instances(scatter).size() > 0, "instances exist before clearing")
	_manager.clear_scatter([scatter])
	t.check_eq(_live_instances(scatter).size(), 0, "clear_scatter frees the instances")
