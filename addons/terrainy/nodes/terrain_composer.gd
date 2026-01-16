@tool
class_name TerrainComposer
extends Node3D

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")

## Main terrain composer that blends all TerrainFeatureNodes and generates final mesh

signal terrain_updated

@export var terrain_size: Vector2 = Vector2(100, 100):
	set(value):
		terrain_size = value
		_request_update()

@export var resolution: int = 128:
	set(value):
		resolution = clamp(value, 16, 512)
		_request_update()

@export var base_height: float = 0.0:
	set(value):
		base_height = value
		_request_update()

@export var auto_update: bool = true

@export_group("Performance")
@export var update_debounce_time: float = 0.3:
	set(value):
		update_debounce_time = max(0.0, value)

@export_group("Material")
@export var terrain_material: Material

@export_group("Collision")
@export var generate_collision: bool = true:
	set(value):
		generate_collision = value
		_update_collision()

var _mesh_instance: MeshInstance3D
var _static_body: StaticBody3D
var _collision_shape: CollisionShape3D
var _update_queued: bool = false
var _debounce_timer: float = 0.0
var _feature_nodes: Array[TerrainFeatureNode] = []
var _initialized: bool = false

func _enter_tree() -> void:
	if Engine.is_editor_hint() and not _initialized:
		# Initialize and generate mesh when first entering the tree
		call_deferred("_initialize_and_generate")

func _initialize_and_generate() -> void:
	if _initialized:
		return
	_initialized = true
	
	# Ensure mesh instance exists
	if not _mesh_instance:
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)
	
	# Generate initial mesh
	_scan_for_features()
	_update_terrain()

func _ready() -> void:
	if not _mesh_instance:
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)
	
	if not _static_body:
		_static_body = StaticBody3D.new()
		add_child(_static_body)
		_static_body.name = "CollisionBody"
	
	if not _collision_shape:
		_collision_shape = CollisionShape3D.new()
		_static_body.add_child(_collision_shape)
		_collision_shape.name = "CollisionShape"
	
	_scan_for_features()
	_connect_feature_signals()
	
	if Engine.is_editor_hint():
		if not child_entered_tree.is_connected(_on_child_changed):
			child_entered_tree.connect(_on_child_changed)
		if not child_exiting_tree.is_connected(_on_child_changed):
			child_exiting_tree.connect(_on_child_changed)
	
	set_process(false)
	_request_update()

func _scan_for_features() -> void:
	# Disconnect old signals before clearing
	for feature in _feature_nodes:
		if is_instance_valid(feature) and feature.parameters_changed.is_connected(_on_feature_changed):
			feature.parameters_changed.disconnect(_on_feature_changed)
	
	_feature_nodes.clear()
	_scan_node_recursive(self)

func _scan_node_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is TerrainFeatureNode and child != _mesh_instance and child != _static_body:
			_feature_nodes.append(child)
			# Recursively scan children of this feature node
			_scan_node_recursive(child)
		elif not (child is MeshInstance3D or child is StaticBody3D or child is CollisionShape3D):
			# Don't scan internal nodes, but do scan other containers
			_scan_node_recursive(child)

func _connect_feature_signals() -> void:
	for feature in _feature_nodes:
		if is_instance_valid(feature) and not feature.parameters_changed.is_connected(_on_feature_changed):
			feature.parameters_changed.connect(_on_feature_changed)

func _on_child_changed(node: Node) -> void:
	# Defer to avoid issues during node deletion
	call_deferred("_rescan_features")

func _rescan_features() -> void:
	_scan_for_features()
	_connect_feature_signals()
	_request_update()

func _on_feature_changed() -> void:
	_request_update()

func _request_update() -> void:
	if not auto_update:
		return
	
	if not _update_queued:
		_update_queued = true
		_debounce_timer = update_debounce_time
		set_process(true)

func _process(delta: float) -> void:
	if _update_queued:
		_debounce_timer -= delta
		if _debounce_timer <= 0.0:
			_update_queued = false
			_debounce_timer = 0.0
			set_process(false)
			_update_terrain()

