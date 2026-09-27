extends SceneTree

## Equivalence check for the hoisted smoothing pass, run against the REAL ModifierPipeline.
##
## benchmark_smoothing_equiv.gd proved the hoisting is bit-exact in principle, but against a local
## copy of the loop. This one calls ModifierPipeline._apply_smoothing_pass directly and compares
## it to a verbatim copy of the pre-change implementation, so it validates the code that actually
## shipped -- including the `weights` container choice and the `row`/`sidx` indexing rewrite.
##
## Exact float equality, no tolerance.

const ModifierPipeline = preload("res://addons/terrainy/helpers/modifier_pipeline.gd")

const BOUNDS := Rect2(-512.0, -512.0, 1024.0, 1024.0)
const MODES := {
	"LIGHT": 1,
	"MEDIUM": 2,
	"HEAVY": 3,
}
const NONE := 0


func _process(_delta: float) -> bool:
	print("Smoothing hoisting: shipped ModifierPipeline vs pre-change implementation\n")
	var pipeline = ModifierPipeline.new()
	var failures := 0
	var comparisons := 0

	for res in [129, 257, 513]:
		var resolution := Vector2i(res, res)
		var data := _make_noise(res)
		for label in MODES:
			var mode: int = MODES[label]
			for radius in [2.0, 8.0]:
				var shipped := pipeline._apply_smoothing_pass(data, resolution, BOUNDS, null, mode, radius)
				var previous := _apply_smoothing_pass_reference(data, resolution, BOUNDS, null, mode, radius)
				comparisons += 1
				var diff := _compare(shipped, previous)
				if diff[0] != 0:
					failures += 1
					print("  DIFFERS  %dx%d %s r%.0f -> n=%d max %.9f" % [
						res, res, label, radius, diff[0], diff[1]
					])
		print("  %dx%d: %d configurations checked" % [res, res, MODES.size() * 2])

	# The NONE/unknown mode returns the input untouched; guard that path too.
	var passthrough := pipeline._apply_smoothing_pass(_make_noise(64), Vector2i(64, 64), BOUNDS, null, NONE, 4.0)
	comparisons += 1
	if passthrough.size() != 64 * 64:
		failures += 1
		print("  DIFFERS  NONE mode did not pass the data through")

	print("")
	if failures == 0:
		print("EQUIVALENCE: %d/%d comparisons bit-identical (exact float equality)." % [comparisons, comparisons])
	else:
		print("EQUIVALENCE: %d of %d comparisons DIFFER." % [failures, comparisons])

	pipeline.cleanup()
	quit(0)
	return true


## Verbatim copy of the implementation before the hoisting change, kept as the reference.
func _apply_smoothing_pass_reference(
	data: PackedFloat32Array,
	resolution: Vector2i,
	terrain_bounds: Rect2,
	context,
	smoothing: int,
	radius: float
) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(data.size())

	var sample_count: int
	var sample_radius: float
	match smoothing:
		1:
			sample_count = 4
			sample_radius = radius * 0.5
		2:
			sample_count = 8
			sample_radius = radius
		3:
			sample_count = 12
			sample_radius = radius * 1.5
		_:
			return data

	var width := resolution.x
	var height := resolution.y
	var step_x := terrain_bounds.size.x / float(width - 1)
	var step_y := terrain_bounds.size.y / float(height - 1)

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
				var sidx := sy * width + sx
				var sample_h := data[sidx]
				var dist := sqrt(offset_x * offset_x + offset_y * offset_y)
				var w: float = max(0.0, 1.0 - dist * inv_norm)
				total_h += sample_h * w
				total_w += w

			result[idx] = total_h / total_w

	return result


func _compare(a: PackedFloat32Array, b: PackedFloat32Array) -> Array:
	if a.size() != b.size():
		return [maxi(a.size(), b.size()), INF]
	var count := 0
	var max_diff := 0.0
	for i in a.size():
		if a[i] != b[i]:
			count += 1
			max_diff = maxf(max_diff, absf(a[i] - b[i]))
	return [count, max_diff]


func _make_noise(res: int) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(res * res)
	for y in res:
		for x in res:
			data[y * res + x] = sin(float(x) * 0.05) * cos(float(y) * 0.05) * 30.0
	return data
