@tool
extends EditorContextMenuPlugin

## Scene tree context menu: "Save Terrainy Configuration" (user config snapshots) and
## "Isolate Preview".

const GalleryDock = preload("res://addons/terrainy/editor/panel/gallery_dock.gd")

var on_saved: Callable = Callable()

func _popup_menu(paths: PackedStringArray) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or paths.size() != 1:
		return
	var node := root.get_node_or_null(paths[0])
	if node is TerrainComposableNode:
		add_context_menu_item("Save Terrainy Configuration", _save)
		add_context_menu_item("Isolate Terrain Preview", _isolate)

func _save(nodes: Array) -> void:
	if nodes.is_empty():
		return
	var err := GalleryDock.save_config(nodes[0], String(nodes[0].name))
	if err == OK:
		print("[terrainy] Saved configuration '%s' to %s" % [nodes[0].name, GalleryDock.CONFIG_DIR])
	if on_saved.is_valid():
		on_saved.call()

func _isolate(nodes: Array) -> void:
	if nodes.is_empty():
		return
	var node: Node = nodes[0]
	var gen := node.get_parent()
	while gen and not (gen is TerrainGenerator):
		gen = gen.get_parent()
	if gen:
		gen.preview_isolate_node = null if gen.preview_isolate_node == node else node
