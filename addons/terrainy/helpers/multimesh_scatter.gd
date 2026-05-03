class_name MultiMeshScatter
extends RefCounted

## Builds and updates a MultiMeshInstance3D from scatter placement data.

const ScatterNode = preload("res://addons/terrainy/nodes/scatter/scatter_node.gd")

static func build_multimesh(
	scatter_node: ScatterNode,
	placement_transforms: Array[Transform3D]
) -> MultiMeshInstance3D:
	if placement_transforms.is_empty():
		return null

	var scene = scatter_node.scene
	if not scene:
		return null

	var preview_node = scene.instantiate()
	if not (preview_node is Node3D):
		preview_node.queue_free()
		return null

	var source_mesh_instance := _find_first_mesh_instance(preview_node as Node3D)
	if not source_mesh_instance or not source_mesh_instance.mesh:
		preview_node.queue_free()
		return null

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = source_mesh_instance.mesh
	multimesh.instance_count = placement_transforms.size()

	for i in placement_transforms.size():
		multimesh.set_instance_transform(i, placement_transforms[i])

	var mesh_instance := MultiMeshInstance3D.new()
	mesh_instance.multimesh = multimesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Copy material override if present
	if source_mesh_instance.material_override:
		mesh_instance.material_override = source_mesh_instance.material_override

	preview_node.queue_free()
	return mesh_instance

static func _find_first_mesh_instance(node: Node3D) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		if child is Node3D:
			var result = _find_first_mesh_instance(child)
			if result:
				return result
	return null
