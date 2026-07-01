class_name ScatterManager
extends RefCounted

## Handles scatter node placement, overlap rejection, and container management

const ScatterNode = preload("res://addons/terrainy/nodes/scatter/scatter_node.gd")
const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")
const EvaluationContext = preload("res://addons/terrainy/nodes/evaluation_context.gd")
const MultiMeshScatter = preload("res://addons/terrainy/helpers/multimesh_scatter.gd")

var _terrain_composer: Node3D = null
var _final_heightmap: Image = null
var _terrain_bounds: Rect2 = Rect2()
var _base_height: float = 0.0
var _resolution: int = 128

# Pre-extracted heightmap data for fast sampling (avoids per-pixel get_pixel() overhead)
var _heightmap_data: PackedFloat32Array = PackedFloat32Array()
var _heightmap_w: int = 0
var _heightmap_h: int = 0

func _init(composer: Node3D) -> void:
	_terrain_composer = composer

func set_terrain_data(heightmap: Image, bounds: Rect2, base_height: float, resolution: int) -> void:
	_final_heightmap = heightmap
	_terrain_bounds = bounds
	_base_height = base_height
	_resolution = resolution
	if _final_heightmap:
		_heightmap_data = _final_heightmap.get_data().to_float32_array()
		_heightmap_w = _final_heightmap.get_width()
		_heightmap_h = _final_heightmap.get_height()
	else:
		_heightmap_data.clear()
		_heightmap_w = 0
		_heightmap_h = 0

func refresh_scatter(scatter_nodes: Array, feature_nodes: Array[TerrainFeatureNode]) -> void:
	for scatter in scatter_nodes:
		if not is_instance_valid(scatter):
			continue
		if not scatter.visible or not scatter.is_inside_tree():
			_clear_scatter_instances(scatter)
			continue
		if scatter.scene == null or scatter.density <= 0.0:
			_clear_scatter_instances(scatter)
			continue
		_scatter_single_node(scatter, feature_nodes)

func clear_scatter(scatter_nodes: Array) -> void:
	for scatter in scatter_nodes:
		if is_instance_valid(scatter):
			_clear_scatter_instances(scatter)

func _scatter_single_node(scatter: ScatterNode, feature_nodes: Array[TerrainFeatureNode]) -> void:
	var scope = _resolve_scatter_scope(scatter)
	if scope.is_empty():
		_clear_scatter_instances(scatter)
		return

	var placements := _generate_scatter_placements(scatter, scope, feature_nodes)
	if placements.is_empty():
		_clear_scatter_instances(scatter)
		return

	var container = _get_or_create_scatter_container(scatter)
	for child in container.get_children():
		child.queue_free()

	if scatter.render_mode == 1:  # MultiMesh
		_build_scatter_multimesh(scatter, container, placements)
	else:
		_build_scatter_instances(scatter, container, placements)

func _generate_scatter_placements(
	scatter: ScatterNode,
	scope: Dictionary,
	feature_nodes: Array[TerrainFeatureNode]
) -> Array[Dictionary]:
	var scope_rect: Rect2 = scope["bounds"]
	if scope_rect.size.x <= 0.0 or scope_rect.size.y <= 0.0:
		return []

	var scope_context: EvaluationContext = scope.get("context", null)
	var scope_feature: TerrainFeatureNode = scope.get("parent_feature", null)
	var scope_area = scope_rect.size.x * scope_rect.size.y
	var computed_count = int(round(scope_area * scatter.density))
	computed_count = max(computed_count, scatter.min_instances)
	if scatter.max_instances > 0:
		computed_count = min(computed_count, scatter.max_instances)
	if computed_count <= 0:
		return []

	var rng = RandomNumberGenerator.new()
	var stable_key = "%s|%d" % [str(_terrain_composer.get_path_to(scatter)), scatter.seed]
	rng.seed = stable_key.hash()

	var placements: Array[Dictionary] = []

	# Spatial hash for faster overlap checking
	var spatial_hash: Dictionary = {}
	var cell_size: float = 1.0
	if not scatter.allow_overlap:
		var overlap_extents = scatter.get_overlap_half_extents(Vector3.ONE)
		cell_size = max(overlap_extents.x, overlap_extents.z) * 4.0
		cell_size = max(cell_size, 0.1)

	var max_attempts = max(computed_count * 12, 64)
	var placed = 0

	for attempt in range(max_attempts):
		if placed >= computed_count:
			break

		var world_x = rng.randf_range(scope_rect.position.x, scope_rect.position.x + scope_rect.size.x)
		var world_z = rng.randf_range(scope_rect.position.y, scope_rect.position.y + scope_rect.size.y)
		var world_pos = Vector3(world_x, 0.0, world_z)

		if scope_context != null and scope_feature != null and scope_feature.get_influence_weight_safe(world_pos, scope_context) <= 0.0:
			continue
		if not _terrain_bounds.has_point(Vector2(world_x, world_z)):
			continue

		var sampled_height = _sample_height_at(world_x, world_z)
		var sampled_normal = _sample_normal_at(world_x, world_z)
		world_pos.y = sampled_height

		var random_scale = scatter.get_random_scale(rng)
		var candidate_half_extents = scatter.get_overlap_half_extents(random_scale)
		var candidate_aabb = AABB(world_pos - candidate_half_extents, candidate_half_extents * 2.0)

		if not scatter.allow_overlap:
			if _check_overlap_spatial(spatial_hash, candidate_aabb, cell_size):
				continue

		var basis = Basis.IDENTITY
		if scatter.align_to_normal:
			basis = Basis(Quaternion(Vector3.UP, sampled_normal))

		var random_rotation = scatter.get_rotation_radians(rng)
		basis = basis.rotated(Vector3.RIGHT, random_rotation.x)
		basis = basis.rotated(Vector3.UP, random_rotation.y)
		basis = basis.rotated(Vector3.BACK, random_rotation.z)
		basis = basis.scaled(random_scale)

		var transform = Transform3D(basis, world_pos)

		placements.append({
			"transform": transform,
			"scale": random_scale,
			"position": world_pos,
			"normal": sampled_normal
		})
		if not scatter.allow_overlap:
			_insert_aabb_spatial(spatial_hash, candidate_aabb, cell_size)
		placed += 1

	return placements

