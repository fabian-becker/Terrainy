@tool
class_name ShapeMaskEditorDialog
extends ConfirmationDialog

class BrushIndicatorOverlay:
	extends Control

	var indicator_color: Color = Color(1.0, 0.55, 0.2, 0.35)
	var border_color: Color = Color(1.0, 1.0, 1.0, 0.9)

	func _draw() -> void:
		var radius = min(size.x, size.y) * 0.5
		if radius <= 1.0:
			return
		var center = size * 0.5
		draw_circle(center, radius, indicator_color)
		draw_arc(center, radius, 0.0, TAU, 48, border_color, 1.5, true)

const ShapeMaskResource = preload("res://addons/terrainy/resources/shape_mask_resource.gd")

enum BrushMode {
	DRAW,
	ERASE,
	BLEND
}

enum PaintMethod {
	REPLACE,
	BLEND
}

var target_shape_node: ShapeNode = null
var undo_redo: EditorUndoRedoManager = null

var _working_image: Image = null
var _canvas_texture: ImageTexture = null
var _is_painting: bool = false
var _undo_stack: Array[Image] = []
var _redo_stack: Array[Image] = []
const MAX_HISTORY_STATES := 32

var _brush_mode: int = BrushMode.DRAW
var _brush_size: int = 24
var _paint_method: int = PaintMethod.REPLACE
var _paint_height: float = 1.0
var _paint_flow: float = 1.0

var _canvas: TextureRect
var _mode_option: OptionButton
var _size_slider: HSlider
var _method_option: OptionButton
var _height_slider: HSlider
var _flow_slider: HSlider
var _width_spin: SpinBox
var _height_spin: SpinBox
var _undo_button: Button
var _redo_button: Button
var _brush_indicator: BrushIndicatorOverlay
var _indicator_label: Label
var _last_mouse_canvas_pos: Vector2 = Vector2.ZERO
var _mouse_in_canvas: bool = false

func _ready() -> void:
	title = "Shape Mask Editor"
	min_size = Vector2i(620, 760)
	ok_button_text = "Apply"
	confirmed.connect(_on_apply_pressed)
	canceled.connect(_on_cancel_pressed)
	close_requested.connect(_on_cancel_pressed)
	_build_ui()

func edit_shape(shape_node: ShapeNode, editor_undo_redo: EditorUndoRedoManager) -> void:
	target_shape_node = shape_node
	undo_redo = editor_undo_redo
	_load_target_image()
	popup_centered_ratio(0.6)

