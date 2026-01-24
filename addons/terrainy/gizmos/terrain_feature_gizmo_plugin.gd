@tool
extends EditorNode3DGizmoPlugin

## Gizmo plugin for TerrainFeatureNodes to visualize influence radius

const TerrainFeatureNode = preload("res://addons/terrainy/nodes/terrain_feature_node.gd")

# Gizmo color constants
const GIZMO_COLOR_MAIN = Color(0.3, 0.8, 1.0, 0.6)
const GIZMO_COLOR_FALLOFF = Color(0.8, 0.5, 0.2, 0.4)
const GIZMO_COLOR_DIRECTION = Color(1.0, 0.3, 0.3, 0.8)
const GIZMO_COLOR_HEIGHT = Color(0.3, 1.0, 0.3, 0.6)

signal gizmo_manipulation_started(node: Node3D)
signal gizmo_manipulation_ended(node: Node3D)

var show_gizmos: bool = true
var undo_redo: EditorUndoRedoManager

func _init():
	create_material("main", GIZMO_COLOR_MAIN)
	create_material("falloff", GIZMO_COLOR_FALLOFF)
	create_material("direction", GIZMO_COLOR_DIRECTION)
	create_material("height", GIZMO_COLOR_HEIGHT)
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
	
	var size = node.influence_size
	var segments = 64
	
	# Draw influence shape based on type
	match node.influence_shape:
		TerrainFeatureNode.InfluenceShape.CIRCLE:
			_draw_circle(lines, size.x, segments)
			if node.edge_falloff > 0.0:
				var falloff_radius = size.x * (1.0 - node.edge_falloff)
				_draw_circle(falloff_lines, falloff_radius, segments)
		
		TerrainFeatureNode.InfluenceShape.RECTANGLE:
			_draw_rectangle(lines, size)
			if node.edge_falloff > 0.0:
				var falloff_size = size * (1.0 - node.edge_falloff)
				_draw_rectangle(falloff_lines, falloff_size)
		
		TerrainFeatureNode.InfluenceShape.ELLIPSE:
			_draw_ellipse(lines, size, segments)
			if node.edge_falloff > 0.0:
				var falloff_size = size * (1.0 - node.edge_falloff)
				_draw_ellipse(falloff_lines, falloff_size, segments)
	
	# Add cross at center
	lines.push_back(Vector3(-5, 0, 0))
	lines.push_back(Vector3(5, 0, 0))
	lines.push_back(Vector3(0, 0, -5))
	lines.push_back(Vector3(0, 0, 5))
	
	# Draw direction arrow for gradient and landscape nodes
	if "direction" in node:
		var dir = node.direction as Vector2
		var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
		var max_size = max(size.x, size.y)
		var arrow_length = max_size * 0.7
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
			var line_length = max_size * 0.5
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
		
		# Start height (center for radial, back for linear)
		var back_pos = Vector3.ZERO
		if "direction" in node:
			var dir = node.direction as Vector2
			var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
			var grad_length = size.x
			back_pos = -dir_3d * grad_length
		
		height_lines.push_back(back_pos)
		height_lines.push_back(back_pos + Vector3(0, start_h, 0))
		
		# End height (edge for radial, front for linear)
		var front_pos = Vector3(size.x, 0, 0)
		if "direction" in node:
			var dir = node.direction as Vector2
			var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
			var grad_length = size.x
			front_pos = dir_3d * grad_length
		
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
	
	# Handle 0: Size control (right side for width)
	handles.push_back(Vector3(size.x, 0, 0))
	
	# Handle 1: Size control (depth, for rectangle and ellipse)
	if node.influence_shape != TerrainFeatureNode.InfluenceShape.CIRCLE:
		handles.push_back(Vector3(0, 0, size.y))
	
	# Handle 2: Falloff control (if falloff exists)
	if node.edge_falloff > 0.0:
		var falloff_size = size.x * (1.0 - node.edge_falloff)
		handles.push_back(Vector3(falloff_size, 0, 0))
	
	# Handle 2: Height control (vertical, for primitives and landscapes)
	if "height" in node:
		var height_val = node.height
		handles.push_back(Vector3(0, height_val, 0))
	
	# Handle 3: Start height control (for gradients)
	if "start_height" in node:
		var start_h = node.start_height
		var back_pos = Vector3.ZERO
		if "direction" in node:
			var dir = node.direction as Vector2
			var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
			var grad_length = size.x
			back_pos = -dir_3d * grad_length
		handles.push_back(back_pos + Vector3(0, start_h, 0))
	
	# Handle 4: End height control (for gradients)
	if "end_height" in node:
		var end_h = node.end_height
		var front_pos = Vector3(size.x, 0, 0)
		if "direction" in node:
			var dir = node.direction as Vector2
			var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
			var grad_length = size.x
			front_pos = dir_3d * grad_length
		handles.push_back(front_pos + Vector3(0, end_h, 0))
	
	# Handle 5: Direction control (for landscapes and gradients)
	if "direction" in node:
		var dir = node.direction as Vector2
		var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
		var max_size = max(size.x, size.y)
		var arrow_length = max_size * 0.7
		handles.push_back(dir_3d * arrow_length)
	
	gizmo.add_handles(handles, get_material("handles", gizmo), handle_ids)

