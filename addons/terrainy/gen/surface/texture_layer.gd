@tool
@icon("res://addons/terrainy/icons/texture_layer.svg")
class_name TerrainyTextureLayer
extends Resource

## A texture layer of the Terrainy 2 palette (ported from 0.7 TerrainTextureLayer): world-space
## height + slope blending, PBR maps. Its weight plane (texture painting + surface contributions)
## is addressed by its index in TerrainGenerator.texture_layers.

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

## Blend mode for this layer:
## Normal = weighted average against other Normal layers,
## Add = layer contributes additively on top of the blended base,
## Multiply = layer modulates (tints/darkens) the blended result
@export_enum("Normal", "Add", "Multiply") var blend_mode: int = 0:
	set(value):
		blend_mode = value
		layer_changed.emit()