func _build_ui() -> void:
	var root = VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var top_strip = HBoxContainer.new()
	top_strip.add_theme_constant_override("separation", 12)
	root.add_child(top_strip)

	var mode_group = VBoxContainer.new()
	mode_group.add_theme_constant_override("separation", 4)
	top_strip.add_child(mode_group)

	var mode_label = Label.new()
	mode_label.text = "Mode"
	mode_group.add_child(mode_label)

	_mode_option = OptionButton.new()
	_mode_option.add_item("Draw")
	_mode_option.add_item("Erase")
	_mode_option.add_item("Blend")
	_mode_option.item_selected.connect(_on_mode_selected)
	mode_group.add_child(_mode_option)

	var history_group = VBoxContainer.new()
	history_group.add_theme_constant_override("separation", 4)
	top_strip.add_child(history_group)

	var history_label = Label.new()
	history_label.text = "History"
	history_group.add_child(history_label)

	var history_row = HBoxContainer.new()
	history_row.add_theme_constant_override("separation", 6)
	history_group.add_child(history_row)

	_undo_button = Button.new()
	_undo_button.text = "Undo"
	_undo_button.pressed.connect(_on_undo_pressed)
	history_row.add_child(_undo_button)

	_redo_button = Button.new()
	_redo_button.text = "Redo"
	_redo_button.pressed.connect(_on_redo_pressed)
	history_row.add_child(_redo_button)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_strip.add_child(spacer)

	var brush_panel = PanelContainer.new()
	root.add_child(brush_panel)

	var brush_margin = MarginContainer.new()
	brush_margin.add_theme_constant_override("margin_left", 8)
	brush_margin.add_theme_constant_override("margin_top", 8)
	brush_margin.add_theme_constant_override("margin_right", 8)
	brush_margin.add_theme_constant_override("margin_bottom", 8)
	brush_panel.add_child(brush_margin)

	var brush_box = VBoxContainer.new()
	brush_box.add_theme_constant_override("separation", 8)
	brush_margin.add_child(brush_box)

	var brush_title = Label.new()
	brush_title.text = "Brush Settings"
	brush_box.add_child(brush_title)

	var brush_grid = GridContainer.new()
	brush_grid.columns = 2
	brush_grid.add_theme_constant_override("h_separation", 10)
	brush_grid.add_theme_constant_override("v_separation", 6)
	brush_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brush_box.add_child(brush_grid)

	var size_label = Label.new()
	size_label.text = "Brush Size"
	brush_grid.add_child(size_label)

	_size_slider = HSlider.new()
	_size_slider.min_value = 1
	_size_slider.max_value = 96
	_size_slider.step = 1
	_size_slider.value = _brush_size
	_size_slider.custom_minimum_size = Vector2(220, 0)
	_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_size_slider.value_changed.connect(_on_size_changed)
	brush_grid.add_child(_size_slider)

	var method_label = Label.new()
	method_label.text = "Paint Method"
	brush_grid.add_child(method_label)

	_method_option = OptionButton.new()
	_method_option.add_item("Replace")
	_method_option.add_item("Blend")
	_method_option.item_selected.connect(_on_method_selected)
	_method_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brush_grid.add_child(_method_option)

	var height_label = Label.new()
	height_label.text = "Paint Height"
	brush_grid.add_child(height_label)

	_height_slider = HSlider.new()
	_height_slider.min_value = 0.0
	_height_slider.max_value = 1.0
	_height_slider.step = 0.01
	_height_slider.value = _paint_height
	_height_slider.custom_minimum_size = Vector2(220, 0)
	_height_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_height_slider.value_changed.connect(_on_height_changed)
	brush_grid.add_child(_height_slider)

	var flow_label = Label.new()
	flow_label.text = "Flow"
	brush_grid.add_child(flow_label)

	_flow_slider = HSlider.new()
	_flow_slider.min_value = 0.01
	_flow_slider.max_value = 1.0
	_flow_slider.step = 0.01
	_flow_slider.value = _paint_flow
	_flow_slider.custom_minimum_size = Vector2(220, 0)
	_flow_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flow_slider.value_changed.connect(_on_flow_changed)
	brush_grid.add_child(_flow_slider)

	var canvas_label = Label.new()
	canvas_label.text = "Mask Preview"
	root.add_child(canvas_label)

	_canvas = TextureRect.new()
	_canvas.custom_minimum_size = Vector2(560, 560)
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.gui_input.connect(_on_canvas_input)
	_canvas.mouse_exited.connect(_on_canvas_mouse_exited)
	_canvas.resized.connect(_on_canvas_resized)
	root.add_child(_canvas)

	var footer_separator = HSeparator.new()
	root.add_child(footer_separator)

	var footer_row = HBoxContainer.new()
	footer_row.add_theme_constant_override("separation", 8)
	root.add_child(footer_row)

	var resolution_label = Label.new()
	resolution_label.text = "Resolution"
	footer_row.add_child(resolution_label)

	_width_spin = SpinBox.new()
	_width_spin.min_value = 8
	_width_spin.max_value = 2048
	_width_spin.step = 1
	_width_spin.value = 256
	_width_spin.custom_minimum_size = Vector2(84, 0)
	footer_row.add_child(_width_spin)

	var multiply_label = Label.new()
	multiply_label.text = "x"
	footer_row.add_child(multiply_label)

	_height_spin = SpinBox.new()
	_height_spin.min_value = 8
	_height_spin.max_value = 2048
	_height_spin.step = 1
	_height_spin.value = 256
	_height_spin.custom_minimum_size = Vector2(84, 0)
	footer_row.add_child(_height_spin)

	var footer_spacer = Control.new()
	footer_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_row.add_child(footer_spacer)

	var resize_button = Button.new()
	resize_button.text = "Resize"
	resize_button.pressed.connect(_on_resize_pressed)
	footer_row.add_child(resize_button)

	var clear_button = Button.new()
	clear_button.text = "Clear"
	clear_button.pressed.connect(_on_clear_pressed)
	footer_row.add_child(clear_button)

	_brush_indicator = BrushIndicatorOverlay.new()
	_brush_indicator.indicator_color = Color(1.0, 0.55, 0.2, 0.35)
	_brush_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_brush_indicator.visible = false
	_canvas.add_child(_brush_indicator)

	_indicator_label = Label.new()
	_indicator_label.text = ""
	_indicator_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_indicator_label.visible = false
	_canvas.add_child(_indicator_label)

	_on_mode_selected(_brush_mode)
	_update_history_buttons()

