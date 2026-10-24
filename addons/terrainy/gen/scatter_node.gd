@tool
@icon("res://addons/terrainy/icons/scatter.svg")
class_name TerrainScatterNode
extends TerrainComposableNode

## Mask-driven prop placement, output as one MultiMeshInstance3D per chunk.
##
## Candidates come from a world-aligned jittered grid (one candidate per `spacing` cell, seeded
## per cell), so placement is deterministic, independent of the chunk layout and stable when
## only a part of the terrain is rebuilt. A candidate survives the hole mask, the slope and
## elevation filters and every mask in [member masks] (their product is the keep probability):
## "trees on grass, not on the painted road" is the same TerrainMaskPath that masked the road.

@export var mesh: Mesh:
	set(value):
		mesh = value
		_scatter_changed()

@export var material_override: Material:
	set(value):
		material_override = value
		_scatter_changed()

## Instances per 100 m^2.
@export_range(0.0, 100.0, 0.01, "or_greater") var density: float = 2.0:
	set(value):
		density = maxf(value, 0.0)
		_scatter_changed()

@export var noise_seed: int = 0:
	set(value):
		noise_seed = value
		_scatter_changed()

@export var masks: Array[TerrainMaskResource] = []:
	set(value):
		for m in masks:
			_track_scatter_resource(m, null)
		masks = value
		for m in masks:
			_track_scatter_resource(null, m)
		_scatter_changed()

@export_group("Filters")
@export_range(0.0, 90.0, 0.1) var slope_min: float = 0.0:
	set(value):
		slope_min = value
		_scatter_changed()
@export_range(0.0, 90.0, 0.1) var slope_max: float = 35.0:
	set(value):
		slope_max = value
		_scatter_changed()
## World elevation range.
@export var elevation_min: float = -10000.0:
	set(value):
		elevation_min = value
		_scatter_changed()
@export var elevation_max: float = 10000.0:
	set(value):
		elevation_max = value
		_scatter_changed()

@export_group("Instances")
@export var scale_min: float = 0.8:
	set(value):
		scale_min = value
		_scatter_changed()
@export var scale_max: float = 1.2:
	set(value):
		scale_max = value
		_scatter_changed()
@export var random_yaw: bool = true:
	set(value):
		random_yaw = value
		_scatter_changed()
@export_range(0.0, 1.0) var align_to_normal: float = 0.0:
	set(value):
		align_to_normal = value
		_scatter_changed()
@export var height_offset: float = 0.0:
	set(value):
		height_offset = value
		_scatter_changed()
@export_range(1, 200000, 1) var max_instances_per_chunk: int = 20000:
	set(value):
		max_instances_per_chunk = value
		_scatter_changed()
@export var cast_shadows: GeometryInstance3D.ShadowCastingSetting = GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
	set(value):
		cast_shadows = value
		_scatter_changed()

func get_unit_kind() -> int:
	return 4  # CompositionPlan.UnitKind.SCATTER

## Scatter never changes heights: it only refreshes its own instances.
func _commit() -> void:
	revision += 1
	_scatter_changed()

func _on_transform_changed() -> void:
	_scatter_changed()

func _track_scatter_resource(old: Resource, new: Resource) -> void:
	if old and old.changed.is_connected(_scatter_changed):
		old.changed.disconnect(_scatter_changed)
	if new and not new.changed.is_connected(_scatter_changed):
		new.changed.connect(_scatter_changed)

func _scatter_changed() -> void:
	var generator := get_generator()
	if generator and is_inside_tree():
		generator.notify_scatter_changed(self)

## Candidate spacing in meters for the configured density.
func spacing() -> float:
	return sqrt(100.0 / maxf(density, 0.0001))
