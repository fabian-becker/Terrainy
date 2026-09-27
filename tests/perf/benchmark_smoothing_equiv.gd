extends SceneTree

## Verifies whether the hoisted smoothing loop can reproduce the current output exactly.
##
## An optimization that changes the terrain is not an optimization, so this compares actual
## pixels instead of trusting the timings. Two hoisting variants are tested, because the
## container decides whether the result stays bit-identical to the current implementation:
##
##   A) weights in a PackedFloat32Array -> rounds every weight to 32-bit
##   B) weights in a plain Array (float64) -> keeps full double precision
##
## The current code keeps `w` in a local double, so only B can match it bit for bit.

const CONFIGS := {
	"LIGHT r2": [4, 2.0, 0.5],
	"MEDIUM r4": [8, 4.0, 1.0],
	"HEAVY r8": [12, 8.0, 1.5],
}
const TERRAIN_BOUNDS := Rect2(-512.0, -512.0, 1024.0, 1024.0)


func _process(_delta: float) -> bool:
	print("Smoothing equivalence: current vs hoisted (exact float equality)\n")
	var bad_f32 := 0
	var bad_f64 := 0

	for res in [129, 257, 513]:
		var width: int = res
		var height: int = res
		var data := _make_noise(res)
		var step_x := TERRAIN_BOUNDS.size.x / float(width - 1)
		var step_y := TERRAIN_BOUNDS.size.y / float(height - 1)

		for label in CONFIGS:
			var sample_count: int = CONFIGS[label][0]
			var sample_radius: float = float(CONFIGS[label][1]) * float(CONFIGS[label][2])

			var base := _smoothing_current(data, width, height, step_x, step_y, sample_count, sample_radius)
			var f32 := _smoothing_hoisted(data, width, height, step_x, step_y, sample_count, sample_radius, true)
			var f64 := _smoothing_hoisted(data, width, height, step_x, step_y, sample_count, sample_radius, false)

			var s32 := _compare(base, f32)
			var s64 := _compare(base, f64)
			if s32[0] != 0:
				bad_f32 += 1
			if s64[0] != 0:
				bad_f64 += 1

			print("  %dx%d %-10s  f32-weights: %-9s (n=%d, maxdiff %.9f)  |  f64-weights: %-9s (n=%d, maxdiff %.9f)" % [
				res, res, label,
				"IDENTICAL" if s32[0] == 0 else "DIFFERS", s32[0], s32[1],
				"IDENTICAL" if s64[0] == 0 else "DIFFERS", s64[0], s64[1],
			])
		print("")

	print("--------------------------------------------------------------------")
	print("f32-weight variant: %s" % ("all identical" if bad_f32 == 0 else "%d config(s) DIFFER" % bad_f32))
	print("f64-weight variant: %s" % ("all identical" if bad_f64 == 0 else "%d config(s) DIFFER" % bad_f64))
	print("")
	if bad_f64 == 0:
		print("RESULT: hoisting is bit-exact when the weights stay float64 -> safe to apply.")
	else:
		print("RESULT: even the float64 variant differs -> the hoisting is NOT a pure refactor.")
	if bad_f32 != 0:
		print("NOTE:   storing the weights in a PackedFloat32Array loses precision and changes")
		print("        the terrain. The hoisted loop must keep them as doubles.")
	quit(0)
	return true


## Returns [differing_count, max_abs_diff].
func _compare(a: PackedFloat32Array, b: PackedFloat32Array) -> Array:
	var count := 0
	var max_diff := 0.0
	for i in a.size():
		if a[i] != b[i]:
			count += 1
			max_diff = maxf(max_diff, absf(a[i] - b[i]))
	return [count, max_diff]


func _smoothing_current(
	data: PackedFloat32Array, width: int, height: int,
	step_x: float, step_y: float, sample_count: int, sample_radius: float
) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(data.size())
	var inv_step_min: float = 1.0 / min(step_x, step_y)
	var inv_norm: float = 1.0 / (sample_radius * inv_step_min * 1.5)

	for y in height:
		for x in width:
			var idx := y * width + x
			var total_h := data[idx]
			var total_w := 1.0
			for s in sample_count:
				var angle := (s / float(sample_count)) * TAU
				var offset_x := (cos(angle) * sample_radius) / step_x
				var offset_y := (sin(angle) * sample_radius) / step_y
				var sx := clampi(x + int(round(offset_x)), 0, width - 1)
				var sy := clampi(y + int(round(offset_y)), 0, height - 1)
				var dist := sqrt(offset_x * offset_x + offset_y * offset_y)
				var w: float = max(0.0, 1.0 - dist * inv_norm)
				total_h += data[sy * width + sx] * w
				total_w += w
			result[idx] = total_h / total_w
	return result


## The hoisted shape. `use_f32_weights` selects the container under test: a
## PackedFloat32Array (lossy) or a plain Array (float64, matching the local double above).
func _smoothing_hoisted(
	data: PackedFloat32Array, width: int, height: int,
	step_x: float, step_y: float, sample_count: int, sample_radius: float,
	use_f32_weights: bool
) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(data.size())
	var inv_step_min: float = 1.0 / min(step_x, step_y)
	var inv_norm: float = 1.0 / (sample_radius * inv_step_min * 1.5)

	var offs_x := PackedInt32Array()
	var offs_y := PackedInt32Array()
	offs_x.resize(sample_count)
	offs_y.resize(sample_count)
	var ws_f32 := PackedFloat32Array()
	var ws: Array = []
	if use_f32_weights:
		ws_f32.resize(sample_count)
	else:
		ws.resize(sample_count)

	for s in sample_count:
		var angle := (s / float(sample_count)) * TAU
		var offset_x := (cos(angle) * sample_radius) / step_x
		var offset_y := (sin(angle) * sample_radius) / step_y
		offs_x[s] = int(round(offset_x))
		offs_y[s] = int(round(offset_y))
		var w: float = max(0.0, 1.0 - sqrt(offset_x * offset_x + offset_y * offset_y) * inv_norm)
		if use_f32_weights:
			ws_f32[s] = w
		else:
			ws[s] = w

	for y in height:
		for x in width:
			var idx := y * width + x
			var total_h := data[idx]
			var total_w := 1.0
			for s in sample_count:
				var sx := clampi(x + offs_x[s], 0, width - 1)
				var sy := clampi(y + offs_y[s], 0, height - 1)
				var w: float = ws_f32[s] if use_f32_weights else ws[s]
				total_h += data[sy * width + sx] * w
				total_w += w
			result[idx] = total_h / total_w
	return result


func _make_noise(res: int) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(res * res)
	for y in res:
		for x in res:
			data[y * res + x] = sin(float(x) * 0.05) * cos(float(y) * 0.05) * 30.0
	return data