func _load_target_image() -> void:
	if target_shape_node == null:
		return
	if target_shape_node.shape_mask == null:
		var created = ShapeMaskResource.new()
		created.ensure_initialized(Vector2i(256, 256))
		target_shape_node.shape_mask = created
	var mask_resource = target_shape_node.shape_mask
	mask_resource.ensure_initialized(mask_resource.resolution)
	_working_image = mask_resource.get_image_copy()
	_width_spin.value = _working_image.get_width()
	_height_spin.value = _working_image.get_height()
	_reset_history()
	_refresh_canvas()

func _refresh_canvas() -> void:
	if _working_image == null:
		_canvas.texture = null
		return
	if _canvas_texture == null:
		_canvas_texture = ImageTexture.create_from_image(_working_image)
	else:
		_canvas_texture.update(_working_image)
	_canvas.texture = _canvas_texture
	_update_history_buttons()

func _on_mode_selected(index: int) -> void:
	_brush_mode = index
	if _height_slider:
		_height_slider.editable = _brush_mode == BrushMode.DRAW
	if _method_option:
		_method_option.disabled = _brush_mode == BrushMode.BLEND
	_update_indicator_style()

func _on_method_selected(index: int) -> void:
	_paint_method = index
	_update_indicator_style()

func _on_size_changed(value: float) -> void:
	_brush_size = int(value)
	_update_brush_indicator(_last_mouse_canvas_pos)

func _on_height_changed(value: float) -> void:
	_paint_height = value
	_update_indicator_style()

func _on_flow_changed(value: float) -> void:
	_paint_flow = value
	_update_indicator_style()

func _on_resize_pressed() -> void:
	if _working_image == null:
		return
	var new_size = Vector2i(int(_width_spin.value), int(_height_spin.value))
	if new_size.x < 1 or new_size.y < 1:
		return
	if _working_image.get_width() == new_size.x and _working_image.get_height() == new_size.y:
		return
	_push_undo_state()
	_working_image.resize(new_size.x, new_size.y, Image.INTERPOLATE_BILINEAR)
	_refresh_canvas()

func _on_clear_pressed() -> void:
	if _working_image == null:
		return
	_push_undo_state()
	_working_image.fill(Color.WHITE)
	_refresh_canvas()

func _on_canvas_input(event: InputEvent) -> void:
	if _working_image == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_is_painting = event.pressed
		_last_mouse_canvas_pos = event.position
		_mouse_in_canvas = true
		_update_brush_indicator(event.position)
		if _is_painting:
			_push_undo_state()
			if _stamp_at_canvas_pos(event.position):
				_refresh_canvas()
	elif event is InputEventMouseMotion and _is_painting and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_last_mouse_canvas_pos = event.position
		_mouse_in_canvas = true
		_update_brush_indicator(event.position)
		if _stamp_at_canvas_pos(event.position):
			_refresh_canvas()
	elif event is InputEventMouseMotion:
		_last_mouse_canvas_pos = event.position
		_mouse_in_canvas = true
		_update_brush_indicator(event.position)

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed:
		if event.keycode == KEY_Z and event.shift_pressed:
			_on_redo_pressed()
		elif event.keycode == KEY_Z:
			_on_undo_pressed()
		elif event.keycode == KEY_Y:
			_on_redo_pressed()

func _stamp_at_canvas_pos(mouse_pos: Vector2) -> bool:
	var draw_rect = _get_canvas_image_draw_rect()
	if draw_rect.size.x <= 0.0 or draw_rect.size.y <= 0.0:
		return false
	if not draw_rect.has_point(mouse_pos):
		return false
	var local_pos = mouse_pos - draw_rect.position
	var uv = Vector2(local_pos.x / draw_rect.size.x, local_pos.y / draw_rect.size.y)
	uv = uv.clamp(Vector2.ZERO, Vector2.ONE)
	var img_x = int(round(uv.x * float(_working_image.get_width() - 1)))
	var img_y = int(round(uv.y * float(_working_image.get_height() - 1)))
	_stamp_brush(Vector2i(img_x, img_y))
	return true

