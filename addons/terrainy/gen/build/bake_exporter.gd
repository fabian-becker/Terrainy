@tool
extends RefCounted

## Bake to scene: static chunk meshes, collision, navigation regions and scatter MultiMeshes.
## The baked scene has no Terrainy dependency at all.

static func export_terrain(generator: Node3D, chunks: Array, material: Material) -> PackedScene:
	# Embed Terrainy-owned resources so the baked scene keeps no dependency on this addon. The
	# auto material's shader is loaded from res://addons/terrainy and would otherwise be stored
	# as an [ext_resource] pointing back into the addon.
	var baked_material: Material = _detach_addon_resources(material)
	var root := Node3D.new()
	root.name = "%sBaked" % generator.name
	root.transform = generator.transform
	for chunk in chunks:
		if chunk.mesh_instance == null or chunk.mesh_instance.mesh == null:
			continue
		var node := Node3D.new()
		node.name = chunk.root.name
		node.transform = chunk.root.transform
		root.add_child(node)
		node.owner = root
		var mesh := MeshInstance3D.new()
		mesh.name = "Mesh"
		mesh.mesh = chunk.mesh_instance.mesh.duplicate()
		mesh.material_override = baked_material
		mesh.cast_shadow = chunk.mesh_instance.cast_shadow
		node.add_child(mesh)
		mesh.owner = root
		if chunk.collision_shape and chunk.collision_shape.shape:
			var body := StaticBody3D.new()
			body.name = "Collision"
			body.collision_layer = chunk.static_body.collision_layer
			body.collision_mask = chunk.static_body.collision_mask
			node.add_child(body)
			body.owner = root
			var shape := CollisionShape3D.new()
			shape.name = "Shape"
			shape.shape = chunk.collision_shape.shape.duplicate()
			shape.transform = chunk.collision_shape.transform
			body.add_child(shape)
			shape.owner = root
		if chunk.nav_region and is_instance_valid(chunk.nav_region) and chunk.nav_region.navigation_mesh:
			var region := NavigationRegion3D.new()
			region.name = "Navigation"
			region.navigation_mesh = chunk.nav_region.navigation_mesh.duplicate()
			node.add_child(region)
			region.owner = root
		for id in chunk.scatter:
			var mmi: MultiMeshInstance3D = chunk.scatter[id]
			if mmi == null or not is_instance_valid(mmi) or mmi.multimesh == null:
				continue
			# Rebuilt from the CPU-side transforms: MultiMesh buffers live in the renderer.
			var transforms: Array = chunk.scatter_transforms.get(id, [])
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mmi.multimesh.mesh
			mm.instance_count = transforms.size()
			for i in transforms.size():
				mm.set_instance_transform(i, transforms[i])
			var copy := MultiMeshInstance3D.new()
			copy.name = mmi.name
			copy.multimesh = mm
			copy.material_override = mmi.material_override
			copy.cast_shadow = mmi.cast_shadow
			node.add_child(copy)
			copy.owner = root
	var packed := PackedScene.new()
	var err := packed.pack(root)
	root.free()
	if err != OK:
		push_error("[TerrainGenerator] Bake failed to pack the scene (error %d)" % err)
		return null
	return packed

## Copy a material with any Terrainy-owned sub-resources detached from their on-disk path.
## `PackedScene.pack` turns path-bearing resources into external references; a duplicated
## [Shader] has an empty path, so it is written inline as a sub-resource instead.
static func _detach_addon_resources(material: Material) -> Material:
	if material == null:
		return null
	var copy := material.duplicate()
	if copy is ShaderMaterial:
		var shader_material: ShaderMaterial = copy
		var shader: Shader = shader_material.shader
		if shader != null and shader.resource_path.begins_with("res://addons/terrainy/"):
			shader_material.shader = shader.duplicate()
	return copy
