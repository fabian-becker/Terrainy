@tool
extends VBoxContainer

## Paint dock: brush selection + options, and the generator's paint layer stack
## (scene order = application order).
##
## Laid out with editor-native pieces (collapsible sections, editor icons, a layer tree and a
## placeholder panel) so it reads like a built-in dock instead of a stack of default controls.

const BrushStamp = preload("res://addons/terrainy/gen/paint/brush_stamp.gd")
const StrokeOp = BrushStamp.StrokeOp

const ICON_GENERATOR := "res://addons/terrainy/icons/generator.svg"
const ICON_PAINT_LAYER := "res://addons/terrainy/icons/paint_layer.svg"
const ICON_TEXTURE_LAYER := "res://addons/terrainy/icons/texture_layer.svg"
const ICON_MASK := "res://addons/terrainy/icons/mask.svg"
const ICON_FLATTEN := "res://addons/terrainy/icons/flatten.svg"
const ICON_OP_OFF := "res://addons/terrainy/icons/op_off.svg"
const ICON_OP_RAISE := "res://addons/terrainy/icons/op_raise.svg"
const ICON_OP_LOWER := "res://addons/terrainy/icons/op_lower.svg"
const ICON_OP_SMOOTH := "res://addons/terrainy/icons/op_smooth.svg"
const ICON_OP_NOISE := "res://addons/terrainy/icons/op_noise.svg"

const CONTROL_WIDTH := 96.0
## Thumbnail sizes: the picker button stays inspector-height with a small preview, while the
## dropdown list uses a larger one so similarly named textures are easy to tell apart.
const TEXTURE_ICON_SIZE := 32
const TEXTURE_BUTTON_ICON_SIZE := 16

var brush = null  # brush_tool.gd
var undo_redo: EditorUndoRedoManager = null
var generator: TerrainGenerator = null

var _title: Label
var _brush_section: FoldableContainer
var _brush_content: VBoxContainer
var _layers_section: FoldableContainer
var _layers_content: VBoxContainer
var _ops: Dictionary = {}
var _radius: SpinBox
var _strength: SpinBox
var _height_scale: SpinBox
var _absolute: CheckBox
var _absolute_height: SpinBox
var _texture: OptionButton
var _erase_texture: CheckBox
var _falloff: EditorResourcePicker
## Texture thumbnails keyed by source texture instance / swatch color + size.
var _icon_cache: Dictionary = {}
## Palette layers whose `layer_changed` signal currently drives a picker refresh.
var _hooked_layers: Array = []
var _layers: Tree
var _layers_empty: PanelContainer
var _layers_empty_label: Label
var _add_button: MenuButton
var _up: Button
var _down: Button
var _clear: Button
var _remove: Button
var _group := ButtonGroup.new()

func _init() -> void:
	name = "Terrainy Paint"
	custom_minimum_size = Vector2(240, 0)

func setup(p_brush, p_undo: EditorUndoRedoManager) -> void:
	brush = p_brush
	undo_redo = p_undo
	if _title == null:
		_build()
	brush.changed.connect(_sync_from_brush)

func _build() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(margin)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(page)

	page.add_child(_build_header())

	# FoldableContainer gives every direct child the same content rect, so each section holds a
	# single VBox that does the actual stacking.
	_brush_section = FoldableContainer.new()
	_brush_section.title = "Brush"
	_brush_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(_brush_section)
	_brush_content = VBoxContainer.new()
	_brush_content.add_theme_constant_override("separation", 6)
	_brush_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_brush_section.add_child(_brush_content)
	_build_brush_section()

	_layers_section = FoldableContainer.new()
	_layers_section.title = "Paint Layers"
	_layers_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layers_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(_layers_section)
	_layers_content = VBoxContainer.new()
	_layers_content.add_theme_constant_override("separation", 6)
	_layers_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layers_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_layers_section.add_child(_layers_content)
	_build_layers_section()

	_sync_from_brush()
	_update_empty_state()

