@tool
extends EditorPlugin

## Terrainy 2 editor host: toolbar (rebuild / bake / brush), brush tool input forwarding,
## paint layers dock, add-node gallery, field gizmos, config snapshots, paint persistence on
## scene save, the paint resample prompt and the `.tpaint` resource format.
##
## Node types are global classes (class_name), so no add_custom_type() list has to be kept in
## sync; the gallery dock and the Create Node dialog both see every type.

const GizmoPlugin = preload("res://addons/terrainy/editor/gizmos/field_gizmo_plugin.gd")
const BrushTool = preload("res://addons/terrainy/editor/brush/brush_tool.gd")
const PaintDock = preload("res://addons/terrainy/editor/panel/paint_dock.gd")
const GalleryDock = preload("res://addons/terrainy/editor/panel/gallery_dock.gd")
const ContextMenu = preload("res://addons/terrainy/editor/context_menu.gd")
const PaintBundleFormat = preload("res://addons/terrainy/paint_bundle_format.gd")

## Autoload that registers the `.tpaint` format outside the editor too. A scene's bundle is a
## resource dependency, so an exported build has to be able to load it; the autoload runs before
## the main scene does.
const FORMAT_AUTOLOAD_NAME := "TerrainyPaintBundleFormat"
const FORMAT_AUTOLOAD_PATH := "res://addons/terrainy/paint_bundle_format.gd"

var _gizmos: EditorNode3DGizmoPlugin
var _brush = null
var _paint_dock: Control
var _gallery_dock: Control
var _context_menu: EditorContextMenuPlugin
var _toolbar: HBoxContainer
var _rebuild_button: Button
var _bake_button: Button
var _brush_button: Button
var _bake_dialog: FileDialog
var _resample_dialog: ConfirmationDialog
var _resample_interp: OptionButton
var _resample_generator: TerrainGenerator = null
var _generator: TerrainGenerator = null

## Install the format autoload when the plugin is switched on. `_enable_plugin` / `_disable_plugin`
## are only called on a project-settings toggle (not on editor start/stop), so this writes
## `project.godot` once instead of on every editor session.
func _enable_plugin() -> void:
	add_autoload_singleton(FORMAT_AUTOLOAD_NAME, FORMAT_AUTOLOAD_PATH)

func _disable_plugin() -> void:
	remove_autoload_singleton(FORMAT_AUTOLOAD_NAME)

func _enter_tree() -> void:
	# Register now so this editor session recognizes `.tpaint` without a restart; the autoload
	# (idempotent) covers exported builds and the next editor start.
	PaintBundleFormat.register()

	_gizmos = GizmoPlugin.new()
	_gizmos.undo_redo = get_undo_redo()
	add_node_3d_gizmo_plugin(_gizmos)

	_brush = BrushTool.new()
	_brush.undo_redo = get_undo_redo()
	_brush.changed.connect(_on_brush_changed)

	_paint_dock = PaintDock.new()
	_paint_dock.setup(_brush, get_undo_redo())
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _paint_dock)
	_gallery_dock = GalleryDock.new()
	_gallery_dock.setup(get_undo_redo())
	add_control_to_dock(DOCK_SLOT_LEFT_UR, _gallery_dock)

	_context_menu = ContextMenu.new()
	_context_menu.on_saved = _gallery_dock.refresh_configs
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _context_menu)

	_toolbar = HBoxContainer.new()
	_rebuild_button = Button.new()
	_rebuild_button.text = "Rebuild Terrain"
	_rebuild_button.pressed.connect(func(): if _generator: _generator.force_rebuild())
	_toolbar.add_child(_rebuild_button)
	_bake_button = Button.new()
	_bake_button.text = "Bake to Scene"
	_bake_button.pressed.connect(_on_bake_pressed)
	_toolbar.add_child(_bake_button)
	_brush_button = Button.new()
	_brush_button.text = "Brush"
	_brush_button.toggle_mode = true
	_brush_button.icon = load("res://addons/terrainy/icons/brush.svg")
	_brush_button.tooltip_text = "Toggle the paint brush (pick the op in the Terrainy Paint dock)"
	_brush_button.toggled.connect(_on_brush_toggled)
	_toolbar.add_child(_brush_button)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.visible = false

	_bake_dialog = FileDialog.new()
	_bake_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_bake_dialog.access = FileDialog.ACCESS_RESOURCES
	_bake_dialog.filters = PackedStringArray(["*.tscn ; Scene", "*.scn ; Binary scene"])
	_bake_dialog.file_selected.connect(_on_bake_path)
	EditorInterface.get_base_control().add_child(_bake_dialog)

	_resample_dialog = ConfirmationDialog.new()
	_resample_dialog.title = "Resample paint layers"
	var box := VBoxContainer.new()
	var info := Label.new()
	info.text = "The terrain size / paint grid changed while paint layers hold data.\nResample them so strokes keep their world position?"
	box.add_child(info)
	_resample_interp = OptionButton.new()
	_resample_interp.add_item("Bilinear (default)", 0)
	_resample_interp.add_item("Nearest", 1)
	box.add_child(_resample_interp)
	_resample_dialog.add_child(box)
	_resample_dialog.ok_button_text = "Resample"
	_resample_dialog.confirmed.connect(_on_resample_confirmed)
	_resample_dialog.canceled.connect(_on_resample_canceled)
	EditorInterface.get_base_control().add_child(_resample_dialog)

	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	get_tree().node_added.connect(_on_node_added)
	_hook_all_generators()

