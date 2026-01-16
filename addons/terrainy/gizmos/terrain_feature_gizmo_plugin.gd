@tool
extends EditorNode3DGizmoPlugin

## Gizmo plugin for TerrainFeatureNodes to visualize influence radius

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")

var show_gizmos: bool = true
var undo_redo: EditorUndoRedoManager

func _init():
	create_material("main", Color(0.3, 0.8, 1.0, 0.6))
	create_material("falloff", Color(0.8, 0.5, 0.2, 0.4))
	create_material("direction", Color(1.0, 0.3, 0.3, 0.8))
	create_material("height", Color(0.3, 1.0, 0.3, 0.6))
	create_handle_material("handles")

func _get_gizmo_name() -> String:
	return "TerrainFeature"

func _has_gizmo(node: Node3D) -> bool:
	if not node:
		return false
	
	var script = node.get_script()
	if not script:
		return false
	
	# Check if this script extends TerrainFeatureNode
	var base_script = script.get_base_script()
	while base_script:
		if base_script.resource_path == "res://addons/terrainy/nodes/terrain_feature_node.gd":
			return true
		base_script = base_script.get_base_script()
	
	# Also check if the script itself is TerrainFeatureNode
	if script.resource_path == "res://addons/terrainy/nodes/terrain_feature_node.gd":
		return true
	
	return false