func _build_scatter_instances(scatter: ScatterNode, container: Node3D, placements: Array[Dictionary]) -> void:
	for placement in placements:
		var instance = scatter.scene.instantiate()
		if not (instance is Node3D):
			instance.queue_free()
			continue
		var instance_3d = instance as Node3D
		container.add_child(instance_3d, false, Node.INTERNAL_MODE_BACK)
		# Placement transforms are in world space; use global_transform so Godot
		# converts them to the correct local transform relative to the container.
		instance_3d.global_transform = placement["transform"]

func _build_scatter_multimesh(scatter: ScatterNode, container: Node3D, placements: Array[Dictionary]) -> void:
	# Placement transforms are in world space. MultiMesh instance_transforms are
	# relative to the MultiMeshInstance3D node, so convert to container-local space.
	var container_global_inv := container.global_transform.affine_inverse()
	var transforms: Array[Transform3D] = []
	transforms.resize(placements.size())
	for i in placements.size():
		transforms[i] = container_global_inv * placements[i]["transform"]

	var mm_instance = MultiMeshScatter.build_multimesh(scatter, transforms)
	if mm_instance:
		container.add_child(mm_instance, false, Node.INTERNAL_MODE_BACK)


func _check_overlap_spatial(spatial_hash: Dictionary, aabb: AABB, cell_size: float) -> bool:
	var min_cell = Vector2i(int(aabb.position.x / cell_size), int(aabb.position.z / cell_size))
	var max_cell = Vector2i(int((aabb.position.x + aabb.size.x) / cell_size), int((aabb.position.z + aabb.size.z) / cell_size))

	for x in range(min_cell.x, max_cell.x + 1):
		for z in range(min_cell.y, max_cell.y + 1):
			var key = Vector2i(x, z)
			if spatial_hash.has(key):
				for existing in spatial_hash[key]:
					if existing.intersects(aabb):
						return true
	return false

func _insert_aabb_spatial(spatial_hash: Dictionary, aabb: AABB, cell_size: float) -> void:
	var min_cell = Vector2i(int(aabb.position.x / cell_size), int(aabb.position.z / cell_size))
	var max_cell = Vector2i(int((aabb.position.x + aabb.size.x) / cell_size), int((aabb.position.z + aabb.size.z) / cell_size))

	for x in range(min_cell.x, max_cell.x + 1):
		for z in range(min_cell.y, max_cell.y + 1):
			var key = Vector2i(x, z)
			if not spatial_hash.has(key):
				spatial_hash[key] = []
			spatial_hash[key].append(aabb)

func _resolve_scatter_scope(scatter: ScatterNode) -> Dictionary:
	var parent_feature = _find_parent_feature(scatter)
	if parent_feature != null:
		var feature_bounds = _get_feature_world_bounds(parent_feature)
		var intersection = feature_bounds.intersection(_terrain_bounds)
		if intersection.size.x <= 0.0 or intersection.size.y <= 0.0:
			return {}
		return {
			"bounds": intersection,
			"context": parent_feature.prepare_evaluation_context(),
			"parent_feature": parent_feature
		}

	if scatter.get_parent() == _terrain_composer:
		return {
			"bounds": _terrain_bounds,
			"context": null
		}

	var fallback = _terrain_bounds
	if fallback.size.x <= 0.0 or fallback.size.y <= 0.0:
		return {}
	return {
		"bounds": fallback,
		"context": null
	}

