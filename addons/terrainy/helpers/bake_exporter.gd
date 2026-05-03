class_name BakeExporter
extends RefCounted

## Exports terrain chunks and features to a PackedScene

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")

func export_terrain(
	chunks: Dictionary,
	feature_nodes: Array[TerrainFeatureNode],
	scatter_nodes: Array,
	collision_layer: int,
	collision_mask: int,
	generate_collision: bool,
	terrain_material: Material
) -> PackedScene:
	var root_node := Node3D.new()
	root_node.name = "BakedTerrain"

	# Export chunks
	for chunk in chunks.values():
		if not chunk.mesh_instance or not chunk.mesh_instance.mesh:
			push_warning("[BakeExporter] Chunk %s has no mesh, skipping" % str(chunk.position))
			continue

		var chunk_root := StaticBody3D.new()
		chunk_root.name = "Chunk_%d_%d" % [chunk.position.x, chunk.position.y]
		chunk_root.collision_layer = collision_layer
		chunk_root.collision_mask = collision_mask

		var chunk_pos := Vector3.ZERO
		if chunk.root and is_instance_valid(chunk.root):
			chunk_pos = Vector3(chunk.world_bounds.position.x, 0.0, chunk.world_bounds.position.y)
		chunk_root.position = chunk_pos

		root_node.add_child(chunk_root)
		chunk_root.owner = root_node

		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = chunk.mesh_instance.mesh.duplicate()
		if terrain_material:
			mesh_instance.material_override = terrain_material
		elif chunk.mesh_instance.material_override:
			mesh_instance.material_override = chunk.mesh_instance.material_override
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mesh_instance.name = "Mesh"
		chunk_root.add_child(mesh_instance)
		mesh_instance.owner = root_node

		if generate_collision and chunk.collision_shape and chunk.collision_shape.shape:
			var collision_shape := CollisionShape3D.new()
			collision_shape.shape = chunk.collision_shape.shape.duplicate()
			collision_shape.position = chunk.collision_shape.position
			collision_shape.scale = chunk.collision_shape.scale
			collision_shape.name = "Collision"
			chunk_root.add_child(collision_shape)
			collision_shape.owner = root_node

	# Export water meshes
	for feature in feature_nodes:
		if not is_instance_valid(feature):
			continue
		if not feature.get("generate_water_mesh"):
			continue
		var water_mesh_prop = feature.get("_water_mesh_instance")
		if not water_mesh_prop or not is_instance_valid(water_mesh_prop):
			continue
		var water_mesh_instance = water_mesh_prop as MeshInstance3D
		if not water_mesh_instance.mesh:
			continue

		var water_node := MeshInstance3D.new()
		water_node.name = feature.name + "_Water"
		water_node.mesh = water_mesh_instance.mesh.duplicate()
		if water_mesh_instance.material_override:
			water_node.material_override = water_mesh_instance.material_override
		water_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		var feature_pos := Vector3.ZERO
		if feature is Node3D:
			feature_pos = (feature as Node3D).global_position
		water_node.position = feature_pos

		root_node.add_child(water_node)
		water_node.owner = root_node

	# Export scatter instances
	for scatter in scatter_nodes:
		if not is_instance_valid(scatter):
			continue
		var container = scatter.get_node_or_null("ScatterInstances")
		if not container:
			continue
		for child in container.get_children():
			if not is_instance_valid(child) or not (child is Node3D):
				continue
			if child is MultiMeshInstance3D:
				var mm = child as MultiMeshInstance3D
				var baked_mm = MultiMeshInstance3D.new()
				baked_mm.multimesh = mm.multimesh
				if mm.material_override:
					baked_mm.material_override = mm.material_override
				baked_mm.cast_shadow = mm.cast_shadow
				baked_mm.transform = mm.transform
				baked_mm.name = scatter.name + "_MultiMesh"
				root_node.add_child(baked_mm)
				baked_mm.owner = root_node
				continue
			var instance_copy = child.duplicate(Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS)
			if not instance_copy:
				continue
			var cast_child := child as Node3D
			var cast_copy := instance_copy as Node3D
			# Use global transform since root_node is not in the scene tree
			cast_copy.transform = cast_child.global_transform
			root_node.add_child(instance_copy)
			instance_copy.owner = root_node
			_set_owners_recursive(instance_copy, root_node)

	var packed_scene := PackedScene.new()
	var error := packed_scene.pack(root_node)
	if error != OK:
		push_error("[BakeExporter] Failed to pack baked scene (error %d)" % error)
		return null
	return packed_scene

func _set_owners_recursive(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_owners_recursive(child, owner)
