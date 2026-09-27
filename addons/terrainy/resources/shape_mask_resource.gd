@tool
class_name ShapeMaskResource
extends Resource

## Paintable top-view mask for ShapeNode.
## Pixel semantics: black = full contribution, white = none.

const DEFAULT_RESOLUTION := Vector2i(256, 256)

@export var resolution: Vector2i = DEFAULT_RESOLUTION:
	set(value):
		var clamped = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		if resolution == clamped:
			return
		resolution = clamped
		_resize_image_preserve()
		emit_changed()

@export var mask_image: Image:
	set(value):
		if value == null:
			mask_image = _create_default_image(resolution)
			emit_changed()
			return
		mask_image = value.duplicate()
		resolution = Vector2i(mask_image.get_width(), mask_image.get_height())
		emit_changed()

func _init() -> void:
	mask_image = _create_default_image(resolution)

func ensure_initialized(target_resolution: Vector2i = DEFAULT_RESOLUTION) -> void:
	if target_resolution.x > 0 and target_resolution.y > 0:
		resolution = Vector2i(maxi(target_resolution.x, 1), maxi(target_resolution.y, 1))
	if mask_image == null or mask_image.get_width() <= 0 or mask_image.get_height() <= 0:
		mask_image = _create_default_image(resolution)
		emit_changed()
		return
	if mask_image.get_width() != resolution.x or mask_image.get_height() != resolution.y:
		_resize_image_preserve()
		emit_changed()

func clear_to_white() -> void:
	ensure_initialized()
	mask_image.fill(Color.WHITE)
	emit_changed()

func set_resolution(new_resolution: Vector2i) -> void:
	resolution = new_resolution

func get_image_copy() -> Image:
	ensure_initialized()
	return mask_image.duplicate()

func set_image_from_editor(image: Image) -> void:
	if image == null:
		return
	mask_image = image.duplicate()
	resolution = Vector2i(mask_image.get_width(), mask_image.get_height())
	emit_changed()

func _resize_image_preserve() -> void:
	if mask_image == null:
		mask_image = _create_default_image(resolution)
		return
	if mask_image.get_width() == resolution.x and mask_image.get_height() == resolution.y:
		return
	mask_image.resize(resolution.x, resolution.y, Image.INTERPOLATE_BILINEAR)

func _create_default_image(size: Vector2i) -> Image:
	var img = Image.create(size.x, size.y, false, Image.FORMAT_L8)
	img.fill(Color.WHITE)
	return img
