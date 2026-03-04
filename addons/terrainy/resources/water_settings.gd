@tool
class_name WaterSettings
extends Resource

## Resource for water appearance settings that can be shared across multiple WaterNodes.

signal settings_changed

@export_group("Water Colors")
## Color for shallow water areas
@export var water_color_shallow: Color = Color(0.2, 0.6, 0.8, 0.8):
	set(value):
		water_color_shallow = value
		settings_changed.emit()

## Color for deep water areas
@export var water_color_deep: Color = Color(0.05, 0.2, 0.4, 0.95):
	set(value):
		water_color_deep = value
		settings_changed.emit()

@export_group("Depth")
## Depth at which water color transitions to "deep"
@export_range(0.1, 50.0) var depth_max: float = 10.0:
	set(value):
		depth_max = value
		settings_changed.emit()

@export_group("Foam")
## Width of foam band at shoreline
@export_range(0.0, 10.0) var foam_width: float = 2.0:
	set(value):
		foam_width = value
		settings_changed.emit()

## Intensity of foam effect
@export_range(0.0, 1.0) var foam_intensity: float = 0.8:
	set(value):
		foam_intensity = value
		settings_changed.emit()

## Tiling scale for foam texture
@export_range(0.1, 10.0) var foam_tiling: float = 1.0:
	set(value):
		foam_tiling = value
		settings_changed.emit()

## Optional foam texture
@export var foam_texture: Texture2D:
	set(value):
		foam_texture = value
		settings_changed.emit()

@export_group("Waves")
## Speed of wave animation
@export_range(0.0, 5.0) var wave_speed: float = 1.0:
	set(value):
		wave_speed = value
		settings_changed.emit()

## Height of wave displacement
@export_range(0.0, 2.0) var wave_height: float = 0.2:
	set(value):
		wave_height = value
		settings_changed.emit()

## Frequency of waves
@export_range(0.1, 10.0) var wave_frequency: float = 2.0:
	set(value):
		wave_frequency = value
		settings_changed.emit()

## Tiling scale for wave normal texture
@export_range(0.1, 20.0) var wave_tiling: float = 1.0:
	set(value):
		wave_tiling = value
		settings_changed.emit()

## Normal map for wave detail
@export var wave_normal: Texture2D:
	set(value):
		wave_normal = value
		settings_changed.emit()

## Strength of normal map effect
@export_range(0.0, 2.0) var normal_strength: float = 0.5:
	set(value):
		normal_strength = value
		settings_changed.emit()

@export_group("Material")
## Custom shader material (overrides all above settings)
@export var custom_material: ShaderMaterial:
	set(value):
		custom_material = value
		settings_changed.emit()

## Create a WaterSettings from default values
static func create_default() -> WaterSettings:
	return WaterSettings.new()