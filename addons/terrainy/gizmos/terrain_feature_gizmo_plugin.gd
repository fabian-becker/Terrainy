@tool
extends EditorNode3DGizmoPlugin

## Gizmo plugin for TerrainFeatureNodes to visualize influence radius

const HoleNode = preload("res://addons/terrainy/nodes/hole_node.gd")
const GizmoHandle = preload("res://addons/terrainy/gizmos/gizmo_handle.gd")

# Gizmo color constants
const GIZMO_COLOR_MAIN = Color(0.3, 0.8, 1.0, 0.6)
const GIZMO_COLOR_FALLOFF = Color(0.8, 0.5, 0.2, 0.4)
const GIZMO_COLOR_DIRECTION = Color(1.0, 0.3, 0.3, 0.8)
const GIZMO_COLOR_HEIGHT = Color(0.3, 1.0, 0.3, 0.6)
const GIZMO_COLOR_HOLE = Color(1.0, 0.3, 0.3, 0.5)  # Red for holes

signal gizmo_manipulation_started(node: Node3D)
signal gizmo_manipulation_ended(node: Node3D)

var show_gizmos: bool = true
var undo_redo: EditorUndoRedoManager

func _init():
	create_material("main", GIZMO_COLOR_MAIN)
	create_material("falloff", GIZMO_COLOR_FALLOFF)
	create_material("direction", GIZMO_COLOR_DIRECTION)
	create_material("height", GIZMO_COLOR_HEIGHT)
	create_material("hole", GIZMO_COLOR_HOLE)
	create_handle_material("handles")

func _get_gizmo_name() -> String:
	return "TerrainFeature"