func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	
	if not show_gizmos:
		return
	
	var node = gizmo.get_node_3d() as TerrainFeatureNode
	if not node:
		return
	
	var lines = PackedVector3Array()
	var falloff_lines = PackedVector3Array()
	var direction_lines = PackedVector3Array()
	var height_lines = PackedVector3Array()
	
	var radius = node.influence_radius
	var segments = 64
	
	# Draw influence radius circle
	for i in range(segments):
		var angle1 = (i / float(segments)) * TAU
		var angle2 = ((i + 1) / float(segments)) * TAU
		
		var p1 = Vector3(cos(angle1) * radius, 0, sin(angle1) * radius)
		var p2 = Vector3(cos(angle2) * radius, 0, sin(angle2) * radius)
		
		lines.push_back(p1)
		lines.push_back(p2)
	
	# Draw falloff zone if applicable
	if node.edge_falloff > 0.0:
		var falloff_radius = radius * (1.0 - node.edge_falloff)
		for i in range(segments):
			var angle1 = (i / float(segments)) * TAU
			var angle2 = ((i + 1) / float(segments)) * TAU
			
			var p1 = Vector3(cos(angle1) * falloff_radius, 0, sin(angle1) * falloff_radius)
			var p2 = Vector3(cos(angle2) * falloff_radius, 0, sin(angle2) * falloff_radius)
			
			falloff_lines.push_back(p1)
			falloff_lines.push_back(p2)
	
	# Add cross at center
	lines.push_back(Vector3(-5, 0, 0))
	lines.push_back(Vector3(5, 0, 0))
	lines.push_back(Vector3(0, 0, -5))
	lines.push_back(Vector3(0, 0, 5))
	
	# Draw direction arrow for gradient and landscape nodes
	if "direction" in node:
		var dir = node.direction as Vector2
		var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
		var arrow_length = radius * 0.7
		var arrow_head_size = 10.0
		
		# Main arrow line
		var arrow_end = dir_3d * arrow_length
		direction_lines.push_back(Vector3.ZERO)
		direction_lines.push_back(arrow_end)
		
		# Arrow head
		var arrow_left = arrow_end - dir_3d * arrow_head_size + Vector3(-dir_3d.z, 0, dir_3d.x) * arrow_head_size * 0.5
		var arrow_right = arrow_end - dir_3d * arrow_head_size + Vector3(dir_3d.z, 0, -dir_3d.x) * arrow_head_size * 0.5
		direction_lines.push_back(arrow_end)
		direction_lines.push_back(arrow_left)
		direction_lines.push_back(arrow_end)
		direction_lines.push_back(arrow_right)
		
		# Draw perpendicular lines for gradients to show the gradient direction
		if node is GradientNode:
			var perp = Vector3(-dir_3d.z, 0, dir_3d.x)
			var line_length = radius * 0.5
			direction_lines.push_back(arrow_end + perp * line_length)
			direction_lines.push_back(arrow_end - perp * line_length)
	
	# Draw height visualization for primitives and gradients
	if "height" in node:
		var height_val = node.height
		height_lines.push_back(Vector3.ZERO)
		height_lines.push_back(Vector3(0, height_val, 0))
		
		# Add a small horizontal indicator at the height level
		height_lines.push_back(Vector3(-5, height_val, 0))
		height_lines.push_back(Vector3(5, height_val, 0))
		height_lines.push_back(Vector3(0, height_val, -5))
		height_lines.push_back(Vector3(0, height_val, 5))
	
	# For gradient nodes, draw both start and end height
	if "start_height" in node and "end_height" in node:
		var start_h = node.start_height
		var end_h = node.end_height
		
		# Start height (at the back of the gradient)
		var back_pos = Vector3.ZERO
		if "direction" in node:
			var dir = node.direction as Vector2
			var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
			back_pos = -dir_3d * radius
		
		height_lines.push_back(back_pos)
		height_lines.push_back(back_pos + Vector3(0, start_h, 0))
		
		# End height (at the front of the gradient)
		var front_pos = Vector3.ZERO
		if "direction" in node:
			var dir = node.direction as Vector2
			var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
			front_pos = dir_3d * radius
		
		height_lines.push_back(front_pos)
		height_lines.push_back(front_pos + Vector3(0, end_h, 0))
		
		# Connect the height line across the gradient
		height_lines.push_back(back_pos + Vector3(0, start_h, 0))
		height_lines.push_back(front_pos + Vector3(0, end_h, 0))
	
	# Add lines to gizmo
	gizmo.add_lines(lines, get_material("main", gizmo))
	if falloff_lines.size() > 0:
		gizmo.add_lines(falloff_lines, get_material("falloff", gizmo))
	if direction_lines.size() > 0:
		gizmo.add_lines(direction_lines, get_material("direction", gizmo))
	if height_lines.size() > 0:
		gizmo.add_lines(height_lines, get_material("height", gizmo))
	
	# Add handles
	var handles = PackedVector3Array()
	var handle_ids = PackedInt32Array()
	
	# Handle 0: Radius control (right side)
	handles.push_back(Vector3(radius, 0, 0))
	
	# Handle 1: Falloff control (if falloff exists)
	if node.edge_falloff > 0.0:
		var falloff_radius = radius * (1.0 - node.edge_falloff)
		handles.push_back(Vector3(falloff_radius, 0, 0))
	
	# Handle 2: Height control (vertical, for primitives and landscapes)
	if "height" in node and not ("start_height" in node):
		var height_val = node.height
		handles.push_back(Vector3(0, height_val, 0))
	
	# Handle 3: Start height control (for gradients)
	if "start_height" in node and "direction" in node:
		var start_h = node.start_height
		var dir = node.direction as Vector2
		var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
		var back_pos = -dir_3d * radius
		handles.push_back(back_pos + Vector3(0, start_h, 0))
	
	# Handle 4: End height control (for gradients)
	if "end_height" in node and "direction" in node:
		var end_h = node.end_height
		var dir = node.direction as Vector2
		var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
		var front_pos = dir_3d * radius
		handles.push_back(front_pos + Vector3(0, end_h, 0))
	
	# Handle 5: Direction control (for landscapes and gradients)
	if "direction" in node:
		var dir = node.direction as Vector2
		var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
		var arrow_length = radius * 0.7
		handles.push_back(dir_3d * arrow_length)
	
	gizmo.add_handles(handles, get_material("handles", gizmo), handle_ids)