func _get_canvas_image_draw_rect() -> Rect2:
	if _canvas == null or _working_image == null:
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	var canvas_size = _canvas.size
	if canvas_size.x <= 0.0 or canvas_size.y <= 0.0:
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	var image_size = Vector2(float(_working_image.get_width()), float(_working_image.get_height()))
	if image_size.x <= 0.0 or image_size.y <= 0.0:
		return Rect2(Vector2.ZERO, Vector2.ZERO)

	var draw_size = canvas_size
	if _canvas.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED or _canvas.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT:
		var canvas_aspect = canvas_size.x / canvas_size.y
		var image_aspect = image_size.x / image_size.y
		if image_aspect > canvas_aspect:
			draw_size = Vector2(canvas_size.x, canvas_size.x / image_aspect)
		else:
			draw_size = Vector2(canvas_size.y * image_aspect, canvas_size.y)

	var draw_pos = (canvas_size - draw_size) * 0.5
	return Rect2(draw_pos, draw_size)

func _stamp_brush(center: Vector2i) -> void:
	var radius: int = maxi(1, int(round(float(_brush_size) * 0.5)))
	var target_gray = 1.0
	if _brush_mode == BrushMode.DRAW:
		# Invert visual grayscale because black means max contribution.
		target_gray = clamp(1.0 - _paint_height, 0.0, 1.0)
	var blend_mode = _brush_mode == BrushMode.BLEND
	var replace_mode = _paint_method == PaintMethod.REPLACE
	# Scale blend sampling with brush size so blending affects the painted area.
	var blend_sample_radius := clampi(int(round(float(radius) * 0.2)), 1, 6)
	var source_image: Image = null
	if blend_mode:
		source_image = _working_image.duplicate()
	for y in range(center.y - radius, center.y + radius + 1):
		if y < 0 or y >= _working_image.get_height():
			continue
		for x in range(center.x - radius, center.x + radius + 1):
			if x < 0 or x >= _working_image.get_width():
				continue
			var offset = Vector2(float(x - center.x), float(y - center.y))
			var dist = offset.length()
			if dist > float(radius):
				continue
			var falloff = 1.0 - smoothstep(0.0, float(radius), dist)
			var current = _working_image.get_pixel(x, y).r
			var next = current
			if blend_mode:
				var neighborhood_mean = _sample_local_average(source_image, x, y, blend_sample_radius)
				var blend_amount = _paint_flow * falloff
				next = lerp(current, neighborhood_mean, blend_amount)
			elif replace_mode:
				next = lerp(current, target_gray, falloff)
			else:
				var amount = _paint_flow * falloff
				next = lerp(current, target_gray, amount)
			_working_image.set_pixel(x, y, Color(next, next, next, 1.0))

func _on_canvas_mouse_exited() -> void:
	_mouse_in_canvas = false
	if _brush_indicator:
		_brush_indicator.visible = false
	if _indicator_label:
		_indicator_label.visible = false

func _on_canvas_resized() -> void:
	if _canvas == null:
		return
	# Force clean redraw while the dialog is being resized to avoid preview artifacts.
	_canvas.queue_redraw()
	if _mouse_in_canvas:
		_update_brush_indicator(_last_mouse_canvas_pos)

func _update_brush_indicator(mouse_pos: Vector2) -> void:
	if not _mouse_in_canvas or _working_image == null or _canvas == null:
		return
	if _working_image.get_width() <= 0 or _working_image.get_height() <= 0:
		return
	var draw_rect = _get_canvas_image_draw_rect()
	if draw_rect.size.x <= 0.0 or draw_rect.size.y <= 0.0 or not draw_rect.has_point(mouse_pos):
		if _brush_indicator:
			_brush_indicator.visible = false
		if _indicator_label:
			_indicator_label.visible = false
		return

	var scale_x = draw_rect.size.x / float(_working_image.get_width())
	var scale_y = draw_rect.size.y / float(_working_image.get_height())
	var brush_radius_px = max(2.0, (float(_brush_size) * 0.5) * ((scale_x + scale_y) * 0.5))

	_brush_indicator.visible = true
	_brush_indicator.position = mouse_pos - Vector2(brush_radius_px, brush_radius_px)
	_brush_indicator.size = Vector2(brush_radius_px * 2.0, brush_radius_px * 2.0)
	_brush_indicator.indicator_color = _get_indicator_color()
	_brush_indicator.queue_redraw()

	_indicator_label.visible = true
	_indicator_label.text = _get_indicator_text()
	_indicator_label.position = mouse_pos + Vector2(brush_radius_px + 8.0, 8.0)

	var min_x = draw_rect.position.x
	var min_y = draw_rect.position.y
	var max_x = max(min_x, draw_rect.position.x + draw_rect.size.x - _indicator_label.size.x)
	var max_y = max(min_y, draw_rect.position.y + draw_rect.size.y - _indicator_label.size.y)
	_indicator_label.position.x = clamp(_indicator_label.position.x, min_x, max_x)
	_indicator_label.position.y = clamp(_indicator_label.position.y, min_y, max_y)