func _find_parent_feature(scatter: ScatterNode) -> TerrainFeatureNode:
	var node: Node = scatter.get_parent()
	while node != null and node != _terrain_composer:
		if node is TerrainFeatureNode:
			return node as TerrainFeatureNode
		node = node.get_parent()
	return null

func _sample_height_at(world_x: float, world_z: float) -> float:
	if _heightmap_data.is_empty():
		return _base_height

	var u = (world_x - _terrain_bounds.position.x) / max(_terrain_bounds.size.x, 0.0001)
	var v = (world_z - _terrain_bounds.position.y) / max(_terrain_bounds.size.y, 0.0001)
	u = clampf(u, 0.0, 1.0)
	v = clampf(v, 0.0, 1.0)

	# Bilinear interpolation for smooth height sampling (matches get_height_at_world_position)
	var px = u * float(_heightmap_w - 1)
	var py = v * float(_heightmap_h - 1)
	var x0 = int(floor(px))
	var y0 = int(floor(py))
	var x1 = mini(x0 + 1, _heightmap_w - 1)
	var y1 = mini(y0 + 1, _heightmap_h - 1)
	var dx = px - float(x0)
	var dy = py - float(y0)

	var h00 = _heightmap_data[y0 * _heightmap_w + x0]
	var h10 = _heightmap_data[y0 * _heightmap_w + x1]
	var h01 = _heightmap_data[y1 * _heightmap_w + x0]
	var h11 = _heightmap_data[y1 * _heightmap_w + x1]
	var h0 = lerp(h00, h10, dx)
	var h1 = lerp(h01, h11, dx)
	var height = lerp(h0, h1, dy)

	if _terrain_composer:
		return _terrain_composer.global_position.y + height
	return height

func _sample_normal_at(world_x: float, world_z: float) -> Vector3:
	var sample_step_x = max(_terrain_bounds.size.x / max(float(_resolution), 1.0), 0.5)
	var sample_step_z = max(_terrain_bounds.size.y / max(float(_resolution), 1.0), 0.5)

	var h_l = _sample_height_at(world_x - sample_step_x, world_z)
	var h_r = _sample_height_at(world_x + sample_step_x, world_z)
	var h_d = _sample_height_at(world_x, world_z - sample_step_z)
	var h_u = _sample_height_at(world_x, world_z + sample_step_z)

	var normal = Vector3(h_l - h_r, 2.0, h_d - h_u).normalized()
	if normal.is_equal_approx(Vector3.ZERO):
		return Vector3.UP
	return normal

func _get_or_create_scatter_container(scatter: ScatterNode) -> Node3D:
	var existing = scatter.get_node_or_null("ScatterInstances")
	if existing and existing is Node3D:
		return existing as Node3D

	var container = Node3D.new()
	container.name = "ScatterInstances"
	scatter.add_child(container, false, Node.INTERNAL_MODE_BACK)
	return container

func _clear_scatter_instances(scatter: ScatterNode) -> void:
	var container = scatter.get_node_or_null("ScatterInstances")
	if container and container is Node3D:
		for child in container.get_children():
			child.queue_free()

func _get_feature_world_bounds(feature: TerrainFeatureNode) -> Rect2:
	var center = Vector2(feature.global_position.x, feature.global_position.z)
	var half_size: Vector2

	match feature.influence_shape:
		TerrainFeatureNode.InfluenceShape.CIRCLE:
			var radius = max(feature.influence_size.x, feature.influence_size.y) * 0.5
			half_size = Vector2(radius, radius)
		TerrainFeatureNode.InfluenceShape.ELLIPSE:
			half_size = feature.influence_size * 0.5
		_:
			half_size = feature.influence_size * 0.5

	var corners = [
		Vector3(-half_size.x, 0, -half_size.y),
		Vector3(half_size.x, 0, -half_size.y),
		Vector3(half_size.x, 0, half_size.y),
		Vector3(-half_size.x, 0, half_size.y)
	]

	var min_x = INF
	var min_z = INF
	var max_x = -INF
	var max_z = -INF

	for corner in corners:
		var world_corner = feature.global_transform * corner
		min_x = min(min_x, world_corner.x)
		min_z = min(min_z, world_corner.z)
		max_x = max(max_x, world_corner.x)
		max_z = max(max_z, world_corner.z)

	return Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))