func _get_handle_name(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> String:
	var node = gizmo.get_node_3d() as TerrainFeatureNode
	if not node:
		return ""
	
	var handle_index = 0
	
	# Handle 0: Always radius
	if handle_index == handle_id:
		return "Influence Radius"
	handle_index += 1
	
	# Handle 1: Falloff (if exists)
	if node.edge_falloff > 0.0:
		if handle_index == handle_id:
			return "Falloff Radius"
		handle_index += 1
	
	# Handle 2: Height (for primitives and landscapes, not gradients)
	if "height" in node and not ("start_height" in node):
		if handle_index == handle_id:
			return "Height"
		handle_index += 1
	
	# Handle 3: Start height (for gradients)
	if "start_height" in node and "direction" in node:
		if handle_index == handle_id:
			return "Start Height"
		handle_index += 1
	
	# Handle 4: End height (for gradients)
	if "end_height" in node and "direction" in node:
		if handle_index == handle_id:
			return "End Height"
		handle_index += 1
	
	# Handle 5: Direction (for landscapes and gradients)
	if "direction" in node:
		if handle_index == handle_id:
			return "Direction"
		handle_index += 1
	
	return ""

func _get_handle_value(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> Variant:
	var node = gizmo.get_node_3d() as TerrainFeatureNode
	if not node:
		return null
	
	var handle_index = 0
	
	# Handle 0: Always radius
	if handle_index == handle_id:
		return node.influence_radius
	handle_index += 1
	
	# Handle 1: Falloff (if exists)
	if node.edge_falloff > 0.0:
		if handle_index == handle_id:
			return node.edge_falloff
		handle_index += 1
	
	# Handle 2: Height (for primitives and landscapes, not gradients)
	if "height" in node and not ("start_height" in node):
		if handle_index == handle_id:
			return node.height
		handle_index += 1
	
	# Handle 3: Start height (for gradients)
	if "start_height" in node and "direction" in node:
		if handle_index == handle_id:
			return node.start_height
		handle_index += 1
	
	# Handle 4: End height (for gradients)
	if "end_height" in node and "direction" in node:
		if handle_index == handle_id:
			return node.end_height
		handle_index += 1
	
	# Handle 5: Direction (for landscapes and gradients)
	if "direction" in node:
		if handle_index == handle_id:
			return node.direction
		handle_index += 1
	
	return null

func _set_handle(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool, camera: Camera3D, screen_pos: Vector2) -> void:
	var node = gizmo.get_node_3d() as TerrainFeatureNode
	if not node:
		return
	
	if not is_instance_valid(undo_redo):
		push_warning("TerrainFeatureGizmoPlugin: undo_redo is invalid, gizmo may not work correctly")
		return
	
	# Get ray from camera
	var ray_from = camera.project_ray_origin(screen_pos)
	var ray_dir = camera.project_ray_normal(screen_pos)
	
	var handle_index = 0
	
	# Handle 0: Radius
	if handle_index == handle_id:
		var plane = Plane(Vector3.UP, 0)
		var intersection = plane.intersects_ray(ray_from, ray_dir)
		if intersection != null:
			var local_intersection = node.to_local(intersection)
			var distance = Vector2(local_intersection.x, local_intersection.z).length()
			node.influence_radius = max(1.0, distance)
		return
	handle_index += 1
	
	# Handle 1: Falloff
	if node.edge_falloff > 0.0:
		if handle_index == handle_id:
			var plane = Plane(Vector3.UP, 0)
			var intersection = plane.intersects_ray(ray_from, ray_dir)
			if intersection != null:
				var local_intersection = node.to_local(intersection)
				var distance = Vector2(local_intersection.x, local_intersection.z).length()
				var new_falloff_radius = max(0.1, distance)
				node.edge_falloff = clamp(1.0 - (new_falloff_radius / node.influence_radius), 0.0, 1.0)
			return
		handle_index += 1
	
	# Handle 2: Height (for primitives and landscapes)
	if "height" in node and not ("start_height" in node):
		if handle_index == handle_id:
			var vertical_plane = Plane(Vector3.RIGHT, 0)
			var vertical_intersection = vertical_plane.intersects_ray(ray_from, ray_dir)
			if vertical_intersection != null:
				var local_y = node.to_local(vertical_intersection).y
				node.height = local_y
			return
		handle_index += 1
	
	# Handle 3: Start height (for gradients)
	if "start_height" in node and "direction" in node:
		if handle_index == handle_id:
			var dir = node.direction as Vector2
			var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
			var back_pos_global = node.to_global(-dir_3d * node.influence_radius)
			var vertical_plane = Plane(Vector3.RIGHT.rotated(Vector3.UP, atan2(dir_3d.z, dir_3d.x)), back_pos_global)
			var vertical_intersection = vertical_plane.intersects_ray(ray_from, ray_dir)
			if vertical_intersection != null:
				var local_y = node.to_local(vertical_intersection).y
				node.start_height = local_y
			return
		handle_index += 1
	
	# Handle 4: End height (for gradients)
	if "end_height" in node and "direction" in node:
		if handle_index == handle_id:
			var dir = node.direction as Vector2
			var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
			var front_pos_global = node.to_global(dir_3d * node.influence_radius)
			var vertical_plane = Plane(Vector3.RIGHT.rotated(Vector3.UP, atan2(dir_3d.z, dir_3d.x)), front_pos_global)
			var vertical_intersection = vertical_plane.intersects_ray(ray_from, ray_dir)
			if vertical_intersection != null:
				var local_y = node.to_local(vertical_intersection).y
				node.end_height = local_y
			return
		handle_index += 1
	
	# Handle 5: Direction (for landscapes and gradients)
	if "direction" in node:
		if handle_index == handle_id:
			var plane = Plane(Vector3.UP, 0)
			var intersection = plane.intersects_ray(ray_from, ray_dir)
			if intersection != null:
				var local_intersection = node.to_local(intersection)
				var dir_2d = Vector2(local_intersection.x, local_intersection.z)
				if dir_2d.length() > 0.1:
					node.direction = dir_2d.normalized()
			return
		handle_index += 1

func _commit_handle(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool, restore: Variant, cancel: bool) -> void:
	var node = gizmo.get_node_3d() as TerrainFeatureNode
	if not node:
		return
	
	if not is_instance_valid(undo_redo):
		push_warning("TerrainFeatureGizmoPlugin: undo_redo is invalid, changes will not be undoable")
		return
	
	var handle_index = 0
	
	# Handle 0: Radius
	if handle_index == handle_id:
		if cancel:
			node.influence_radius = restore
		else:
			undo_redo.create_action("Change Influence Radius")
			undo_redo.add_do_property(node, "influence_radius", node.influence_radius)
			undo_redo.add_undo_property(node, "influence_radius", restore)
			undo_redo.commit_action()
		return
	handle_index += 1
	
	# Handle 1: Falloff
	if node.edge_falloff > 0.0 or cancel:
		if handle_index == handle_id:
			if cancel:
				node.edge_falloff = restore
			else:
				undo_redo.create_action("Change Edge Falloff")
				undo_redo.add_do_property(node, "edge_falloff", node.edge_falloff)
				undo_redo.add_undo_property(node, "edge_falloff", restore)
				undo_redo.commit_action()
			return
		handle_index += 1
	
	# Handle 2: Height (for primitives and landscapes)
	if "height" in node and not ("start_height" in node):
		if handle_index == handle_id:
			if cancel:
				node.height = restore
			else:
				undo_redo.create_action("Change Height")
				undo_redo.add_do_property(node, "height", node.height)
				undo_redo.add_undo_property(node, "height", restore)
				undo_redo.commit_action()
			return
		handle_index += 1
	
	# Handle 3: Start height (for gradients)
	if "start_height" in node and "direction" in node:
		if handle_index == handle_id:
			if cancel:
				node.start_height = restore
			else:
				undo_redo.create_action("Change Start Height")
				undo_redo.add_do_property(node, "start_height", node.start_height)
				undo_redo.add_undo_property(node, "start_height", restore)
				undo_redo.commit_action()
			return
		handle_index += 1
	
	# Handle 4: End height (for gradients)
	if "end_height" in node and "direction" in node:
		if handle_index == handle_id:
			if cancel:
				node.end_height = restore
			else:
				undo_redo.create_action("Change End Height")
				undo_redo.add_do_property(node, "end_height", node.end_height)
				undo_redo.add_undo_property(node, "end_height", restore)
				undo_redo.commit_action()
			return
		handle_index += 1
	
	# Handle 5: Direction (for landscapes and gradients)
	if "direction" in node:
		if handle_index == handle_id:
			if cancel:
				node.direction = restore
			else:
				undo_redo.create_action("Change Direction")
				undo_redo.add_do_property(node, "direction", node.direction)
				undo_redo.add_undo_property(node, "direction", restore)
				undo_redo.commit_action()
			return
		handle_index += 1