@tool
extends RefCounted

## Immutable, worker-safe snapshot of a [TerrainModifier]. [method apply] modifies a map in place:
## the owner's own map (Local), a group composite (Group) or the terrain composite (Global).
## Every op is `h = lerp(h, op(h), strength * mask)`.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")
const BandTask = preload("res://addons/terrainy/gen/eval/band_task.gd")

## Fewest rows a band may own before splitting a pass stops paying for itself.
const BAND_MIN_ROWS: int = 8

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
## when [param dest] is not the terrain composite itself: a group composite and an additive
## field's own map hold deltas over the enclosing composite, so the world height the gizmo
## draws must be converted with `target_height * target_scale + target_offset`.
##
## [param threads] spreads the passes over the worker pool: every pass (mask, flatten, blur,
## merge) writes its own rows of the map, so the bands never touch each other's pixels.
func apply(dest, grid, target_offset: float = 0.0, target_scale: float = 1.0, threads: int = 1) -> void:
	if dest == null or dest.is_empty() or strength <= 0.0:
		return
	var target_level := target_height * target_scale + target_offset
	var rect: Rect2i = dest.rect
	# Bound the pass: a modifier with a footprint, or (when it has none) a mask that is zero outside
	# its own bounds. Without this every unbounded modifier walks the whole grid even when its mask
	# only covers a corridor -- 245k instead of 16.7M samples at 4096 cells.
	if has_bounds:
		rect = rect.intersection(grid.rect_for_world(bounds, 1))
	elif mask != null and mask.bounds.size.x > 0.0 and mask.bounds.size.y > 0.0:
		rect = rect.intersection(grid.rect_for_world(mask.bounds, 1))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var weights := PackedFloat32Array()
	weights.resize(rect.size.x * rect.size.y)
	weights.fill(clampf(strength, 0.0, 1.0))
	if mask != null:
		var m: PackedFloat32Array = mask.weights(grid, rect, dest, threads)
		var bands := BandTask.band_count(rect.size.y, threads, BAND_MIN_ROWS)
		if bands <= 1:
			_mul_rows(weights, m, rect.size.x, 0, rect.size.y)
		else:
			BandTask.run(threads, bands, func(i: int) -> void:
				var rng := BandTask.band_range(rect.size.y, bands, i)
				_mul_rows(weights, m, rect.size.x, rng.x, rng.y))
	if op == Op.FLATTEN:
		_flatten_weights(grid, rect, weights, threads)
	var processed := PackedFloat32Array()
	if op == Op.SMOOTH:
		processed = dest.blurred(rect, radius, grid.cell, iterations, threads)
	# Group composites track coverage so the group only blends where its children acted. A
	# modifier is not a blend, so it must mark the area it touched itself -- otherwise a group
	# whose only child is a flatten would contribute nothing at all.
	var coverage = dest.get_meta("coverage") if dest.has_meta("coverage") else null
	# Everything the merge pass needs is resolved here, on the calling thread: the bands get plain
	# buffers and integers, never a live object to read properties off.
	var cw: int = coverage.rect.size.x if coverage != null else 0
	var c0: int = (rect.position.y - coverage.rect.position.y) * cw + (rect.position.x - coverage.rect.position.x) if coverage != null else 0
	var source: PackedFloat32Array = dest.data
	var cov_data: PackedFloat32Array = coverage.data if coverage != null else PackedFloat32Array()
	var w := rect.size.x
	var mw: int = dest.rect.size.x
	var dest_pos: Vector2i = dest.rect.position
	# A band never writes into a buffer another band reads: each one fills a private row block that
	# this frame stitches back. That needs the rect to own whole rows of the target and the map to
	# carry no coverage bookkeeping; anything else merges in place on this thread.
	if w != mw or not cov_data.is_empty():
		_merge_rows(source, PackedFloat32Array(), weights, processed, cov_data, cw, c0, rect,
			dest_pos, mw, target_level, 0, rect.size.y)
		return
	var bands := BandTask.band_count(rect.size.y, threads, BAND_MIN_ROWS)
	if bands <= 1:
		_merge_rows(source, PackedFloat32Array(), weights, processed, cov_data, cw, c0, rect,
			dest_pos, mw, target_level, 0, rect.size.y)
		return
	var slots := []
	slots.resize(bands)
	var mutex := Mutex.new()
	BandTask.run(threads, bands, func(i: int) -> void:
		var rng := BandTask.band_range(rect.size.y, bands, i)
		var buf := PackedFloat32Array()
		buf.resize(w * (rng.y - rng.x))
		buf = _merge_rows(source, buf, weights, processed, cov_data, cw, c0, rect, dest_pos,
			mw, target_level, rng.x, rng.y)
		mutex.lock()
		slots[i] = buf
		mutex.unlock())
	var out := PackedFloat32Array()
	var start: int = (rect.position.y - dest_pos.y) * mw
	out.append_array(source.slice(0, start))
	for part in slots:
		out.append_array(part)
	out.append_array(source.slice(start + w * rect.size.y, source.size()))
	dest.data = out

