@tool
@icon("res://addons/terrainy/icons/mask.svg")
class_name TerrainMaskTexture
extends TerrainMaskResource

## Texture mask: the red channel (or luminance) of an image, stretched over a rectangle.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")

@export var texture: Texture2D:
	set(value):
		texture = value
		emit_changed()

@export var use_luminance: bool = false:
	set(value):
		use_luminance = value
		emit_changed()

## World size the texture covers (X, Z), centered on the owner + offset.
@export var size: Vector2 = Vector2(64, 64):
	set(value):
		size = value.max(Vector2(0.01, 0.01))
		emit_changed()

@export var offset: Vector2 = Vector2.ZERO:
	set(value):
		offset = value
		emit_changed()

@export_range(-360, 360, 0.1, "radians_as_degrees") var rotation: float = 0.0:
	set(value):
		rotation = value
		emit_changed()

func make_snapshot(context: Dictionary) -> RefCounted:
	var snap := MaskSnapshot.new()
	_fill_common(snap, context)
	snap.kind = MaskSnapshot.Kind.TEXTURE
	var xform := _space_xform(context) * Transform3D(Basis(Vector3.UP, rotation), Vector3(offset.x, 0.0, offset.y))
	snap.inv_xform = xform.affine_inverse()
	snap.half = size * 0.5
	snap.bounds = Raster.shape_bounds(xform, snap.half)
	if texture:
		var image := texture.get_image()
		if image:
			snap.texture_data = Raster.image_channel(image, use_luminance)
			snap.texture_size = image.get_size()
	return snap