func _update_indicator_style() -> void:
	if not _mouse_in_canvas:
		return
	_update_brush_indicator(_last_mouse_canvas_pos)

func _get_indicator_color() -> Color:
	var intensity = _paint_flow
	if _brush_mode == BrushMode.BLEND:
		return Color(0.3, 0.7, 1.0, clamp(0.2 + intensity * 0.5, 0.2, 0.9))
	if _brush_mode == BrushMode.ERASE:
		return Color(1.0, 0.35, 0.35, clamp(0.2 + intensity * 0.5, 0.2, 0.9))
	if _paint_method == PaintMethod.REPLACE:
		return Color(1.0, 0.55, 0.2, 0.8)
	return Color(1.0, 0.75, 0.2, clamp(0.2 + intensity * 0.5, 0.2, 0.9))

func _get_indicator_text() -> String:
	if _brush_mode == BrushMode.BLEND:
		return "Blend  S:%d  F:%.2f" % [_brush_size, _paint_flow]
	if _brush_mode == BrushMode.ERASE:
		var erase_method = "Replace" if _paint_method == PaintMethod.REPLACE else "Blend"
		return "Erase %s  S:%d  F:%.2f" % [erase_method, _brush_size, _paint_flow]
	var draw_method = "Replace" if _paint_method == PaintMethod.REPLACE else "Blend"
	return "Draw %s  S:%d  H:%.2f  F:%.2f" % [draw_method, _brush_size, _paint_height, _paint_flow]

func _reset_history() -> void:
	_undo_stack.clear()
	_redo_stack.clear()
	_update_history_buttons()

func _push_undo_state() -> void:
	if _working_image == null:
		return
	_undo_stack.append(_working_image.duplicate())
	if _undo_stack.size() > MAX_HISTORY_STATES:
		_undo_stack.remove_at(0)
	_redo_stack.clear()
	_update_history_buttons()

func _on_undo_pressed() -> void:
	if _undo_stack.is_empty() or _working_image == null:
		return
	_redo_stack.append(_working_image.duplicate())
	_working_image = _undo_stack.pop_back()
	_refresh_canvas()

func _on_redo_pressed() -> void:
	if _redo_stack.is_empty() or _working_image == null:
		return
	_undo_stack.append(_working_image.duplicate())
	_working_image = _redo_stack.pop_back()
	_refresh_canvas()

func _update_history_buttons() -> void:
	if _undo_button:
		_undo_button.disabled = _undo_stack.is_empty()
	if _redo_button:
		_redo_button.disabled = _redo_stack.is_empty()

func _sample_local_average(image: Image, x: int, y: int, sample_radius: int = 1) -> float:
	var sum := 0.0
	var count := 0
	for yy in range(y - sample_radius, y + sample_radius + 1):
		if yy < 0 or yy >= image.get_height():
			continue
		for xx in range(x - sample_radius, x + sample_radius + 1):
			if xx < 0 or xx >= image.get_width():
				continue
			sum += image.get_pixel(xx, yy).r
			count += 1
	if count <= 0:
		return image.get_pixel(x, y).r
	return sum / float(count)

func _on_apply_pressed() -> void:
	if target_shape_node == null or _working_image == null or undo_redo == null:
		hide()
		return
	var previous_resource = target_shape_node.shape_mask
	var new_resource = ShapeMaskResource.new()
	new_resource.set_image_from_editor(_working_image)
	undo_redo.create_action("Paint Shape Mask")
	undo_redo.add_do_property(target_shape_node, "shape_mask", new_resource)
	undo_redo.add_undo_property(target_shape_node, "shape_mask", previous_resource)
	undo_redo.commit_action()
	hide()

func _on_cancel_pressed() -> void:
	hide()
