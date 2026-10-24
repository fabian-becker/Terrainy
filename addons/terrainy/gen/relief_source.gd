@tool
@icon("res://addons/terrainy/icons/relief.svg")
class_name TerrainReliefSource
extends Resource

## One entry of a [TerrainFieldNode] relief stack: noise on top of the profile.
##
## The noise is sampled in the field's local XZ space (it moves and rotates with the field),
## rotated by [member rotation] and stretched by [member scale] (anisotropic frequency: a scale
## of (4, 1) makes features four times longer along local X — dune ridges, elongated basins).
## The effective seed is derived from the generator's `noise_seed` and [member noise_seed], so
## the generator owns determinism.

enum Blend { ADD, MULTIPLY }

@export var noise: FastNoiseLite = _default_noise():
	set(value):
		if noise and noise.changed.is_connected(emit_changed):
			noise.changed.disconnect(emit_changed)
		noise = value
		if noise:
			noise.changed.connect(emit_changed)
		emit_changed()

## Amplitude of the noise in meters (noise values are in -1..1).
@export var weight: float = 4.0:
	set(value):
		weight = value
		emit_changed()

## Constant added to the weighted noise.
@export var offset: float = 0.0:
	set(value):
		offset = value
		emit_changed()

## Add: shape += noise. Multiply: shape *= 1 + noise.
@export var blend: Blend = Blend.ADD:
	set(value):
		blend = value
		emit_changed()

## Sampling stretch along local X/Z (> 1 = longer features).
@export var scale: Vector2 = Vector2.ONE:
	set(value):
		scale = Vector2(maxf(absf(value.x), 0.0001), maxf(absf(value.y), 0.0001))
		emit_changed()

@export_range(-360, 360, 0.1, "radians_as_degrees") var rotation: float = 0.0:
	set(value):
		rotation = value
		emit_changed()

## Multiply the noise by the profile value, so it fades with the shape toward the edges.
@export var follow_profile: bool = false:
	set(value):
		follow_profile = value
		emit_changed()

## Combined with the generator's noise_seed.
@export var noise_seed: int = 0:
	set(value):
		noise_seed = value
		emit_changed()

@export var enabled: bool = true:
	set(value):
		enabled = value
		emit_changed()

func _init() -> void:
	if noise:
		noise.changed.connect(emit_changed)

static func _default_noise() -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.02
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 4
	return n

## Effective seed for a generator seed (stable across runs and platforms).
func effective_seed(generator_seed: int) -> int:
	return int(hash([generator_seed, noise_seed]) & 0x7fffffff)