func _exit_tree() -> void:
	if EditorInterface.get_selection().selection_changed.is_connected(_on_selection_changed):
		EditorInterface.get_selection().selection_changed.disconnect(_on_selection_changed)
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	remove_node_3d_gizmo_plugin(_gizmos)
	remove_context_menu_plugin(_context_menu)
	remove_control_from_docks(_paint_dock)
	remove_control_from_docks(_gallery_dock)
	_paint_dock.queue_free()
	_gallery_dock.queue_free()
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.queue_free()
	_bake_dialog.queue_free()
	_resample_dialog.queue_free()

func _get_plugin_name() -> String:
	return "Terrainy 2"

# --- Selection / editing --------------------------------------------------------------------

func _handles(object: Object) -> bool:
	return object is TerrainGenerator or (object is Node and _find_generator(object) != null)

func _edit(object: Object) -> void:
	_set_generator(_find_generator(object) if object is Node else null)

func _make_visible(visible: bool) -> void:
	_toolbar.visible = visible
	if not visible and _brush:
		_brush_button.button_pressed = false

static func _find_generator(node: Node) -> TerrainGenerator:
	while node != null:
		if node is TerrainGenerator:
			return node
		node = node.get_parent()
	return null

func _on_selection_changed() -> void:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	_set_generator(_find_generator(nodes[0]) if not nodes.is_empty() else null)

func _set_generator(gen: TerrainGenerator) -> void:
	if gen == _generator:
		return
	_generator = gen
	_paint_dock.set_generator(gen)
	_toolbar.visible = gen != null

func _on_brush_toggled(on: bool) -> void:
	if not on:
		_brush.op = -1
	elif _brush.op < 0:
		_brush.op = 0
	_paint_dock._sync_from_brush()
	update_overlays()

func _on_brush_changed() -> void:
	_brush_button.set_pressed_no_signal(_brush.op >= 0)
	update_overlays()

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if _brush == null or not _brush.is_active():
		return AFTER_GUI_INPUT_PASS
	var consumed: bool = _brush.handle_input(camera, event)
	if event is InputEventMouseMotion or consumed:
		update_overlays()
	return AFTER_GUI_INPUT_STOP if consumed else AFTER_GUI_INPUT_PASS

func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if _brush == null or not _brush.is_active():
		return
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	var camera := viewport.get_camera_3d() if viewport else null
	if camera:
		_brush.draw_overlay(overlay, camera)

# --- Bake -----------------------------------------------------------------------------------

func _on_bake_pressed() -> void:
	if _generator == null:
		return
	_bake_dialog.current_file = "%s_baked.tscn" % _generator.name
	_bake_dialog.popup_centered_ratio(0.6)

func _on_bake_path(path: String) -> void:
	if _generator == null:
		return
	_generator.rebuild_now()
	var err := _generator.bake_to_scene(path)
	if err == OK:
		print("[terrainy] Baked terrain saved to %s" % path)
		EditorInterface.get_resource_filesystem().scan()
	else:
		push_error("[terrainy] Bake failed (error %d)" % err)

# --- Paint persistence + resample prompt ----------------------------------------------------

func _hook_all_generators() -> void:
	for gen in _generators_in(EditorInterface.get_edited_scene_root()):
		_hook_generator(gen)

static func _generators_in(node: Node, out: Array = []) -> Array:
	if node == null:
		return out
	if node is TerrainGenerator:
		out.append(node)
	for child in node.get_children():
		_generators_in(child, out)
	return out

func _on_node_added(node: Node) -> void:
	if node is TerrainGenerator:
		_hook_generator(node)

func _hook_generator(gen: TerrainGenerator) -> void:
	var cb := _on_resample_requested.bind(gen)
	if not gen.paint_resample_requested.is_connected(cb):
		gen.paint_resample_requested.connect(cb)

func _on_resample_requested(_old_size: float, _new_size: float, _old_grid: int, _new_grid: int, gen: TerrainGenerator) -> void:
	_resample_generator = gen
	_resample_dialog.popup_centered()

func _on_resample_confirmed() -> void:
	var gen := _resample_generator
	if gen and is_instance_valid(gen):
		gen.resample_pending_paint_layers(_resample_interp.get_selected_id())

func _on_resample_canceled() -> void:
	var gen := _resample_generator
	if gen and is_instance_valid(gen):
		gen.cancel_paint_resample()

## Scene save: write every generator's paint into the scene's bundle (atomic, one file).
func _save_external_data() -> void:
	for gen in _generators_in(EditorInterface.get_edited_scene_root()):
		var err: Error = gen.save_paint()
		if err != OK and err != ERR_UNCONFIGURED:
			push_error("[terrainy] Could not save paint bundle for %s at %s (error %d)" % [
				gen.name, gen.resolve_paint_bundle_path(), err])