## Manually trigger terrain regeneration
func rebuild_terrain() -> void:
	_update_queued = false
	_debounce_timer = 0.0
	set_process(false)
	_update_terrain()

func _update_terrain() -> void:
	var mesh = _generate_terrain_mesh()
	if _mesh_instance:
		_mesh_instance.mesh = mesh
		if terrain_material:
			_mesh_instance.material_override = terrain_material
	
	_update_collision()
	terrain_updated.emit()

func _update_collision() -> void:
	if not _collision_shape or not _mesh_instance:
		return
	
	if generate_collision and _mesh_instance.mesh:
		_static_body.visible = true
		var shape = _mesh_instance.mesh.create_trimesh_shape()
		_collision_shape.shape = shape
	else:
		_static_body.visible = false
		_collision_shape.shape = null

func _generate_terrain_mesh() -> ArrayMesh:
	var vertices: PackedVector3Array = []
	var normals: PackedVector3Array = []
	var uvs: PackedVector2Array = []
	var indices: PackedInt32Array = []
	
	var step = terrain_size / float(resolution)
	var half_size = terrain_size / 2.0
	
	# Generate vertices
	for z in range(resolution + 1):
		for x in range(resolution + 1):
			var local_x = (x * step.x) - half_size.x
			var local_z = (z * step.y) - half_size.y
			var world_pos = to_global(Vector3(local_x, 0, local_z))
			
			var height = _calculate_height_at(world_pos)
			
			vertices.append(Vector3(local_x, height, local_z))
			uvs.append(Vector2(x / float(resolution), z / float(resolution)))
	
	# Generate indices (counter-clockwise winding for correct normals)
	for z in range(resolution):
		for x in range(resolution):
			var i = z * (resolution + 1) + x
			
			# Two triangles per quad - reversed winding order
			indices.append(i)
			indices.append(i + 1)
			indices.append(i + resolution + 1)
			
			indices.append(i + 1)
			indices.append(i + resolution + 2)
			indices.append(i + resolution + 1)
	
	# Calculate normals
	normals.resize(vertices.size())
	for i in range(normals.size()):
		normals[i] = Vector3.UP
	
	for i in range(0, indices.size(), 3):
		var i0 = indices[i]
		var i1 = indices[i + 1]
		var i2 = indices[i + 2]
		
		var v0 = vertices[i0]
		var v1 = vertices[i1]
		var v2 = vertices[i2]
		
		var normal = (v1 - v0).cross(v2 - v0).normalized()
		normals[i0] += normal
		normals[i1] += normal
		normals[i2] += normal
	
	# Normalize all normals
	for i in range(normals.size()):
		normals[i] = normals[i].normalized()
	
	# Create mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var array_mesh = ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	return array_mesh

func _calculate_height_at(world_pos: Vector3) -> float:
	var final_height = base_height
	var total_weight = 0.0
	var weighted_heights: Array[Dictionary] = []
	
	# Collect all feature contributions
	for feature in _feature_nodes:
		if not feature.visible:
			continue
		
		var weight = feature.get_influence_weight(world_pos)
		if weight > 0.001:
			var height = feature.get_height_at(world_pos)
			weighted_heights.append({
				"height": height,
				"weight": weight * feature.strength,
				"mode": feature.blend_mode
			})
			total_weight += weight * feature.strength
	
	# Blend all features
	if weighted_heights.is_empty():
		return final_height
	
	# Sort by blend mode for proper layering
	# For now, simple blending
	for data in weighted_heights:
		match data.mode:
			0: # Add
				final_height += data.height * data.weight
			1: # Max
				final_height = max(final_height, data.height * data.weight)
			2: # Min
				final_height = min(final_height, data.height * data.weight)
			3: # Multiply
				final_height *= (1.0 + data.height * data.weight)
			4: # Average
				final_height += data.height * data.weight
	
	return final_height
