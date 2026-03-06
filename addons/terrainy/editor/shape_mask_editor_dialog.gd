@tool
class_name ShapeMaskEditorDialog
extends ConfirmationDialog

const ShapeMaskResource = preload("res://addons/terrainy/resources/shape_mask_resource.gd")

enum BrushMode {
	DRAW,
	ERASE
}

var target_shape_node: ShapeNode = null
var undo_redo: EditorUndoRedoManager = null

var _working_image: Image = null
var _canvas_texture: ImageTexture = null
var _is_painting: bool = false

var _brush_mode: int = BrushMode.DRAW
var _brush_size: int = 24
var _brush_strength: float = 0.5

var _canvas: TextureRect
var _mode_option: OptionButton
var _size_slider: HSlider
var _strength_slider: HSlider
var _width_spin: SpinBox
var _height_spin: SpinBox

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
	add_child(root)

	var toolbar = HBoxContainer.new()
	root.add_child(toolbar)

	_mode_option = OptionButton.new()
	_mode_option.add_item("Draw")
	_mode_option.add_item("Erase")
	_mode_option.item_selected.connect(_on_mode_selected)
	toolbar.add_child(_mode_option)

	_size_slider = HSlider.new()
	_size_slider.min_value = 1
	_size_slider.max_value = 96
	_size_slider.step = 1
	_size_slider.value = _brush_size
	_size_slider.custom_minimum_size = Vector2(180, 0)
	_size_slider.value_changed.connect(_on_size_changed)
	toolbar.add_child(_size_slider)

	var size_label = Label.new()
	size_label.text = "Brush Size"
	toolbar.add_child(size_label)

	_strength_slider = HSlider.new()
	_strength_slider.min_value = 0.01
	_strength_slider.max_value = 1.0
	_strength_slider.step = 0.01
	_strength_slider.value = _brush_strength
	_strength_slider.custom_minimum_size = Vector2(180, 0)
	_strength_slider.value_changed.connect(_on_strength_changed)
	toolbar.add_child(_strength_slider)

	var strength_label = Label.new()
	strength_label.text = "Strength"
	toolbar.add_child(strength_label)

	var resize_row = HBoxContainer.new()
	root.add_child(resize_row)

	_width_spin = SpinBox.new()
	_width_spin.min_value = 8
	_width_spin.max_value = 2048
	_width_spin.step = 1
	_width_spin.value = 256
	resize_row.add_child(_width_spin)

	_height_spin = SpinBox.new()
	_height_spin.min_value = 8
	_height_spin.max_value = 2048
	_height_spin.step = 1
	_height_spin.value = 256
	resize_row.add_child(_height_spin)

	var resize_button = Button.new()
	resize_button.text = "Resize"
	resize_button.pressed.connect(_on_resize_pressed)
	resize_row.add_child(resize_button)

	var clear_button = Button.new()
	clear_button.text = "Clear"
	clear_button.pressed.connect(_on_clear_pressed)
	resize_row.add_child(clear_button)

	_canvas = TextureRect.new()
	_canvas.custom_minimum_size = Vector2(560, 560)
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.stretch_mode = TextureRect.STRETCH_SCALE
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.gui_input.connect(_on_canvas_input)
	root.add_child(_canvas)

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

func _on_mode_selected(index: int) -> void:
	_brush_mode = index

func _on_size_changed(value: float) -> void:
	_brush_size = int(value)

func _on_strength_changed(value: float) -> void:
	_brush_strength = value

func _on_resize_pressed() -> void:
	if _working_image == null:
		return
	var new_size = Vector2i(int(_width_spin.value), int(_height_spin.value))
	if new_size.x < 1 or new_size.y < 1:
		return
	if _working_image.get_width() == new_size.x and _working_image.get_height() == new_size.y:
		return
	_working_image.resize(new_size.x, new_size.y, Image.INTERPOLATE_BILINEAR)
	_refresh_canvas()

func _on_clear_pressed() -> void:
	if _working_image == null:
		return
	_working_image.fill(Color.WHITE)
	_refresh_canvas()

func _on_canvas_input(event: InputEvent) -> void:
	if _working_image == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_is_painting = event.pressed
		if _is_painting:
			_stamp_at_canvas_pos(event.position)
			_refresh_canvas()
	elif event is InputEventMouseMotion and _is_painting and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_stamp_at_canvas_pos(event.position)
		_refresh_canvas()

func _stamp_at_canvas_pos(mouse_pos: Vector2) -> void:
	if _canvas.size.x <= 0.0 or _canvas.size.y <= 0.0:
		return
	var uv = Vector2(mouse_pos.x / _canvas.size.x, mouse_pos.y / _canvas.size.y)
	uv = uv.clamp(Vector2.ZERO, Vector2.ONE)
	var img_x = int(round(uv.x * float(_working_image.get_width() - 1)))
	var img_y = int(round(uv.y * float(_working_image.get_height() - 1)))
	_stamp_brush(Vector2i(img_x, img_y))

func _stamp_brush(center: Vector2i) -> void:
	var radius = max(1, _brush_size / 2)
	var target_gray = 0.0 if _brush_mode == BrushMode.DRAW else 1.0
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
			var amount = _brush_strength * falloff
			var current = _working_image.get_pixel(x, y).r
			var next = lerp(current, target_gray, amount)
			_working_image.set_pixel(x, y, Color(next, next, next, 1.0))

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
