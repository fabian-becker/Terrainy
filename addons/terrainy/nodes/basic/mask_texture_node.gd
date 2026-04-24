@tool
class_name MaskTextureNode
extends TerrainFeatureNode

## A non-destructive mask node that defines an influence area using a texture.
## Does not affect terrain height. Instead, place it as a parent of ScatterNodes
## (or other TerrainFeatureNodes) to restrict their influence to the masked area.
##
## Usage:
##   1. Assign any Texture2D (including CompressedTexture2D) to the inherited
##      "Mask Texture" property.
##   2. Place scatter nodes or other features as children.
##   3. White = full influence, black = no influence.

func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint() and name.is_empty():
		name = "MaskTexture"

func prepare_evaluation_context() -> EvaluationContext:
	return EvaluationContext.from_feature(self)

func get_height_at_safe(_world_pos: Vector3, _context: EvaluationContext) -> float:
	return 0.0

func affects_heightmap() -> bool:
	return false

func get_gpu_param_pack() -> Dictionary:
	return _build_gpu_param_pack(FeatureType.MASK_TEXTURE, PackedFloat32Array(), PackedInt32Array())