func _mul_rows(weights: PackedFloat32Array, other: PackedFloat32Array, width: int, y0: int, y1: int) -> void:
	var i := y0 * width
	var last := y1 * width
	while i < last:
		weights[i] *= other[i]
		i += 1

## The merge pass for rows `[y0, y1)` of [param rect]: `h = lerp(h, op(h), weight)`.
## Results go to [param buf] when it is sized (`w * rows`, a private block), otherwise straight
## back into [param source] -- which is only safe on one thread.
func _merge_rows(source: PackedFloat32Array, buf: PackedFloat32Array,
		weights: PackedFloat32Array, processed: PackedFloat32Array, cov_data: PackedFloat32Array,
		cw: int, c0: int, rect: Rect2i, dest_pos: Vector2i, mw: int, target_level: float,
		y0: int, y1: int) -> PackedFloat32Array:
	var w := rect.size.x
	var rows := mini(y1, rect.size.y) - y0
	if rows <= 0:
		return buf
	var x_off: int = rect.position.x - dest_pos.x
	var in_place := buf.is_empty()
	if in_place:
		buf = source
	else:
		# Seed the block with the rows it replaces: a pixel the weights skip keeps its height.
		var seed_from: int = (rect.position.y + y0 - dest_pos.y) * mw + x_off
		buf = source.slice(seed_from, seed_from + w * rows)
	var has_cov := cw > 0 and not cov_data.is_empty()
	# Hoisted out of the pixel loop: member reads per sample cost more than the op itself.
	var op_i := op
	var umin := use_min
	var umax := use_max
	var lo := clamp_min
	var hi := clamp_max
	# The two ops that touch every pixel of a big terrain get their own loop with the per-sample
	# helper inlined: a match plus a GDScript call per sample is what made this pass 3-4 us/sample.
	var hot := op_i == Op.REMAP or op_i == Op.CLAMP
	var span := in_max - in_min
	var in_span_ok := absf(span) > 1e-6
	var out_span := out_max - out_min
	var lut_n := remap_lut.size()
	var lut_last := lut_n - 1
	for y in rows:
		var gy := rect.position.y + y0 + y
		var row: int = (gy - dest_pos.y) * mw + x_off
		var crow: int = c0 + (y0 + y) * cw
		var krow: int = (y0 + y) * w
		# Write index: the block is band-local, the in-place pass writes the map itself.
		var wrow: int = row if in_place else y * w
		for x in w:
			var k := krow + x
			var wt := weights[k]
			if wt <= 0.0:
				continue
			if has_cov:
				var ci := crow + x
				var cwt := minf(wt, 1.0)
				if cwt > cov_data[ci]:
					cov_data[ci] = cwt
			var h: float = source[row + x]
			var t: float
			if hot:
				if op_i == Op.CLAMP:
					t = h
					if umin:
						t = maxf(t, lo)
					if umax:
						t = minf(t, hi)
				else:
					# _remap() inlined (identical arithmetic, one fewer call per sample).
					var n := (h - in_min) / span if in_span_ok else 0.0
					if clamp_input:
						n = clampf(n, 0.0, 1.0)
					if lut_n > 0:
						if clamp_input:
							var cx := clampf(n, 0.0, 1.0) * float(lut_last)
							var ci2 := int(cx)
							n = remap_lut[lut_last] if ci2 >= lut_last else lerpf(remap_lut[ci2], remap_lut[ci2 + 1], cx - ci2)
					t = out_min + n * out_span
			else:
				match op_i:
					Op.SMOOTH:
						t = processed[k]
					Op.TERRACE:
						t = _terrace(h)
					_:
						t = target_level
			buf[wrow + x] = h + (t - h) * wt
	return buf

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

func _flatten_weights(grid, rect: Rect2i, weights: PackedFloat32Array, threads: int = 1) -> void:
	var bands := BandTask.band_count(rect.size.y, threads, BAND_MIN_ROWS)
	if bands <= 1:
		_flatten_rows(grid, rect, weights, 0, rect.size.y)
	else:
		BandTask.run(threads, bands, func(i: int) -> void:
			var rng := BandTask.band_range(rect.size.y, bands, i)
			_flatten_rows(grid, rect, weights, rng.x, rng.y))

func _flatten_rows(grid, rect: Rect2i, weights: PackedFloat32Array, y0: int, y1: int) -> void:
	var w := rect.size.x
	for y in range(y0, mini(y1, rect.size.y)):
		var gz: float = grid.origin.y + (rect.position.y + y) * grid.cell
		var row := y * w
		for x in w:
			var k := row + x
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
