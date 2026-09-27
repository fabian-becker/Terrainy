extends SceneTree

## Probe: how much of the CPU smoothing cost is the per-pixel recomputation of the
## per-sample polar offsets?
##
## _apply_smoothing_pass computes, for every pixel and every sample:
##     angle     = (s / count) * TAU
##     offset_x  = (cos(angle) * sample_radius) / step_x
##     offset_y  = (sin(angle) * sample_radius) / step_y
## None of those depend on x or y -- only on `s` -- so they are loop-invariant across the
## whole image and could be baked into a small array before the pixel loop.
##
## This measures the current shape against the hoisted shape on identical data.

const SAMPLES := {
	"LIGHT(4)": [4, 0.5],
	"MEDIUM(8)": [8, 1.0],
	"HEAVY(12)": [12, 1.5],
}
const TERRAIN_BOUNDS := Rect2(-512.0, -512.0, 1024.0, 1024.0)


func _process(_delta: float) -> bool:
	print("Smoothing pass: per-pixel polar-offset recomputation vs hoisted\n")

	for res in [257, 513]:
		var width: int = res
		var height: int = res
		var data := _make_noise(res)
		var radius := 8.0
		var step_x := TERRAIN_BOUNDS.size.x / float(width - 1)
		var step_y := TERRAIN_BOUNDS.size.y / float(height - 1)

		for label in SAMPLES:
			var sample_count: int = SAMPLES[label][0]
			var sample_radius: float = radius * float(SAMPLES[label][1])

			var current := _best(3, func() -> void:
				_smoothing_current(data, width, height, step_x, step_y, sample_count, sample_radius)
			)
			var hoisted := _best(3, func() -> void:
				_smoothing_hoisted(data, width, height, step_x, step_y, sample_count, sample_radius)
			)
			print("  %dx%d %-10s current %9.2f ms | hoisted %9.2f ms | %.2fx" % [
				res, res, label, current, hoisted, current / maxf(hoisted, 0.001)
			])
		print("")

	print("Reference (measured in benchmark.gd):")
	print("  smoothing_r2 @ 513x513 (LIGHT, r=2)  = 932 ms")
	print("  smoothing_r8 @ 513x513 (HEAVY, r=8)  = 2711 ms")
	quit(0)
	return true


## Verbatim shape of ModifierPipeline._apply_smoothing_pass.
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
			var center_h := data[idx]
			var total_h := center_h
			var total_w := 1.0
			for s in sample_count:
				var angle := (s / float(sample_count)) * TAU
				var offset_x := (cos(angle) * sample_radius) / step_x
				var offset_y := (sin(angle) * sample_radius) / step_y
				var sx := clampi(x + int(round(offset_x)), 0, width - 1)
				var sy := clampi(y + int(round(offset_y)), 0, height - 1)
				var sample_h := data[sy * width + sx]
				var dist := sqrt(offset_x * offset_x + offset_y * offset_y)
				var w: float = max(0.0, 1.0 - dist * inv_norm)
				total_h += sample_h * w
				total_w += w
			result[idx] = total_h / total_w
	return result


## Same math, with the per-sample offsets/factors computed once up front.
func _smoothing_hoisted(
	data: PackedFloat32Array, width: int, height: int,
	step_x: float, step_y: float, sample_count: int, sample_radius: float
) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(data.size())
	var inv_step_min: float = 1.0 / min(step_x, step_y)
	var inv_norm: float = 1.0 / (sample_radius * inv_step_min * 1.5)

	# Loop-invariant per sample: integer pixel offsets and the weight.
	var offs_x := PackedInt32Array()
	var offs_y := PackedInt32Array()
	var ws := PackedFloat32Array()
	offs_x.resize(sample_count)
	offs_y.resize(sample_count)
	ws.resize(sample_count)
	for s in sample_count:
		var angle := (s / float(sample_count)) * TAU
		var offset_x := (cos(angle) * sample_radius) / step_x
		var offset_y := (sin(angle) * sample_radius) / step_y
		offs_x[s] = int(round(offset_x))
		offs_y[s] = int(round(offset_y))
		ws[s] = max(0.0, 1.0 - sqrt(offset_x * offset_x + offset_y * offset_y) * inv_norm)

	for y in height:
		for x in width:
			var idx := y * width + x
			var center_h := data[idx]
			var total_h := center_h
			var total_w := 1.0
			for s in sample_count:
				var sx := clampi(x + offs_x[s], 0, width - 1)
				var sy := clampi(y + offs_y[s], 0, height - 1)
				total_h += data[sy * width + sx] * ws[s]
				total_w += ws[s]
			result[idx] = total_h / total_w
	return result


func _make_noise(res: int) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(res * res)
	for y in res:
		for x in res:
			data[y * res + x] = sin(float(x) * 0.05) * cos(float(y) * 0.05) * 30.0
	return data


func _best(samples: int, body: Callable) -> float:
	var best := INF
	for i in samples:
		var start := Time.get_ticks_usec()
		body.call()
		best = min(best, float(Time.get_ticks_usec() - start) / 1000.0)
	return best