func _build_header() -> Control:
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 2)
	header.add_child(_muted_label("Terrain Generator"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	header.add_child(row)
	var gen_icon := TextureRect.new()
	gen_icon.texture = load(ICON_GENERATOR)
	gen_icon.custom_minimum_size = Vector2(20, 20)
	gen_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gen_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(gen_icon)
	_title = Label.new()
	_title.text = "No generator selected"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.add_theme_font_size_override("font_size", 15)
	row.add_child(_title)
	return header

func _build_brush_section() -> void:
	var ops := GridContainer.new()
	ops.columns = 4
	ops.add_theme_constant_override("h_separation", 4)
	ops.add_theme_constant_override("v_separation", 4)
	ops.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_brush_content.add_child(ops)
	for entry in [
			["Off", -1, ICON_OP_OFF, "Stop painting in the viewport."],
			["Raise", StrokeOp.RAISE, ICON_OP_RAISE, "Raise the terrain under the brush. Hold Ctrl to erase."],
			["Lower", StrokeOp.LOWER, ICON_OP_LOWER, "Lower the terrain under the brush. Hold Ctrl to erase."],
			["Flatten", StrokeOp.FLATTEN, ICON_FLATTEN, "Flatten to the height under the brush. Hold Shift for an absolute height."],
			["Smooth", StrokeOp.SMOOTH, ICON_OP_SMOOTH, "Smooth the surface under the brush."],
			["Noise", StrokeOp.STAMP_NOISE, ICON_OP_NOISE, "Stamp procedural noise."],
			["Texture", StrokeOp.TEXTURE, ICON_TEXTURE_LAYER, "Paint the selected texture layer's weight."],
			["Mask", StrokeOp.MASK, ICON_MASK, "Paint a mask for fields and modifiers."]]:
		var b := Button.new()
		b.text = entry[0]
		b.icon = load(entry[2])
		b.toggle_mode = true
		b.button_group = _group
		b.tooltip_text = entry[3]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_set_op.bind(entry[1]))
		ops.add_child(b)
		_ops[entry[1]] = b
	_ops[-1].button_pressed = true

	_radius = _spin("Radius (m)", 0.5, 512.0, 0.1, func(v): brush.radius = v,
		"Brush radius in meters. [ and ] change it from the viewport.")
	_strength = _spin("Strength", 0.0, 1.0, 0.01, func(v): brush.strength = v,
		"How strongly each stamp applies.")
	_height_scale = _spin("Height per stamp (m)", 0.01, 50.0, 0.01, func(v): brush.height_scale = v,
		"Meters added per stamp at Strength 1.")

	var abs_row := HBoxContainer.new()
	abs_row.add_theme_constant_override("separation", 8)
	_brush_content.add_child(abs_row)
	_absolute = CheckBox.new()
	_absolute.text = "Absolute flatten"
	_absolute.tooltip_text = "Flatten to the target height instead of the height under the brush."
	_absolute.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_absolute.toggled.connect(_on_absolute_toggled)
	abs_row.add_child(_absolute)
	_absolute_height = SpinBox.new()
	_absolute_height.min_value = -10000.0
	_absolute_height.max_value = 10000.0
	_absolute_height.step = 0.1
	_absolute_height.custom_minimum_size = Vector2(CONTROL_WIDTH, 0)
	_absolute_height.tooltip_text = "Absolute flatten target height (m)."
	_absolute_height.value_changed.connect(func(v): brush.absolute_height = v)
	abs_row.add_child(_absolute_height)

	_texture = OptionButton.new()
	_texture.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Long layer names must not widen the dock: show an ellipsis on the button and let the
	# dropdown size itself to the item list instead.
	_texture.clip_text = true
	_texture.fit_to_longest_item = false
	_texture.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_texture.item_selected.connect(_on_texture_selected)
	var texture_popup := _texture.get_popup()
	# A search field appears once the palette is big enough to need one.
	texture_popup.search_bar_enabled = true
	texture_popup.search_bar_min_item_count = 6
	texture_popup.search_bar_fuzzy_search_enabled = true
	var texture_row := HBoxContainer.new()
	texture_row.add_theme_constant_override("separation", 8)
	texture_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texture_row.add_child(_texture)
	_erase_texture = CheckBox.new()
	_erase_texture.text = "Erase"
	_erase_texture.tooltip_text = "Remove the selected texture's weight instead of painting it. Ctrl erases for a single stroke."
	_erase_texture.toggled.connect(func(on):
		brush.texture_erase = on
		# Redraw the cursor overlay now so the erase ring/label switches without a mouse move.
		brush.changed.emit())
	texture_row.add_child(_erase_texture)
	_add_control_row("Texture", texture_row, true, "Texture layer painted by the Texture op.")

	_falloff = EditorResourcePicker.new()
	_falloff.base_type = "Curve"
	_falloff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_falloff.resource_changed.connect(func(r): brush.falloff = r)
	_falloff.resource_selected.connect(func(r, _inspect): EditorInterface.inspect_object(r))
	_add_control_row("Falloff", _falloff, true, "Brush falloff curve from the center (0) to the rim (1).")

	var hint := _muted_label("Ctrl: erase  ·  Erase: remove texture weight  ·  Shift: absolute flatten  ·  [ / ]: radius")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	_brush_content.add_child(hint)

func _build_layers_section() -> void:
	var intro := _muted_label("Scene order — the top layer is applied first.")
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", 11)
	_layers_content.add_child(intro)

	# Toolbar above the list, like the scene / filesystem docks.
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	_layers_content.add_child(actions)
	_add_button = MenuButton.new()
	_add_button.text = "Add Layer"
	_add_button.icon = _editor_icon("Add")
	_add_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_add_button.tooltip_text = "Add a paint layer to this generator."
	_add_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var popup := _add_button.get_popup()
	for kind in TerrainPaintLayer.PaintKind.values():
		var idx := popup.item_count
		popup.add_item(TerrainPaintLayer.PaintKind.keys()[kind].capitalize(), kind)
		popup.set_item_icon(idx, _paint_kind_icon(kind))
	popup.id_pressed.connect(_add_layer)
	actions.add_child(_add_button)
	_up = _icon_button("MoveUp", "Up", "Move the selected layer up (earlier in the stack).")
	_up.pressed.connect(_move_layer.bind(-1))
	actions.add_child(_up)
	_down = _icon_button("MoveDown", "Down", "Move the selected layer down (later in the stack).")
	_down.pressed.connect(_move_layer.bind(1))
	actions.add_child(_down)
	_clear = _icon_button("Clear", "Clear", "Clear the selected layer's painted data.")
	_clear.pressed.connect(_clear_layer)
	actions.add_child(_clear)
	_remove = _icon_button("Remove", "Delete", "Remove the selected layer from the generator.")
	_remove.pressed.connect(_remove_layer)
	actions.add_child(_remove)

	_layers = Tree.new()
	_layers.hide_root = true
	_layers.columns = 2
	_layers.select_mode = Tree.SELECT_ROW
	_layers.allow_reselect = true
	_layers.custom_minimum_size = Vector2(0, 160)
	_layers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layers.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_layers.set_column_expand(0, true)
	_layers.set_column_expand(1, false)
	_layers.set_column_custom_minimum_width(1, 88)
	_layers.item_selected.connect(_on_layer_selected)
	_layers_content.add_child(_layers)

	_layers_empty = PanelContainer.new()
	_layers_empty.custom_minimum_size = Vector2(0, 160)
	_layers_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_layers_empty_label = Label.new()
	_layers_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_layers_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_layers_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_layers_empty_label.add_theme_color_override("font_color", _muted_color())
	_layers_empty.add_child(_layers_empty_label)
	_layers_content.add_child(_layers_empty)

## Label + control row, matching the editor inspector's label-left/control-right rhythm.
func _add_control_row(label_text: String, control: Control, expand_control: bool, tip: String = "") -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var l := Label.new()
	l.text = label_text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.tooltip_text = tip
	row.add_child(l)
	if expand_control:
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(control)
	_brush_content.add_child(row)

func _spin(label_text: String, lo: float, hi: float, step: float, cb: Callable, tip: String = "") -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size = Vector2(CONTROL_WIDTH, 0)
	s.tooltip_text = tip
	s.value_changed.connect(cb)
	_add_control_row(label_text, s, false, tip)
	return s

func _on_absolute_toggled(on: bool) -> void:
	brush.use_absolute = on
	_absolute_height.editable = on

func _on_texture_selected(index: int) -> void:
	var id := _texture.get_item_id(index)
	if id < 0:
		return
	brush.texture_index = id
	_update_texture_button_icon(id)

func _on_layer_selected() -> void:
	var layer := _selected_layer()
	brush.layer = layer
	if layer:
		EditorInterface.inspect_object(layer)
	_update_actions()

func _sync_from_brush() -> void:
	if brush == null or _radius == null:
		return
	_radius.set_value_no_signal(brush.radius)
	_strength.set_value_no_signal(brush.strength)
	_height_scale.set_value_no_signal(brush.height_scale)
	_absolute.set_pressed_no_signal(brush.use_absolute)
	_absolute_height.set_value_no_signal(brush.absolute_height)
	_absolute_height.editable = brush.use_absolute
	_falloff.edited_resource = brush.falloff
	# Programmatic presses skip the ButtonGroup notification, so set every member explicitly.
	for op in _ops:
		_ops[op].set_pressed_no_signal(op == brush.op)
	if _texture != null:
		_select_texture_item()
	if _erase_texture != null:
		_erase_texture.set_pressed_no_signal(brush.texture_erase)

func _set_op(op: int) -> void:
	brush.op = op
	brush.changed.emit()

## Called by the plugin when the edited generator changes (or null).
func set_generator(gen: TerrainGenerator) -> void:
	if generator and is_instance_valid(generator) and generator.paint_layers_changed.is_connected(refresh):
		generator.paint_layers_changed.disconnect(refresh)
		generator.texture_layers_changed.disconnect(refresh)
	if gen != generator:
		_icon_cache.clear()
	generator = gen
	brush.generator = gen
	if gen:
		gen.paint_layers_changed.connect(refresh)
		gen.texture_layers_changed.connect(refresh)
	refresh()

func refresh() -> void:
	if _layers == null:
		return
	_hook_palette_layers()
	var has_gen := _has_generator()
	_title.text = generator.name if has_gen else "No generator selected"
	_title.tooltip_text = "Editing %s" % generator.name if has_gen else ""
	if has_gen:
		_title.remove_theme_color_override("font_color")
	else:
		_title.add_theme_color_override("font_color", _muted_color())
	_rebuild_layers(has_gen)
	_rebuild_texture_options(has_gen)
	_update_empty_state()

func _rebuild_layers(has_gen: bool) -> void:
	_layers.clear()
	if not has_gen:
		return
	var muted := _muted_color()
	var root := _layers.create_item()
	for layer in generator.get_paint_layers():
		var kind_text: String = TerrainPaintLayer.PaintKind.keys()[layer.kind].capitalize()
		var item := _layers.create_item(root)
		item.set_text(0, layer.name)
		item.set_text(1, kind_text if layer.enabled else "%s · off" % kind_text)
		item.set_icon(0, _paint_kind_icon(layer.kind))
		item.set_metadata(0, layer)
		item.set_tooltip_text(0, "%s — %s" % [layer.name, kind_text])
		if not layer.enabled:
			item.set_custom_color(0, muted)
			item.set_custom_color(1, muted)
		if layer == brush.layer:
			item.select(0)

func _rebuild_texture_options(has_gen: bool) -> void:
	_texture.clear()
	_texture.set_button_icon(null)
	if not has_gen:
		_texture.disabled = true
		_texture.tooltip_text = "Select a TerrainGenerator to pick a texture layer."
		return
	var palette := _palette()
	if palette.is_empty():
		_texture.add_item("No texture layers", -1)
		_texture.select(0)
		_texture.disabled = true
		_texture.tooltip_text = "This generator has no texture layers yet."
		return
	_texture.disabled = false
	_texture.tooltip_text = "Texture layer painted by the Texture op."
	var popup := _texture.get_popup()
	for i in palette.size():
		var l = palette[i]
		var layer_name: String = l.layer_name if l else "<empty>"
		_texture.add_icon_item(_palette_icon(l, TEXTURE_ICON_SIZE),
			"%d: %s" % [i, layer_name], i)
		var item := _texture.item_count - 1
		popup.set_item_icon_max_width(item, TEXTURE_ICON_SIZE)
		popup.set_item_tooltip(item, _texture_item_tooltip(i, l))
	_select_texture_item()

## Texture-layer edits (name, albedo texture, color) emit `layer_changed` but not
## `texture_layers_changed`, so the picker listens to the layers themselves.
func _hook_palette_layers() -> void:
	for layer in _hooked_layers:
		if is_instance_valid(layer) and layer.layer_changed.is_connected(_on_texture_layer_changed):
			layer.layer_changed.disconnect(_on_texture_layer_changed)
	_hooked_layers.clear()
	for layer in _palette():
		if layer and is_instance_valid(layer) and not layer.layer_changed.is_connected(_on_texture_layer_changed):
			layer.layer_changed.connect(_on_texture_layer_changed)
			_hooked_layers.append(layer)

func _on_texture_layer_changed() -> void:
	if _texture != null and _has_generator():
		_rebuild_texture_options(true)

## The generator's palette, with the raw texture-layer array as a fallback for generators that
## have not captured a palette yet.
func _palette() -> Array:
	if not _has_generator():
		return []
	var palette: Array = generator.get_palette()
	if palette.is_empty():
		palette = generator.texture_layers
	return palette

func _select_texture_item() -> void:
	if _palette().is_empty():
		return
	var index := -1
	for i in _texture.item_count:
		if _texture.get_item_id(i) == brush.texture_index:
			index = i
			break
	if index < 0:
		_texture.selected = -1
		_texture.set_button_icon(null)
		return
	_texture.select(index)
	_update_texture_button_icon(brush.texture_index)

## Small preview on the closed OptionButton, while the dropdown items keep the larger one.
func _update_texture_button_icon(texture_index: int) -> void:
	var palette := _palette()
	if texture_index < 0 or texture_index >= palette.size():
		_texture.set_button_icon(null)
		return
	_texture.set_button_icon(_palette_icon(palette[texture_index], TEXTURE_BUTTON_ICON_SIZE))

func _texture_item_tooltip(index: int, layer) -> String:
	var title := "%d: %s" % [index, layer.layer_name if layer else "<empty>"]
	if layer == null:
		return "%s\nEmpty palette slot." % title
	var tex: Texture2D = layer.albedo_texture
	if tex:
		var size := tex.get_size()
		return "%s\n%d × %d px" % [title, int(size.x), int(size.y)]
	return "%s\nColor %s (no albedo texture)" % [title, layer.albedo_color.to_html(false)]

## Thumbnail for a palette entry: its albedo texture when there is one, otherwise a swatch of the
## layer's albedo color so color-only generators are still distinguishable.
func _palette_icon(layer, size: int) -> Texture2D:
	if layer == null:
		return _swatch_icon(Color(0.35, 0.35, 0.35, 0.75), size)
	var tex: Texture2D = layer.albedo_texture
	if tex:
		var icon := _scaled_texture_icon(tex, size)
		if icon:
			return icon
	return _swatch_icon(layer.albedo_color, size)

func _scaled_texture_icon(tex: Texture2D, size: int) -> Texture2D:
	var key := "tex:%d:%d" % [tex.get_instance_id(), size]
	if _icon_cache.has(key):
		return _icon_cache[key]
	var source := tex.get_image()
	if source == null or source.get_width() <= 0 or source.get_height() <= 0:
		return null
	# Duplicate before resizing: the image handed back by the texture resource may be shared.
	var img: Image = source.duplicate() as Image
	if img.is_compressed() and img.decompress() != OK:
		return null
	var w := img.get_width()
	var h := img.get_height()
	if w != h:
		var side := mini(w, h)
		img = img.get_region(Rect2i((w - side) / 2, (h - side) / 2, side, side))
	if img.get_width() != size:
		img.resize(size, size, Image.INTERPOLATE_LANCZOS)
	var out := ImageTexture.create_from_image(img)
	_icon_cache[key] = out
	return out

func _swatch_icon(color: Color, size: int) -> Texture2D:
	var key := "swatch:%d:%d" % [color.to_rgba32(), size]
	if _icon_cache.has(key):
		return _icon_cache[key]
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(color)
	if size >= 8:
		var edge := color.darkened(0.3)
		edge.a = maxf(edge.a, 0.55)
		for x in size:
			img.set_pixel(x, 0, edge)
			img.set_pixel(x, size - 1, edge)
		for y in size:
			img.set_pixel(0, y, edge)
			img.set_pixel(size - 1, y, edge)
	var out := ImageTexture.create_from_image(img)
	_icon_cache[key] = out
	return out

func _update_empty_state() -> void:
	var has_gen := _has_generator()
	var count := generator.get_paint_layers().size() if has_gen else 0
	_layers.visible = count > 0
	_layers_empty.visible = count == 0
	if not has_gen:
		_layers_empty_label.text = "Select a TerrainGenerator in the scene tree to edit paint layers."
	else:
		_layers_empty_label.text = "No paint layers yet.\nUse Add Layer to start painting."
	_update_actions()

func _update_actions() -> void:
	if _add_button == null:
		return
	var has_gen := _has_generator()
	_add_button.disabled = not has_gen
	var layer := _selected_layer()
	var has_layer := layer != null
	# Paint layers share the generator's child list with fields, groups, modifiers and scatter,
	# so the raw child index says nothing about the paint stack order.
	var layers: Array = generator.get_paint_layers() if has_gen else []
	var paint_index: int = layers.find(layer) if has_layer else -1
	_up.disabled = paint_index <= 0
	_down.disabled = paint_index < 0 or paint_index >= layers.size() - 1
	_clear.disabled = not has_layer or not layer.has_data()
	_remove.disabled = not has_layer

func _selected_layer() -> TerrainPaintLayer:
	if _layers == null:
		return null
	var item := _layers.get_selected()
	if item == null:
		return null
	return item.get_metadata(0)

func _has_generator() -> bool:
	return generator != null and is_instance_valid(generator)

func _paint_kind_icon(kind: int) -> Texture2D:
	match kind:
		TerrainPaintLayer.PaintKind.TEXTURE:
			return load(ICON_TEXTURE_LAYER)
		TerrainPaintLayer.PaintKind.MASK:
			return load(ICON_MASK)
	return load(ICON_PAINT_LAYER)

func _icon_button(icon_name: String, fallback_text: String, tip: String) -> Button:
	var b := Button.new()
	b.tooltip_text = tip
	var icon := _editor_icon(icon_name)
	if icon:
		b.icon = icon
		b.custom_minimum_size = Vector2(30, 26)
	else:
		b.text = fallback_text
		b.custom_minimum_size = Vector2(0, 26)
	return b

func _muted_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", _muted_color())
	return l

func _muted_color() -> Color:
	var theme := _editor_theme()
	if theme and theme.has_color("font_disabled_color", "Button"):
		return theme.get_color("font_disabled_color", "Button")
	return Color(0.6, 0.6, 0.6)

func _editor_theme() -> Theme:
	return EditorInterface.get_editor_theme()

func _editor_icon(icon_name: String) -> Texture2D:
	var theme := _editor_theme()
	if theme and theme.has_icon(icon_name, "EditorIcons"):
		return theme.get_icon(icon_name, "EditorIcons")
	return null

func _add_layer(kind: int) -> void:
	if generator == null:
		return
	var layer := TerrainPaintLayer.new()
	layer.kind = kind
	layer.name = "Paint" + TerrainPaintLayer.PaintKind.keys()[kind].capitalize().replace(" ", "")
	undo_redo.create_action("terrainy: add paint layer")
	undo_redo.add_do_method(generator, "add_child", layer, true)
	undo_redo.add_do_property(layer, "owner", EditorInterface.get_edited_scene_root())
	undo_redo.add_do_reference(layer)
	undo_redo.add_undo_method(generator, "remove_child", layer)
	undo_redo.commit_action()
	brush.layer = layer
	refresh()

func _move_layer(delta: int) -> void:
	var layer := _selected_layer()
	if layer == null:
		return
	var layers: Array = generator.get_paint_layers()
	var index: int = layers.find(layer)
	var target: int = index + delta
	if index < 0 or target < 0 or target >= layers.size():
		return
	# Swap with the adjacent paint layer, not with whatever sibling happens to sit next to it
	# in the generator's child list. `move_child` at the neighbour's index places the layer
	# after it when moving down and before it when moving up (the index shifts after removal).
	var neighbor: Node = layers[target]
	var from := layer.get_index()
	var to: int = neighbor.get_index()
	undo_redo.create_action("terrainy: reorder paint layer")
	undo_redo.add_do_method(generator, "move_child", layer, to)
	undo_redo.add_undo_method(generator, "move_child", layer, from)
	undo_redo.commit_action()
	generator.notify_paint_structure_changed()

func _clear_layer() -> void:
	var layer := _selected_layer()
	if layer == null or not layer.has_data():
		return
	var rect := Rect2i(Vector2i.ZERO, layer.get_data().get_size())
	var before := layer.copy_rect(rect)
	var empty := Image.create(rect.size.x, rect.size.y, false, before.get_format())
	undo_redo.create_action("terrainy: clear paint layer")
	undo_redo.add_do_method(layer, "paste_rect", empty, Vector2i.ZERO, Rect2i())
	undo_redo.add_undo_method(layer, "paste_rect", before, Vector2i.ZERO, layer.content_rect)
	undo_redo.commit_action()
	_update_actions()

func _remove_layer() -> void:
	var layer := _selected_layer()
	if layer == null:
		return
	undo_redo.create_action("terrainy: remove paint layer")
	undo_redo.add_do_method(generator, "remove_child", layer)
	undo_redo.add_undo_method(generator, "add_child", layer, true)
	undo_redo.add_undo_method(generator, "move_child", layer, layer.get_index())
	undo_redo.add_undo_property(layer, "owner", layer.owner)
	undo_redo.add_undo_reference(layer)
	undo_redo.commit_action()
	brush.layer = null
	refresh()
