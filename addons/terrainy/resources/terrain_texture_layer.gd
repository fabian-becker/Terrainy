@tool
class_name TerrainTextureLayer
extends Resource

## A texture layer for terrain rendering with height and slope-based blending

signal layer_changed

## Display name for this layer
@export var layer_name: String = "New Layer":
	set(value):
		layer_name = value
		layer_changed.emit()

@export_group("Textures")
## Albedo (color) texture
@export var albedo_texture: Texture2D:
	set(value):
		albedo_texture = value
		layer_changed.emit()

## Albedo color tint
@export var albedo_color: Color = Color.WHITE:
	set(value):
		albedo_color = value
		layer_changed.emit()

## Normal map texture
@export var normal_texture: Texture2D:
	set(value):
		normal_texture = value
		layer_changed.emit()

## Normal map strength
@export_range(0.0, 2.0) var normal_strength: float = 1.0:
	set(value):
		normal_strength = value
		layer_changed.emit()

## Roughness texture (or constant if null)
@export var roughness_texture: Texture2D:
	set(value):
		roughness_texture = value
		layer_changed.emit()

## Roughness value (used if no texture, or as multiplier)
@export_range(0.0, 1.0) var roughness: float = 1.0:
	set(value):
		roughness = value
		layer_changed.emit()

## Metallic texture (or constant if null)
@export var metallic_texture: Texture2D:
	set(value):
		metallic_texture = value
		layer_changed.emit()

## Metallic value (used if no texture, or as multiplier)
@export_range(0.0, 1.0) var metallic: float = 0.0:
	set(value):
		metallic = value
		layer_changed.emit()

## Ambient occlusion texture
@export var ao_texture: Texture2D:
	set(value):
		ao_texture = value
		layer_changed.emit()

## AO strength
@export_range(0.0, 1.0) var ao_strength: float = 1.0:
	set(value):
		ao_strength = value
		layer_changed.emit()

@export_group("UV Settings")
## UV tiling/scale (meters per texture repeat - larger values = larger texture tiles)
@export var uv_scale: Vector2 = Vector2(10.0, 10.0):
	set(value):
		uv_scale = value
		layer_changed.emit()

## UV offset
@export var uv_offset: Vector2 = Vector2.ZERO:
	set(value):
		uv_offset = value
		layer_changed.emit()

@export_group("Height Blending")
## Minimum height for this layer to appear
@export var height_min: float = -1000.0:
	set(value):
		height_min = value
		layer_changed.emit()

## Maximum height for this layer to appear
@export var height_max: float = 1000.0:
	set(value):
		height_max = value
		layer_changed.emit()

## Curve for height blending (X = normalized height 0-1, Y = weight multiplier)
@export var height_blend_curve: Curve:
	set(value):
		if height_blend_curve and height_blend_curve.changed.is_connected(_on_curve_changed):
			height_blend_curve.changed.disconnect(_on_curve_changed)
		height_blend_curve = value
		if height_blend_curve:
			height_blend_curve.changed.connect(_on_curve_changed)
		layer_changed.emit()

## Falloff distance for height transitions
@export var height_falloff: float = 5.0:
	set(value):
		height_falloff = max(0.0, value)
		layer_changed.emit()

@export_group("Slope Blending")
## Minimum slope angle (degrees) for this layer to appear
@export_range(0.0, 90.0) var slope_min: float = 0.0:
	set(value):
		slope_min = clamp(value, 0.0, 90.0)
		layer_changed.emit()

## Maximum slope angle (degrees) for this layer to appear
@export_range(0.0, 90.0) var slope_max: float = 90.0:
	set(value):
		slope_max = clamp(value, 0.0, 90.0)
		layer_changed.emit()

## Curve for slope blending (X = normalized slope 0-1, Y = weight multiplier)
@export var slope_blend_curve: Curve:
	set(value):
		if slope_blend_curve and slope_blend_curve.changed.is_connected(_on_curve_changed):
			slope_blend_curve.changed.disconnect(_on_curve_changed)
		slope_blend_curve = value
		if slope_blend_curve:
			slope_blend_curve.changed.connect(_on_curve_changed)
		layer_changed.emit()

## Falloff distance for slope transitions (degrees)
@export_range(0.0, 45.0) var slope_falloff: float = 10.0:
	set(value):
		slope_falloff = value
		layer_changed.emit()

@export_group("Layer Settings")
## Overall strength/opacity of this layer
@export_range(0.0, 1.0) var layer_strength: float = 1.0:
	set(value):
		layer_strength = value
		layer_changed.emit()

## Blend mode for this layer
@export_enum("Normal", "Add", "Multiply") var blend_mode: int = 0:
	set(value):
		blend_mode = value
		layer_changed.emit()

func _on_curve_changed() -> void:
	layer_changed.emit()

## Get the blend weight for this layer at a given height and slope
func calculate_blend_weight(height: float, slope_angle: float) -> float:
	var weight: float = 1.0
	
	# Height influence
	if height < height_min - height_falloff:
		weight = 0.0
	elif height < height_min + height_falloff:
		var t = (height - (height_min - height_falloff)) / (height_falloff * 2.0)
		weight *= smoothstep(0.0, 1.0, t)
		if height_blend_curve:
			weight *= height_blend_curve.sample(t)
	
	if height > height_max + height_falloff:
		weight = 0.0
	elif height > height_max - height_falloff:
		var t = ((height_max + height_falloff) - height) / (height_falloff * 2.0)
		weight *= smoothstep(0.0, 1.0, t)
		if height_blend_curve:
			weight *= height_blend_curve.sample(1.0 - t)
	
	# Slope influence
	if slope_angle < slope_min - slope_falloff:
		weight = 0.0
	elif slope_angle < slope_min + slope_falloff:
		var t = (slope_angle - (slope_min - slope_falloff)) / (slope_falloff * 2.0)
		weight *= smoothstep(0.0, 1.0, t)
		if slope_blend_curve:
			weight *= slope_blend_curve.sample(t)
	
	if slope_angle > slope_max + slope_falloff:
		weight = 0.0
	elif slope_angle > slope_max - slope_falloff:
		var t = ((slope_max + slope_falloff) - slope_angle) / (slope_falloff * 2.0)
		weight *= smoothstep(0.0, 1.0, t)
		if slope_blend_curve:
			weight *= slope_blend_curve.sample(1.0 - t)
	
	return weight * layer_strength

func smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
