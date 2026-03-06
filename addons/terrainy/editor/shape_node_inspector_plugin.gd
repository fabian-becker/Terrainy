@tool
class_name ShapeNodeInspectorPlugin
extends EditorInspectorPlugin

const ShapeMaskEditorDialog = preload("res://addons/terrainy/editor/shape_mask_editor_dialog.gd")

var host_plugin: EditorPlugin = null
var _dialog: ShapeMaskEditorDialog = null

func _can_handle(object: Object) -> bool:
	return object is ShapeNode

func _parse_begin(object: Object) -> void:
	if host_plugin == null:
		return
	var node = object as ShapeNode
	if node == null:
		return
	var button = Button.new()
	button.text = "Edit Shape Mask"
	button.pressed.connect(_on_edit_pressed.bind(node))
	add_custom_control(button)

func _on_edit_pressed(node: ShapeNode) -> void:
	if host_plugin == null or node == null:
		return
	if _dialog == null:
		_dialog = ShapeMaskEditorDialog.new()
		host_plugin.get_editor_interface().get_base_control().add_child(_dialog)
	_dialog.edit_shape(node, host_plugin.get_undo_redo())