func _has_gizmo(node: Node3D) -> bool:
	if not node:
		return false
	return TerrainyScriptUtils.is_script_type(node, "TerrainFeatureNode")

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
			var circle_radius = max(size.x, size.y) * 0.5
			_draw_circle(lines, circle_radius, segments)
			if node.edge_falloff > 0.0:
				var falloff_radius = circle_radius * (1.0 - node.edge_falloff)
				_draw_circle(falloff_lines, falloff_radius, segments)
		
		TerrainFeatureNode.InfluenceShape.RECTANGLE:
			_draw_rectangle(lines, size)
			if node.edge_falloff > 0.0:
				var falloff_size = size * (1.0 - node.edge_falloff)
				_draw_rectangle(falloff_lines, falloff_size)
		
		TerrainFeatureNode.InfluenceShape.ELLIPSE:
			var ellipse_radii = size * 0.5
			_draw_ellipse(lines, ellipse_radii, segments)
			if node.edge_falloff > 0.0:
				var falloff_size = ellipse_radii * (1.0 - node.edge_falloff)
				_draw_ellipse(falloff_lines, falloff_size, segments)
	
	# Add cross at center
	lines.push_back(Vector3(-5, 0, 0))
	lines.push_back(Vector3(5, 0, 0))
	lines.push_back(Vector3(0, 0, -5))
	lines.push_back(Vector3(0, 0, 5))
	
	# Get handles to determine what visual indicators to draw
	var handles = node._get_gizmo_handles()
	
	# Draw special indication for hole nodes
	var hole_lines = PackedVector3Array()
	if node is HoleNode:
		var hole_node = node as HoleNode
		# Draw X through the center to indicate this is a hole
		var max_size = max(size.x, size.y) * 0.3
		hole_lines.push_back(Vector3(-max_size, 0.5, -max_size))
		hole_lines.push_back(Vector3(max_size, 0.5, max_size))
		hole_lines.push_back(Vector3(-max_size, 0.5, max_size))
		hole_lines.push_back(Vector3(max_size, 0.5, -max_size))
		
		# Draw bevel width indicator if beveled
		if hole_node.edge_type == HoleNode.EdgeType.BEVELED and hole_node.edge_bevel_width > 0:
			var bevel = hole_node.edge_bevel_width
			var bevel_lines = PackedVector3Array()
			match node.influence_shape:
				TerrainFeatureNode.InfluenceShape.CIRCLE:
					var circle_radius = max(size.x, size.y) * 0.5
					_draw_circle(bevel_lines, circle_radius - bevel, segments)
				TerrainFeatureNode.InfluenceShape.RECTANGLE:
					_draw_rectangle(bevel_lines, size - Vector2(bevel * 2, bevel * 2))
				TerrainFeatureNode.InfluenceShape.ELLIPSE:
					_draw_ellipse(bevel_lines, size * 0.5 - Vector2(bevel, bevel), segments)
			gizmo.add_lines(bevel_lines, get_material("falloff", gizmo))
	
	# Draw direction arrow for gradient and landscape nodes
	var has_direction = false
	var dir_handle: GizmoHandle = null
	for h in handles:
		if h.handle_type == GizmoHandle.HandleType.DIRECTION:
			has_direction = true
			dir_handle = h
			break
	
	if has_direction and dir_handle != null:
		var dir_3d = dir_handle.local_position.normalized()
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
	
	# Draw height visualization for primitives and landscapes
	var has_height = false
	var height_val = 0.0
	for h in handles:
		if h.handle_type == GizmoHandle.HandleType.HEIGHT:
			has_height = true
			height_val = h.local_position.y
			break
	
	if has_height:
		height_lines.push_back(Vector3.ZERO)
		height_lines.push_back(Vector3(0, height_val, 0))
		
		# Add a small horizontal indicator at the height level
		height_lines.push_back(Vector3(-5, height_val, 0))
		height_lines.push_back(Vector3(5, height_val, 0))
		height_lines.push_back(Vector3(0, height_val, -5))
		height_lines.push_back(Vector3(0, height_val, 5))
	
	# For gradient nodes, draw both start and end height
	var start_handle: GizmoHandle = null
	var end_handle: GizmoHandle = null
	for h in handles:
		if h.handle_type == GizmoHandle.HandleType.START_HEIGHT:
			start_handle = h
		elif h.handle_type == GizmoHandle.HandleType.END_HEIGHT:
			end_handle = h
	
	if start_handle != null and end_handle != null:
		var start_h = start_handle.local_position.y
		var end_h = end_handle.local_position.y
		var back_pos = Vector3(start_handle.local_position.x, 0, start_handle.local_position.z)
		var front_pos = Vector3(end_handle.local_position.x, 0, end_handle.local_position.z)
		
		height_lines.push_back(back_pos)
		height_lines.push_back(back_pos + Vector3(0, start_h, 0))
		
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
	if hole_lines.size() > 0:
		gizmo.add_lines(hole_lines, get_material("hole", gizmo))
	
	# Add handles
	# Note: add_handles() always tries to create a handle-sphere mesh and assign a
	# material to it. Calling it with empty position arrays raises
	# "Index p_idx = 0 is out of bounds (surfaces.size() = 0)" from
	# surface_set_material — so skip the call entirely when there are no handles.
	if handles.size() > 0:
		var handle_positions = PackedVector3Array()
		var handle_ids = PackedInt32Array()
		for i in handles.size():
			handle_positions.push_back(handles[i].local_position)
			handle_ids.push_back(i)
		gizmo.add_handles(handle_positions, get_material("handles", gizmo), handle_ids)

