@tool
@icon("res://addons/terrainy/icons/texture_layer.svg")
class_name TerrainySurfaceContribution
extends Resource

## Paints one [TerrainyTextureLayer] where the owning field acts (ported from 0.7
## TerrainSurfaceContribution).
##
## The contribution's control value is the exact weight the height pass blended the owning
## field with (domain falloff x strength x mask), so the geometry a field moved and the texture
## it paints always agree. Stage 6 folds contributions into the per-layer weight planes; TEXTURE
## paint layers are applied after them and win where painted.
##
## A layer that is not part of TerrainGenerator.texture_layers is appended to the palette
## automatically ("contribution-owned": it only shows where a contribution or paint puts it).

signal contribution_changed

enum Mode {
	## Claim the surface for the layer (takeover, settled after the palette is normalized).
	REPLACE,
	## Add to the layer's palette weight.
	ADD,
	## Scale the layer's palette weight down.
	SUPPRESS,
}

@export var enabled: bool = true:
	set(value):
		enabled = value
		_commit()

@export var texture_layer: TerrainyTextureLayer = null:
	set(value):
		if texture_layer and texture_layer.layer_changed.is_connected(_commit):
			texture_layer.layer_changed.disconnect(_commit)
		texture_layer = value
		if texture_layer:
			texture_layer.layer_changed.connect(_commit)
		_commit()

@export var mode: Mode = Mode.REPLACE:
	set(value):
		mode = value
		_commit()

@export_range(0.0, 1.0) var strength: float = 1.0:
	set(value):
		strength = clampf(value, 0.0, 1.0)
		_commit()

## Scale the claim by the target layer's own height/slope blend (0.7 respect_layer_gate).
@export var respect_layer_gate: bool = false:
	set(value):
		respect_layer_gate = value
		_commit()

func is_active() -> bool:
	return enabled and texture_layer != null

func _commit() -> void:
	emit_changed()
	contribution_changed.emit()
