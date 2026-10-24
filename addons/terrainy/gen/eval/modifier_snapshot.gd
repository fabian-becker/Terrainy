@tool
extends RefCounted

## Immutable, worker-safe snapshot of a [TerrainModifier]. [method apply] modifies a map in place:
## the owner's own map (Local), a group composite (Group) or the terrain composite (Global).
## Every op is `h = lerp(h, op(h), strength * mask)`.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")

enum Op { SMOOTH, TERRACE, CLAMP, REMAP, FLATTEN }

var op: int = Op.SMOOTH
var strength: float = 1.0
var mask = null  # MaskSnapshot or null

# Smooth
var radius: float = 2.0
var iterations: int = 1
# Terrace
var step_height: float = 5.0
var smoothness: float = 0.2
var terrace_offset: float = 0.0
# Clamp
var use_min: bool = true
var use_max: bool = true
var clamp_min: float = 0.0
var clamp_max: float = 50.0
# Remap
var in_min: float = 0.0
var in_max: float = 50.0
var out_min: float = 0.0
var out_max: float = 50.0
var remap_lut: PackedFloat32Array = PackedFloat32Array()
var clamp_input: bool = true
# Flatten
var target_height: float = 0.0
## World XZ of the modifier, the point where [method apply] reads the map's datum.
var center: Vector2 = Vector2.ZERO
var inv_xform: Transform3D = Transform3D.IDENTITY
var shape: int = 0
var half: Vector2 = Vector2.ONE
var falloff_lut: PackedFloat32Array = PackedFloat32Array()
var bounds: Rect2 = Rect2()
var has_bounds: bool = false

var signature: String = ""

func uses_target_height() -> bool:
	return op == Op.FLATTEN

## Apply in place. [param target_offset] / [param target_scale] rebase [member target_height]
## when [param map] is not the terrain composite itself: a group composite and an additive
## field's own map hold deltas over the enclosing composite, so the world height the gizmo
## draws must be converted with `target_height * target_scale + target_offset`.
func apply(map, grid, target_offset: float = 0.0, target_scale: float = 1.0) -> void:
	if map == null or map.is_empty() or strength <= 0.0:
		return
	var target_level := target_height * target_scale + target_offset
	var rect: Rect2i = map.rect
	if has_bounds:
		rect = rect.intersection(grid.rect_for_world(bounds, 1))
		if rect.size.x <= 0 or rect.size.y <= 0:
			return
	var weights := PackedFloat32Array()
	weights.resize(rect.size.x * rect.size.y)
	weights.fill(clampf(strength, 0.0, 1.0))
	if mask != null:
		var m: PackedFloat32Array = mask.weights(grid, rect, map)
		for i in weights.size():
			weights[i] *= m[i]
	if op == Op.FLATTEN:
		_flatten_weights(grid, rect, weights)
	var source: PackedFloat32Array = map.data
	var processed := PackedFloat32Array()
	if op == Op.SMOOTH:
		processed = map.blurred(rect, radius, grid.cell, iterations)
	# Group composites track coverage so the group only blends where its children acted. A
	# modifier is not a blend, so it must mark the area it touched itself -- otherwise a group
	# whose only child is a flatten would contribute nothing at all.
	var coverage = map.get_meta("coverage") if map.has_meta("coverage") else null
	var cw: int = coverage.rect.size.x if coverage != null else 0
	var c0: int = (rect.position.y - coverage.rect.position.y) * cw + (rect.position.x - coverage.rect.position.x) if coverage != null else 0
	var mw: int = map.rect.size.x
	var w := rect.size.x
	for y in rect.size.y:
		var row: int = (rect.position.y + y - map.rect.position.y) * mw + (rect.position.x - map.rect.position.x)
		var crow: int = c0 + y * cw
		for x in w:
			var k := y * w + x
			var wt := weights[k]
			if wt <= 0.0:
				continue
			if coverage != null:
				var ci := crow + x
				var cwt := minf(wt, 1.0)
				if cwt > coverage.data[ci]:
					coverage.data[ci] = cwt
			var i := row + x
			var h := source[i]
			var t: float
			match op:
				Op.SMOOTH:
					t = processed[k]
				Op.TERRACE:
					t = _terrace(h)
				Op.CLAMP:
					t = h
					if use_min:
						t = maxf(t, clamp_min)
					if use_max:
						t = minf(t, clamp_max)
				Op.REMAP:
					t = _remap(h)
				_:
					t = target_level
			source[i] = h + (t - h) * wt

func _terrace(h: float) -> float:
	if step_height <= 0.0001:
		return h
	var n := (h - terrace_offset) / step_height
	var level := floorf(n)
	var frac := n - level
	var q := level
	if smoothness > 0.0001:
		q += Raster.smoothstep01(1.0 - smoothness, 1.0, frac)
	return q * step_height + terrace_offset

func _remap(h: float) -> float:
	var span := in_max - in_min
	var n := (h - in_min) / span if absf(span) > 1e-6 else 0.0
	if clamp_input:
		n = clampf(n, 0.0, 1.0)
	if not remap_lut.is_empty():
		n = CurveLut.sample(remap_lut, clampf(n, 0.0, 1.0)) if clamp_input else n
	return out_min + n * (out_max - out_min)

func _flatten_weights(grid, rect: Rect2i, weights: PackedFloat32Array) -> void:
	var w := rect.size.x
	for y in rect.size.y:
		var gz: float = grid.origin.y + (rect.position.y + y) * grid.cell
		for x in w:
			var k := y * w + x
			if weights[k] <= 0.0:
				continue
			var gx: float = grid.origin.x + (rect.position.x + x) * grid.cell
			var l := inv_xform * Vector3(gx, 0.0, gz)
			var d := Raster.shape_distance(shape, l.x, l.z, half)
			if d >= 1.0:
				weights[k] = 0.0
				continue
			if not falloff_lut.is_empty():
				weights[k] *= CurveLut.sample(falloff_lut, 1.0 - d)
