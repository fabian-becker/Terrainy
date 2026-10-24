@tool
@icon("res://addons/terrainy/icons/modifier.svg")
class_name TerrainRemapModifier
extends TerrainModifier

## Remaps heights from [input_min, input_max] to [output_min, output_max], optionally through a
## [member curve] (x = normalized input, y = normalized output).

const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")

@export var input_min: float = 0.0:
	set(value):
		input_min = value
		_commit()

@export var input_max: float = 32.0:
	set(value):
		input_max = value
		_commit()

@export var output_min: float = 0.0:
	set(value):
		output_min = value
		_commit()

@export var output_max: float = 32.0:
	set(value):
		output_max = value
		_commit()

@export var curve: Curve:
	set(value):
		_track_resource(curve, value)
		curve = value
		_commit()

## Clamp the normalized input to 0..1 (off = extrapolate linearly; the curve is then ignored).
@export var clamp_input: bool = true:
	set(value):
		clamp_input = value
		_commit()

func _fill_snapshot(snap, _context: Dictionary) -> void:
	snap.op = ModifierSnapshot.Op.REMAP
	snap.in_min = input_min
	snap.in_max = input_max
	snap.out_min = output_min
	snap.out_max = output_max
	snap.clamp_input = clamp_input
	snap.remap_lut = CurveLut.bake(curve) if curve else PackedFloat32Array()

func _params_signature() -> String:
	return "%s|%s|%s|%s|%d|%s" % [var_to_str(input_min), var_to_str(input_max), var_to_str(output_min),
		var_to_str(output_max), int(clamp_input), Signature.of_object(curve) if curve else "-"]