func _get_handle_name(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> String:
	var node = gizmo.get_node_3d() as TerrainFeatureNode
	if not node:
		return ""
	
	var handles = node._get_gizmo_handles()
	if handle_id < 0 or handle_id >= handles.size():
		return ""
	return handles[handle_id].name

func _get_handle_value(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> Variant:
	var node = gizmo.get_node_3d() as TerrainFeatureNode
	if not node:
		return null
	
	var handles = node._get_gizmo_handles()
	if handle_id < 0 or handle_id >= handles.size():
		return null
	
	var handle = handles[handle_id]
	
	match handle.handle_type:
		GizmoHandle.HandleType.SIZE_X:
			return node.influence_size.x
		GizmoHandle.HandleType.SIZE_Y:
			return node.influence_size.y
		GizmoHandle.HandleType.FALLOFF:
			return node.edge_falloff
		GizmoHandle.HandleType.HEIGHT:
			if node is PrimitiveNode:
				return (node as PrimitiveNode).height
			elif node is LandscapeNode:
				return (node as LandscapeNode).height
		GizmoHandle.HandleType.START_HEIGHT:
			return (node as GradientNode).start_height
		GizmoHandle.HandleType.END_HEIGHT:
			return (node as GradientNode).end_height
		GizmoHandle.HandleType.DIRECTION:
			return node.get_direction()
	
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
	
	var handles = node._get_gizmo_handles()
	if handle_id < 0 or handle_id >= handles.size():
		return
	
	var handle = handles[handle_id]
	
	match handle.handle_type:
		GizmoHandle.HandleType.SIZE_X:
			var plane = Plane(Vector3.UP, 0)
			var intersection = plane.intersects_ray(ray_from, ray_dir)
			if intersection != null:
				var local_intersection = node.to_local(intersection)
				if node.influence_shape == TerrainFeatureNode.InfluenceShape.CIRCLE:
					var new_radius = max(1.0, abs(local_intersection.x))
					node.influence_size = Vector2(new_radius * 2.0, new_radius * 2.0)
				else:
					var new_size_x = max(1.0, abs(local_intersection.x) * 2.0)
					node.influence_size.x = new_size_x
			_redraw(gizmo)
			return
		
		GizmoHandle.HandleType.SIZE_Y:
			var plane = Plane(Vector3.UP, 0)
			var intersection = plane.intersects_ray(ray_from, ray_dir)
			if intersection != null:
				var local_intersection = node.to_local(intersection)
				node.influence_size.y = max(1.0, abs(local_intersection.z) * 2.0)
			_redraw(gizmo)
			return
		
		GizmoHandle.HandleType.FALLOFF:
			var plane = Plane(Vector3.UP, 0)
			var intersection = plane.intersects_ray(ray_from, ray_dir)
			if intersection != null:
				var local_intersection = node.to_local(intersection)
				var distance = Vector2(local_intersection.x, local_intersection.z).length()
				var max_size = max(node.influence_size.x, node.influence_size.y) * 0.5
				var new_falloff_radius = max(0.1, distance)
				node.edge_falloff = clamp(1.0 - (new_falloff_radius / max_size), 0.0, 1.0)
			_redraw(gizmo)
			return
		
		GizmoHandle.HandleType.HEIGHT:
			var node_pos = node.global_position
			var vertical_plane = Plane(Vector3.RIGHT, node_pos)
			var vertical_intersection = vertical_plane.intersects_ray(ray_from, ray_dir)
			if vertical_intersection != null:
				var local_y = node.to_local(vertical_intersection).y
				if node is PrimitiveNode:
					(node as PrimitiveNode).height = local_y
				elif node is LandscapeNode:
					(node as LandscapeNode).height = local_y
			_redraw(gizmo)
			return
		
		GizmoHandle.HandleType.START_HEIGHT:
			var back_pos = Vector3(handle.local_position.x, 0, handle.local_position.z)
			var back_pos_global = node.to_global(back_pos)
			var vertical_plane = Plane(Vector3.RIGHT, back_pos_global)
			var has_dir = false
			for h in handles:
				if h.handle_type == GizmoHandle.HandleType.DIRECTION:
					has_dir = true
					break
			if has_dir:
				var dir = node.get_direction()
				var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
				vertical_plane = Plane(Vector3.RIGHT.rotated(Vector3.UP, atan2(dir_3d.z, dir_3d.x)), back_pos_global)
			var vertical_intersection = vertical_plane.intersects_ray(ray_from, ray_dir)
			if vertical_intersection != null:
				var local_y = node.to_local(vertical_intersection).y
				(node as GradientNode).start_height = local_y
			_redraw(gizmo)
			return
		
		GizmoHandle.HandleType.END_HEIGHT:
			var front_pos = Vector3(handle.local_position.x, 0, handle.local_position.z)
			var front_pos_global = node.to_global(front_pos)
			var vertical_plane = Plane(Vector3.RIGHT, front_pos_global)
			var has_dir = false
			for h in handles:
				if h.handle_type == GizmoHandle.HandleType.DIRECTION:
					has_dir = true
					break
			if has_dir:
				var dir = node.get_direction()
				var dir_3d = Vector3(dir.x, 0, dir.y).normalized()
				vertical_plane = Plane(Vector3.RIGHT.rotated(Vector3.UP, atan2(dir_3d.z, dir_3d.x)), front_pos_global)
			var vertical_intersection = vertical_plane.intersects_ray(ray_from, ray_dir)
			if vertical_intersection != null:
				var local_y = node.to_local(vertical_intersection).y
				(node as GradientNode).end_height = local_y
			_redraw(gizmo)
			return
		
		GizmoHandle.HandleType.DIRECTION:
			var plane = Plane(Vector3.UP, 0)
			var intersection = plane.intersects_ray(ray_from, ray_dir)
			if intersection != null:
				var local_intersection = node.to_local(intersection)
				var dir_2d = Vector2(local_intersection.x, local_intersection.z)
				if dir_2d.length() > 0.1:
					if node is LandscapeNode:
						(node as LandscapeNode).direction = dir_2d.normalized()
					elif node is LinearGradientNode:
						(node as LinearGradientNode).direction = dir_2d.normalized()
			_redraw(gizmo)
			return

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
		if was_manipulating:
			node._commit_parameter_change()
		return
	
	var handles = node._get_gizmo_handles()
	if handle_id < 0 or handle_id >= handles.size():
		return
	
	var handle = handles[handle_id]
	
	match handle.handle_type:
		GizmoHandle.HandleType.SIZE_X:
			if cancel:
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
		
		GizmoHandle.HandleType.SIZE_Y:
			if cancel:
				node.influence_size.y = restore
			else:
				undo_redo.create_action("Change Influence Depth")
				undo_redo.add_do_property(node, "influence_size", node.influence_size)
				undo_redo.add_undo_property(node, "influence_size", Vector2(node.influence_size.x, restore))
				undo_redo.commit_action()
			if was_manipulating:
				node._commit_parameter_change()
			return
		
		GizmoHandle.HandleType.FALLOFF:
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
		
		GizmoHandle.HandleType.HEIGHT:
			if cancel:
				if node is PrimitiveNode:
					(node as PrimitiveNode).height = restore
				elif node is LandscapeNode:
					(node as LandscapeNode).height = restore
			else:
				undo_redo.create_action("Change Height")
				if node is PrimitiveNode:
					var n = node as PrimitiveNode
					undo_redo.add_do_property(n, "height", n.height)
					undo_redo.add_undo_property(n, "height", restore)
				elif node is LandscapeNode:
					var n = node as LandscapeNode
					undo_redo.add_do_property(n, "height", n.height)
					undo_redo.add_undo_property(n, "height", restore)
				undo_redo.commit_action()
			if was_manipulating:
				node._commit_parameter_change()
			return
		
		GizmoHandle.HandleType.START_HEIGHT:
			if cancel:
				(node as GradientNode).start_height = restore
			else:
				var n = node as GradientNode
				undo_redo.create_action("Change Start Height")
				undo_redo.add_do_property(n, "start_height", n.start_height)
				undo_redo.add_undo_property(n, "start_height", restore)
				undo_redo.commit_action()
			if was_manipulating:
				node._commit_parameter_change()
			return
		
		GizmoHandle.HandleType.END_HEIGHT:
			if cancel:
				(node as GradientNode).end_height = restore
			else:
				var n = node as GradientNode
				undo_redo.create_action("Change End Height")
				undo_redo.add_do_property(n, "end_height", n.end_height)
				undo_redo.add_undo_property(n, "end_height", restore)
				undo_redo.commit_action()
			if was_manipulating:
				node._commit_parameter_change()
			return
		
		GizmoHandle.HandleType.DIRECTION:
			if cancel:
				if node is LandscapeNode:
					(node as LandscapeNode).direction = restore
				elif node is LinearGradientNode:
					(node as LinearGradientNode).direction = restore
			else:
				undo_redo.create_action("Change Direction")
				if node is LandscapeNode:
					var n = node as LandscapeNode
					undo_redo.add_do_property(n, "direction", n.direction)
					undo_redo.add_undo_property(n, "direction", restore)
				elif node is LinearGradientNode:
					var n = node as LinearGradientNode
					undo_redo.add_do_property(n, "direction", n.direction)
					undo_redo.add_undo_property(n, "direction", restore)
				undo_redo.commit_action()
			if was_manipulating:
				node.parameters_changed.emit()
			return

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