func _get_handle_name(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> String:
	var node = gizmo.get_node_3d() as TerrainFeatureNode
	if not node:
		return ""
	
	var handle_index = 0
	
	# Handle 0: Size X (width)
	if handle_index == handle_id:
		if node.influence_shape == TerrainFeatureNode.InfluenceShape.CIRCLE:
			return "Radius"
		else:
			return "Width"
	handle_index += 1
	
	# Handle 1: Size Y (depth, for rectangle and ellipse)
	if node.influence_shape != TerrainFeatureNode.InfluenceShape.CIRCLE:
		if handle_index == handle_id:
			return "Depth"
		handle_index += 1
	
	# Handle 2: Falloff (if exists)
	if node.edge_falloff > 0.0:
		if handle_index == handle_id:
			return "Falloff"
		handle_index += 1
	
	# Handle 2: Height (for primitives and landscapes, not gradients)
	if "height" in node and not ("start_height" in node):
		if handle_index == handle_id:
			return "Height"
		handle_index += 1
	
	# Handle 3: Start height (for gradients)
	if "start_height" in node:
		if handle_index == handle_id:
			return "Start Height"
		handle_index += 1
	
	# Handle 4: End height (for gradients)
	if "end_height" in node:
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
	
	# Handle 0: Size X (width/radius)
	if handle_index == handle_id:
		return node.influence_size.x
	handle_index += 1
	
	# Handle 1: Size Y (depth, for rectangle and ellipse)
	if node.influence_shape != TerrainFeatureNode.InfluenceShape.CIRCLE:
		if handle_index == handle_id:
			return node.influence_size.y
		handle_index += 1
	
	# Handle 2: Falloff (if exists)
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
	if "start_height" in node:
		if handle_index == handle_id:
			return node.start_height
		handle_index += 1
	
	# Handle 4: End height (for gradients)
	if "end_height" in node:
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

	# Signal that manipulation is starting (first handle drag)
	if not node.get_meta("_gizmo_manipulating", false):
		node.set_meta("_gizmo_manipulating", true)
		node.set_meta("_gizmo_manipulation_time", Time.get_ticks_msec() / 1000.0)
		gizmo_manipulation_started.emit(node)
	
	if not is_instance_valid(undo_redo):
		push_warning("TerrainFeatureGizmoPlugin: undo_redo is invalid, gizmo may not work correctly")
		return
	
	# Get ray from camera
	var ray_from = camera.project_ray_origin(screen_pos)
	var ray_dir = camera.project_ray_normal(screen_pos)
	
	var handle_index = 0
	
	# Handle 0: Size X (width/radius)
	if handle_index == handle_id:
		var plane = Plane(Vector3.UP, 0)
		var intersection = plane.intersects_ray(ray_from, ray_dir)
		if intersection != null:
			var local_intersection = node.to_local(intersection)
			var new_size_x = max(1.0, abs(local_intersection.x))
			if node.influence_shape == TerrainFeatureNode.InfluenceShape.CIRCLE:
				node.influence_size = Vector2(new_size_x, new_size_x)
			else:
				node.influence_size.x = new_size_x
		_redraw(gizmo)
		return
	handle_index += 1
	
	# Handle 1: Size Y (depth, for rectangle and ellipse)
	if node.influence_shape != TerrainFeatureNode.InfluenceShape.CIRCLE:
		if handle_index == handle_id:
			var plane = Plane(Vector3.UP, 0)
			var intersection = plane.intersects_ray(ray_from, ray_dir)
			if intersection != null:
				var local_intersection = node.to_local(intersection)
				node.influence_size.y = max(1.0, abs(local_intersection.z))
			_redraw(gizmo)
			return
		handle_index += 1
	
	# Handle 2: Falloff
	if node.edge_falloff > 0.0:
		if handle_index == handle_id:
			var plane = Plane(Vector3.UP, 0)
			var intersection = plane.intersects_ray(ray_from, ray_dir)
			if intersection != null:
				var local_intersection = node.to_local(intersection)
				var distance = Vector2(local_intersection.x, local_intersection.z).length()
				var max_size = max(node.influence_size.x, node.influence_size.y)
				var new_falloff_radius = max(0.1, distance)
				node.edge_falloff = clamp(1.0 - (new_falloff_radius / max_size), 0.0, 1.0)
			_redraw(gizmo)
			return
		handle_index += 1
	
	# Handle 3: Height (for primitives and landscapes)
	if "height" in node and not ("start_height" in node):
		if handle_index == handle_id:
			# Create a vertical plane that passes through the node's position
			var node_pos = node.global_position
			var vertical_plane = Plane(Vector3.RIGHT, node_pos)
			var vertical_intersection = vertical_plane.intersects_ray(ray_from, ray_dir)
			if vertical_intersection != null:
				var local_y = node.to_local(vertical_intersection).y
				node.height = local_y
			_redraw(gizmo)
			return
		handle_index += 1
	
	# Handle 3: Start height (for gradients)
	if "start_height" in node:
		if handle_index == handle_id:
			var back_pos_global = node.global_position
			var vertical_plane = Plane(Vector3.RIGHT, back_pos_global)
			if "direction" in node:
				var dir = node.direction as Vector2
				var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
				var grad_length = node.influence_size.x
				back_pos_global = node.to_global(-dir_3d * grad_length)
				vertical_plane = Plane(Vector3.RIGHT.rotated(Vector3.UP, atan2(dir_3d.z, dir_3d.x)), back_pos_global)
			var vertical_intersection = vertical_plane.intersects_ray(ray_from, ray_dir)
			if vertical_intersection != null:
				var local_y = node.to_local(vertical_intersection).y
				node.start_height = local_y
			_redraw(gizmo)
			return
		handle_index += 1
	
	# Handle 4: End height (for gradients)
	if "end_height" in node:
		if handle_index == handle_id:
			var front_pos_global = node.to_global(Vector3(node.influence_size.x, 0, 0))
			var vertical_plane = Plane(Vector3.RIGHT, front_pos_global)
			if "direction" in node:
				var dir = node.direction as Vector2
				var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
				var grad_length = node.influence_size.x
				front_pos_global = node.to_global(dir_3d * grad_length)
				vertical_plane = Plane(Vector3.RIGHT.rotated(Vector3.UP, atan2(dir_3d.z, dir_3d.x)), front_pos_global)
			var vertical_intersection = vertical_plane.intersects_ray(ray_from, ray_dir)
			if vertical_intersection != null:
				var local_y = node.to_local(vertical_intersection).y
				node.end_height = local_y
			_redraw(gizmo)
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
			_redraw(gizmo)
			return
		handle_index += 1

func _commit_handle(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool, restore: Variant, cancel: bool) -> void:
	var node = gizmo.get_node_3d() as TerrainFeatureNode
	if not node:
		return
	
	# Signal that manipulation has ended
	var was_manipulating = node.get_meta("_gizmo_manipulating", false)
	if was_manipulating:
		node.set_meta("_gizmo_manipulating", false)
		node.remove_meta("_gizmo_manipulation_time")
		gizmo_manipulation_ended.emit(node)
	
	if not is_instance_valid(undo_redo):
		push_warning("TerrainFeatureGizmoPlugin: undo_redo is invalid, changes will not be undoable")
		# Still emit the parameters_changed signal to update the terrain
		if was_manipulating:
			node._commit_parameter_change()
		return
	
	var handle_index = 0
	
	# Handle 0: Size X (width/radius)
	if handle_index == handle_id:
		if cancel:
			# Restore is a float (influence_size.x), need to update only X component
			if node.influence_shape == TerrainFeatureNode.InfluenceShape.CIRCLE:
				node.influence_size = Vector2(restore, restore)
			else:
				node.influence_size.x = restore
		else:
			undo_redo.create_action("Change Influence Size X")
			undo_redo.add_do_property(node, "influence_size", node.influence_size)
			undo_redo.add_undo_property(node, "influence_size", 
				Vector2(restore, restore) if node.influence_shape == TerrainFeatureNode.InfluenceShape.CIRCLE else Vector2(restore, node.influence_size.y))
			undo_redo.commit_action()
		if was_manipulating:
				node._commit_parameter_change()
		return
	handle_index += 1
	
	# Handle 1: Size Y (depth, for rectangle and ellipse)
	if node.influence_shape != TerrainFeatureNode.InfluenceShape.CIRCLE:
		if handle_index == handle_id:
			if cancel:
				# Restore is a float (influence_size.y), need to update only Y component
				node.influence_size.y = restore
			else:
				undo_redo.create_action("Change Influence Depth")
				undo_redo.add_do_property(node, "influence_size", node.influence_size)
				undo_redo.add_undo_property(node, "influence_size", Vector2(node.influence_size.x, restore))
				undo_redo.commit_action()
			if was_manipulating:
					node._commit_parameter_change()
			return
		handle_index += 1
	
	# Handle 2: Falloff
	if node.edge_falloff > 0.0 or cancel:
		if handle_index == handle_id:
			if cancel:
				node.edge_falloff = restore
			else:
				undo_redo.create_action("Change Edge Falloff")
				undo_redo.add_do_property(node, "edge_falloff", node.edge_falloff)
				undo_redo.add_undo_property(node, "edge_falloff", restore)
				undo_redo.commit_action()
			if was_manipulating:
					node._commit_parameter_change()
			return
		handle_index += 1
	
	# Handle 3: Height (for primitives and landscapes)
	if "height" in node and not ("start_height" in node):
		if handle_index == handle_id:
			if cancel:
				node.height = restore
			else:
				undo_redo.create_action("Change Height")
				undo_redo.add_do_property(node, "height", node.height)
				undo_redo.add_undo_property(node, "height", restore)
				undo_redo.commit_action()
			if was_manipulating:
					node._commit_parameter_change()
			return
		handle_index += 1
	
	# Handle 3: Start height (for gradients)
	if "start_height" in node:
		if handle_index == handle_id:
			if cancel:
				node.start_height = restore
			else:
				undo_redo.create_action("Change Start Height")
				undo_redo.add_do_property(node, "start_height", node.start_height)
				undo_redo.add_undo_property(node, "start_height", restore)
				undo_redo.commit_action()
			if was_manipulating:
					node._commit_parameter_change()
			return
		handle_index += 1
	
	# Handle 4: End height (for gradients)
	if "end_height" in node:
		if handle_index == handle_id:
			if cancel:
				node.end_height = restore
			else:
				undo_redo.create_action("Change End Height")
				undo_redo.add_do_property(node, "end_height", node.end_height)
				undo_redo.add_undo_property(node, "end_height", restore)
				undo_redo.commit_action()
			if was_manipulating:
					node._commit_parameter_change()
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
			if was_manipulating:
				node.parameters_changed.emit()
			return
		handle_index += 1

## Helper functions for drawing different shapes
func _draw_circle(lines: PackedVector3Array, radius: float, segments: int) -> void:
	for i in range(segments):
		var angle1 = (i / float(segments)) * TAU
		var angle2 = ((i + 1) / float(segments)) * TAU

		var p1 = Vector3(cos(angle1) * radius, 0, sin(angle1) * radius)
		var p2 = Vector3(cos(angle2) * radius, 0, sin(angle2) * radius)

		lines.push_back(p1)
		lines.push_back(p2)

func _draw_rectangle(lines: PackedVector3Array, size: Vector2) -> void:
	var half_size = size * 0.5

	# Four corners
	var corners = [
	Vector3(-half_size.x, 0, -half_size.y),
	Vector3(half_size.x, 0, -half_size.y),
	Vector3(half_size.x, 0, half_size.y),
	Vector3(-half_size.x, 0, half_size.y)
	]

	# Draw four edges
	for i in range(4):
		lines.push_back(corners[i])
		lines.push_back(corners[(i + 1) % 4])

func _draw_ellipse(lines: PackedVector3Array, size: Vector2, segments: int) -> void:
	for i in range(segments):
		var angle1 = (i / float(segments)) * TAU
		var angle2 = ((i + 1) / float(segments)) * TAU

		var p1 = Vector3(cos(angle1) * size.x, 0, sin(angle1) * size.y)
		var p2 = Vector3(cos(angle2) * size.x, 0, sin(angle2) * size.y)

		lines.push_back(p1)
		lines.push_back(p2)
