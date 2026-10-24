@tool
extends VBoxContainer

## Add-node gallery: every shipped Terrainy 2 node, the isolate preview and the user's own
## configuration snapshots (small `.tscn` files in res://terrainy_configs/). No shipped shape
## presets: shape knowledge lives in docs/terrainy2/recipes.md.

const CONFIG_DIR := "res://terrainy_configs"

var undo_redo: EditorUndoRedoManager = null
var _configs: ItemList
var _config_name: LineEdit

func _init() -> void:
	name = "Terrainy Nodes"
	custom_minimum_size = Vector2(220, 0)

func setup(p_undo: EditorUndoRedoManager) -> void:
	undo_redo = p_undo
	var hint := Label.new()
	hint.text = "Adds under the selected node"
	add_child(hint)
	var grid := GridContainer.new()
	grid.columns = 2
	add_child(grid)
	for entry in _entries():
		var b := Button.new()
		b.text = entry[0]
		b.tooltip_text = entry[2]
		b.pressed.connect(_add.bind(entry[1]))
		grid.add_child(b)
	add_child(HSeparator.new())
	var iso := HBoxContainer.new()
	add_child(iso)
	var isolate := Button.new()
	isolate.text = "Isolate selected"
	isolate.pressed.connect(_isolate.bind(true))
	iso.add_child(isolate)
	var clear := Button.new()
	clear.text = "Clear isolation"
	clear.pressed.connect(_isolate.bind(false))
	iso.add_child(clear)
	add_child(HSeparator.new())
	var cl := Label.new()
	cl.text = "My configurations"
	add_child(cl)
	var save_row := HBoxContainer.new()
	add_child(save_row)
	_config_name = LineEdit.new()
	_config_name.placeholder_text = "name"
	_config_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_row.add_child(_config_name)
	var save := Button.new()
	save.text = "Save selected"
	save.pressed.connect(func(): save_selected_config(_config_name.text))
	save_row.add_child(save)
	_configs = ItemList.new()
	_configs.custom_minimum_size = Vector2(0, 100)
	_configs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_configs.item_activated.connect(func(_i): _insert_config())
	add_child(_configs)
	var insert := Button.new()
	insert.text = "Insert configuration"
	insert.pressed.connect(_insert_config)
	add_child(insert)
	refresh_configs()

func _entries() -> Array:
	return [
		["Generator", "generator", "TerrainGenerator root"],
		["Field (Region)", "field_region", "TerrainFieldNode with a Region domain"],
		["Field (Corridor)", "field_corridor", "TerrainFieldNode with a Path3D route"],
		["Field (Global)", "field_global", "TerrainFieldNode acting on the whole terrain"],
		["Heightmap", "heightmap", "TerrainHeightmapNode"],
		["Group", "group", "TerrainFieldGroup"],
		["Smooth", "smooth", "TerrainSmoothModifier"],
		["Terrace", "terrace", "TerrainTerraceModifier"],
		["Clamp", "clamp", "TerrainClampModifier"],
		["Remap", "remap", "TerrainRemapModifier"],
		["Flatten", "flatten", "TerrainFlattenModifier"],
		["Hole", "hole", "TerrainHoleNode"],
		["Scatter", "scatter", "TerrainScatterNode"],
		["Paint layer", "paint", "TerrainPaintLayer (height delta)"],
	]

static func create_node(kind: String) -> Node:
	match kind:
		"generator":
			var g := TerrainGenerator.new()
			g.name = "TerrainGenerator"
			return g
		"field_region":
			var f := TerrainFieldNode.new()
			f.name = "Field"
			return f
		"field_corridor":
			var f := TerrainFieldNode.new()
			f.name = "Corridor"
			f.domain_kind = TerrainTypes.DomainKind.CORRIDOR
			f.profile_height = -2.0
			var path := Path3D.new()
			path.name = "Route"
			path.curve = Curve3D.new()
			path.curve.add_point(Vector3(-24, 0, 0))
			path.curve.add_point(Vector3(24, 0, 0))
			f.add_child(path)
			return f
		"field_global":
			var f := TerrainFieldNode.new()
			f.name = "GlobalField"
			f.domain_kind = TerrainTypes.DomainKind.GLOBAL
			f.profile_height = 0.0
			f.relief_layers = [TerrainReliefSource.new()] as Array[TerrainReliefSource]
			return f
		"heightmap":
			var h := TerrainHeightmapNode.new()
			h.name = "Heightmap"
			# Typical use: terrain base over the whole map.
			h.domain_kind = TerrainTypes.DomainKind.GLOBAL
			h.blend_mode = TerrainTypes.BlendMode.REPLACE
			return h
		"group":
			var g := TerrainFieldGroup.new()
			g.name = "Group"
			return g
		"smooth":
			return _named(TerrainSmoothModifier.new(), "Smooth")
		"terrace":
			return _named(TerrainTerraceModifier.new(), "Terrace")
		"clamp":
			return _named(TerrainClampModifier.new(), "Clamp")
		"remap":
			return _named(TerrainRemapModifier.new(), "Remap")
		"flatten":
			return _named(TerrainFlattenModifier.new(), "Flatten")
		"hole":
			return _named(TerrainHoleNode.new(), "Hole")
		"scatter":
			var s := TerrainScatterNode.new()
			s.name = "Scatter"
			s.mesh = BoxMesh.new()
			return s
		"paint":
			return _named(TerrainPaintLayer.new(), "PaintDelta")
	return null

