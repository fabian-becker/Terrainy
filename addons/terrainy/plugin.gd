@tool
extends EditorPlugin

var rebuild_button: Button
# var gizmo_toggle_button: CheckButton
var current_terrain_composer: Node3D
var terrain_gizmo_plugin: EditorNode3DGizmoPlugin
var _editor_selection: EditorSelection

func _enter_tree() -> void:
	# Add rebuild coordinator autoload
	add_autoload_singleton("TerrainRebuildCoordinator", "res://addons/terrainy/helpers/terrain_rebuild_coordinator.gd")
	
	# Add custom node types
	add_custom_type(
		"TerrainComposer",
		"Node3D",
		preload("res://addons/terrainy/nodes/terrain_composer.gd"),
		preload("res://addons/terrainy/icons/terrain_composer.svg")
	)
	add_custom_type(
		"TerrainFeatureNode",
		"Node3D",
		preload("res://addons/terrainy/nodes/terrain_feature_node.gd"),
		preload("res://addons/terrainy/icons/terrain_feature.svg")
	)
	
	# Base classes
	add_custom_type("PrimitiveNode", "Node3D", preload("res://addons/terrainy/nodes/primitives/primitive_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("GradientNode", "Node3D", preload("res://addons/terrainy/nodes/gradients/gradient_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("LandscapeNode", "Node3D", preload("res://addons/terrainy/nodes/landscapes/landscape_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("NoiseNode", "Node3D", preload("res://addons/terrainy/nodes/noise/noise_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	
	# Gradients
	add_custom_type("RadialGradientNode", "Node3D", preload("res://addons/terrainy/nodes/gradients/radial_gradient_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("LinearGradientNode", "Node3D", preload("res://addons/terrainy/nodes/gradients/linear_gradient_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("ConeNode", "Node3D", preload("res://addons/terrainy/nodes/gradients/cone_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("HemisphereNode", "Node3D", preload("res://addons/terrainy/nodes/gradients/hemisphere_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	
	# Primitives
	add_custom_type("HillNode", "Node3D", preload("res://addons/terrainy/nodes/primitives/hill_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("MountainNode", "Node3D", preload("res://addons/terrainy/nodes/primitives/mountain_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("CraterNode", "Node3D", preload("res://addons/terrainy/nodes/primitives/crater_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("VolcanoNode", "Node3D", preload("res://addons/terrainy/nodes/primitives/volcano_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("IslandNode", "Node3D", preload("res://addons/terrainy/nodes/primitives/island_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	
	# Landscapes
	add_custom_type("CanyonNode", "Node3D", preload("res://addons/terrainy/nodes/landscapes/canyon_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("MountainRangeNode", "Node3D", preload("res://addons/terrainy/nodes/landscapes/mountain_range_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("DuneSeaNode", "Node3D", preload("res://addons/terrainy/nodes/landscapes/dune_sea_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	
	# Noise
	add_custom_type("PerlinNoiseNode", "Node3D", preload("res://addons/terrainy/nodes/noise/perlin_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("VoronoiNode", "Node3D", preload("res://addons/terrainy/nodes/noise/voronoi_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	
	# Utility nodes
	add_custom_type("ShapeNode", "Node3D", preload("res://addons/terrainy/nodes/basic/shape_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	add_custom_type("HeightmapNode", "Node3D", preload("res://addons/terrainy/nodes/basic/heightmap_node.gd"), preload("res://addons/terrainy/icons/terrain_feature.svg"))
	
	# Add gizmo plugin
	terrain_gizmo_plugin = preload("res://addons/terrainy/gizmos/terrain_feature_gizmo_plugin.gd").new()
	terrain_gizmo_plugin.undo_redo = get_undo_redo()
	add_node_3d_gizmo_plugin(terrain_gizmo_plugin)
	
	# Refresh gizmos for existing nodes after a short delay
	call_deferred("_refresh_existing_gizmos")

	# Track editor selection changes to prevent stuck gizmo states
	_editor_selection = get_editor_interface().get_selection()
	if _editor_selection and not _editor_selection.selection_changed.is_connected(_on_selection_changed):
		_editor_selection.selection_changed.connect(_on_selection_changed)
	
	# Create toolbar buttons
	rebuild_button = Button.new()
	rebuild_button.text = "Rebuild Terrain"
	rebuild_button.pressed.connect(_on_rebuild_pressed)
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, rebuild_button)
	
	# gizmo_toggle_button = CheckButton.new()
	# gizmo_toggle_button.text = "Show Gizmos"
	# # Restore previous state from plugin settings
	# var saved_state = get_editor_interface().get_editor_settings().get_setting("terrainy/show_gizmos")
	# if saved_state != null:
	# 	gizmo_toggle_button.button_pressed = saved_state
	# 	terrain_gizmo_plugin.show_gizmos = saved_state
	# else:
	# 	gizmo_toggle_button.button_pressed = true
	# gizmo_toggle_button.toggled.connect(_on_gizmo_toggle)
	# add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, gizmo_toggle_button)
	
	# Check for terrain composers periodically
	get_tree().node_added.connect(_on_node_changed)
	get_tree().node_removed.connect(_on_node_changed)
	_update_button_visibility()

func _exit_tree() -> void:
	# Remove autoload singleton
	remove_autoload_singleton("TerrainRebuildCoordinator")
	
	# Clear gizmos from all nodes before removing the plugin
	var edited_scene_root = get_tree().edited_scene_root
	if edited_scene_root:
		_clear_all_gizmos(edited_scene_root)
	
	# Clean up
	if rebuild_button:
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, rebuild_button)
		rebuild_button.queue_free()
	
	# if gizmo_toggle_button:
	# 	remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, gizmo_toggle_button)
	# 	gizmo_toggle_button.queue_free()
	
	if terrain_gizmo_plugin:
		remove_node_3d_gizmo_plugin(terrain_gizmo_plugin)

	if _editor_selection and _editor_selection.selection_changed.is_connected(_on_selection_changed):
		_editor_selection.selection_changed.disconnect(_on_selection_changed)
	
	if get_tree().node_added.is_connected(_on_node_changed):
		get_tree().node_added.disconnect(_on_node_changed)
	if get_tree().node_removed.is_connected(_on_node_changed):
		get_tree().node_removed.disconnect(_on_node_changed)
	
	# Remove all custom types
	remove_custom_type("TerrainComposer")
	remove_custom_type("TerrainFeatureNode")
	
	# Base classes
	remove_custom_type("PrimitiveNode")
	remove_custom_type("GradientNode")
	remove_custom_type("LandscapeNode")
	remove_custom_type("NoiseNode")
	
	# Gradients
	remove_custom_type("RadialGradientNode")
	remove_custom_type("LinearGradientNode")
	remove_custom_type("ConeNode")
	remove_custom_type("HemisphereNode")
	
	# Primitives
	remove_custom_type("HillNode")
	remove_custom_type("MountainNode")
	remove_custom_type("CraterNode")
	remove_custom_type("VolcanoNode")
	remove_custom_type("IslandNode")
	
	# Landscapes
	remove_custom_type("CanyonNode")
	remove_custom_type("MountainRangeNode")
	remove_custom_type("DuneSeaNode")
	
	# Noise
	remove_custom_type("PerlinNoiseNode")
	remove_custom_type("VoronoiNode")
	
	# Utility
	remove_custom_type("ShapeNode")
	remove_custom_type("HeightmapNode")

func _handles(object: Object) -> bool:
	return object is Node3D and object.get_script() == preload("res://addons/terrainy/nodes/terrain_composer.gd")

func _edit(object: Object) -> void:
	if object and _handles(object):
		current_terrain_composer = object
	else:
		current_terrain_composer = null

func _on_node_changed(_node: Node) -> void:
	_update_button_visibility()

func _update_button_visibility() -> void:
	if not rebuild_button:
		return
	
	var has_terrain_composer = _find_terrain_composer_in_tree() != null
	rebuild_button.visible = has_terrain_composer

func _find_terrain_composer_in_tree() -> Node3D:
	var edited_scene_root = get_tree().edited_scene_root
	if not edited_scene_root:
		return null
	
	return _find_terrain_composer_recursive(edited_scene_root)

func _find_terrain_composer_recursive(node: Node) -> Node3D:
	if _handles(node):
		return node
	
	for child in node.get_children():
		var result = _find_terrain_composer_recursive(child)
		if result:
			return result
	
	return null

func _on_rebuild_pressed() -> void:
	print("[Terrainy] Rebuild Terrain button pressed")
	
	# Check if Shift is held - if so, rebuild ALL terrain composers
	var input = Input
	if input.is_key_pressed(KEY_SHIFT):
		_rebuild_all_terrain_composers()
		return
	
	# Otherwise, rebuild the selected terrain composer, or find one in the tree
	var target = current_terrain_composer
	if not target or not is_instance_valid(target):
		target = _find_terrain_composer_in_tree()
	
	if target and is_instance_valid(target):
		# Force a complete rebuild with all caches cleared
		target.force_rebuild()

func _rebuild_all_terrain_composers() -> void:
	var edited_scene_root = get_tree().edited_scene_root
	if not edited_scene_root:
		return
	
	var composers: Array[Node] = []
	_find_all_terrain_composers(edited_scene_root, composers)
	
	if composers.is_empty():
		print("[Terrainy] No TerrainComposers found in scene")
		return
	
	print("[Terrainy] Rebuilding %d TerrainComposer(s)..." % composers.size())
	for composer in composers:
		if is_instance_valid(composer):
			composer.force_rebuild()

func _find_all_terrain_composers(node: Node, result: Array[Node]) -> void:
	if _handles(node):
		result.append(node)
	
	for child in node.get_children():
		_find_all_terrain_composers(child, result)

func _on_gizmo_toggle(enabled: bool) -> void:
	if terrain_gizmo_plugin:
		terrain_gizmo_plugin.show_gizmos = enabled
		# Save state to editor settings
		get_editor_interface().get_editor_settings().set_setting("terrainy/show_gizmos", enabled)
		# Force redraw of all gizmos
		update_overlays()

func _on_selection_changed() -> void:
	var edited_scene_root = get_tree().edited_scene_root
	if not edited_scene_root:
		return
	var changed = _clear_stuck_gizmo_flags(edited_scene_root)
	if changed:
		update_overlays()

func _refresh_existing_gizmos() -> void:
	# Update gizmos without reloading the scene
	var editor_interface = get_editor_interface()
	var current_scene = editor_interface.get_edited_scene_root()
	if current_scene:
		# Update all terrain feature nodes
		_update_gizmos_recursive(current_scene)
	update_overlays()

func _update_gizmos_recursive(node: Node) -> void:
	if _is_terrain_feature_node(node):
		# Force gizmo update
		node.update_gizmos()
	
	for child in node.get_children():
		_update_gizmos_recursive(child)

func _clear_stuck_gizmo_flags(node: Node) -> bool:
	var changed = false
	if _is_terrain_feature_node(node):
		if node.get_meta("_gizmo_manipulating", false):
			node.set_meta("_gizmo_manipulating", false)
			node.remove_meta("_gizmo_manipulation_time")
			if node.has_signal("parameters_changed"):
				node.parameters_changed.emit()
			node.update_gizmos()
			changed = true

	for child in node.get_children():
		if _clear_stuck_gizmo_flags(child):
			changed = true

	return changed

func _is_terrain_feature_node(node: Node) -> bool:
	if not (node is Node3D):
		return false
	var script = node.get_script()
	if not script:
		return false
	var base_script = script.get_base_script()
	while base_script:
		if base_script.resource_path == "res://addons/terrainy/nodes/terrain_feature_node.gd":
			return true
		base_script = base_script.get_base_script()
	# Also check if the script itself is TerrainFeatureNode
	return script.resource_path == "res://addons/terrainy/nodes/terrain_feature_node.gd"

func _clear_all_gizmos(node: Node) -> void:
	# Recursively clear gizmos from terrain feature nodes
	if node is Node3D:
		var script = node.get_script()
		if script:
			var base_script = script.get_base_script()
			while base_script:
				if base_script.resource_path == "res://addons/terrainy/nodes/terrain_feature_node.gd":
					# Clear all gizmos from this node
					# The node will request new gizmos on next update
					if node.has_method("set_gizmo"):
						node.set_gizmo(null)
					break
				base_script = base_script.get_base_script()
	
	for child in node.get_children():
		_clear_all_gizmos(child)

func _make_visible(visible: bool) -> void:
	_update_button_visibility()