static func _named(node: Node, n: String) -> Node:
	node.name = n
	return node

func _target_parent(kind: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var parent: Node = selected[0] if not selected.is_empty() else root
	if kind == "paint":
		while parent and not (parent is TerrainGenerator):
			parent = parent.get_parent()
	return parent if parent else root

func _add(kind: String) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var node := create_node(kind)
	if root == null:
		if node is Node3D:
			push_warning("[terrainy] Open or create a 3D scene first")
		node.free()
		return
	var parent := _target_parent(kind)
	if parent == null:
		push_warning("[terrainy] Paint layers must be children of a TerrainGenerator")
		node.free()
		return
	undo_redo.create_action("terrainy: add %s" % node.name)
	undo_redo.add_do_method(parent, "add_child", node, true)
	undo_redo.add_do_method(self, "_set_owner_recursive", node, root)
	undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(parent, "remove_child", node)
	undo_redo.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)

func _set_owner_recursive(node: Node, owner_node: Node) -> void:
	node.owner = owner_node
	for child in node.get_children():
		_set_owner_recursive(child, owner_node)

func _isolate(on: bool) -> void:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var node: Node = selected[0] if not selected.is_empty() else null
	var gen: Node = node
	while gen and not (gen is TerrainGenerator):
		gen = gen.get_parent()
	if gen:
		gen.preview_isolate_node = node if on and node != gen and node is Node3D else null

## Save the selected composable node (with its children) as a configuration snapshot.
func save_selected_config(config_name: String) -> Error:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	if selected.is_empty() or not (selected[0] is TerrainComposableNode):
		push_warning("[terrainy] Select a field / group / modifier to save its configuration")
		return ERR_INVALID_PARAMETER
	var err := save_config(selected[0], config_name)
	refresh_configs()
	return err

static func save_config(node: Node, config_name: String) -> Error:
	if config_name.strip_edges().is_empty():
		config_name = String(node.name)
	DirAccess.make_dir_recursive_absolute(CONFIG_DIR)
	var copy := node.duplicate()
	if copy is Node3D:
		copy.transform = Transform3D(copy.transform.basis, Vector3.ZERO)
	_own(copy, copy)
	var packed := PackedScene.new()
	var err := packed.pack(copy)
	copy.free()
	if err != OK:
		return err
	var path := "%s/%s.tscn" % [CONFIG_DIR, config_name.validate_filename()]
	return ResourceSaver.save(packed, path)

static func _own(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own(child, owner_node)

func refresh_configs() -> void:
	if _configs == null:
		return
	_configs.clear()
	if not DirAccess.dir_exists_absolute(CONFIG_DIR):
		return
	for f in DirAccess.get_files_at(CONFIG_DIR):
		if f.ends_with(".tscn"):
			_configs.add_item(f.get_basename())

func _insert_config() -> void:
	var sel := _configs.get_selected_items()
	if sel.is_empty():
		return
	var path := "%s/%s.tscn" % [CONFIG_DIR, _configs.get_item_text(sel[0])]
	var packed := load(path) as PackedScene
	var root := EditorInterface.get_edited_scene_root()
	if packed == null or root == null:
		return
	var node := packed.instantiate()
	# A local copy, not an instance: the configuration is a starting point to keep editing.
	node.scene_file_path = ""
	var parent := _target_parent("field")
	undo_redo.create_action("terrainy: insert configuration")
	undo_redo.add_do_method(parent, "add_child", node, true)
	undo_redo.add_do_method(self, "_set_owner_recursive", node, root)
	undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(parent, "remove_child", node)
	undo_redo.commit_action()
