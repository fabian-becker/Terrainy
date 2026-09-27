extends SceneTree

## Focused probe for the mesh-generator boundary-vertex key cost.
##
## The holed (marching squares) mesh path builds a `String` key per cell edge for the
## `edge_verts` dedup dict: `"h_%d_%d" % [gz, gx]`. A commit message claims this became an
## "integer-keyed dict", but the code still formats strings. This measures what the string
## costs versus a packed-integer key, which is what determines whether fixing it is worth it.

const CELLS := 400_000   # upper bound on edge lookups for a large holed chunk


func _process(_delta: float) -> bool:
	print("Boundary-vertex key cost (mesh hole path), %d operations" % CELLS)

	var samples := 5
	var string_ms := _best(samples, func() -> void:
		var d: Dictionary = {}
		var acc := 0
		for i in CELLS:
			var gz := i / 512
			var gx := i % 512
			var k := "h_%d_%d" % [gz, gx]
			d[k] = i
			acc += d.size()
	)

	var int_ms := _best(samples, func() -> void:
		var d: Dictionary = {}
		var acc := 0
		for i in CELLS:
			var gz := i / 512
			var gx := i % 512
			# Packed key: horizontal edge vs vertical edge lives in the low bit pair,
			# the two grid coords in fixed-width fields.
			var k := (gx << 12) | gz
			d[k] = i
			acc += d.size()
	)

	print("  string key  \"h_%%d_%%d\" %% [...] : %8.2f ms  (%.3f us/op)" % [string_ms, string_ms * 1000.0 / CELLS])
	print("  packed int key  (gx<<12)|gz     : %8.2f ms  (%.3f us/op)" % [int_ms, int_ms * 1000.0 / CELLS])
	print("  => speedup %.1fx, saves %.1f ms per %d lookups" % [
		string_ms / maxf(int_ms, 0.0001), string_ms - int_ms, CELLS
	])
	print("")
	print("Reference: measured holed-vs-solid mesh cost for a 257x257 chunk is")
	print("  96.7 ms solid -> 170.1 ms holed, i.e. +73.4 ms for the marching-squares branch")
	print("  (that delta contains this key cost plus the boundary-vertex geometry work).")
	quit(0)
	return true


func _best(samples: int, body: Callable) -> float:
	var best := INF
	for i in samples:
		var start := Time.get_ticks_usec()
		body.call()
		best = min(best, float(Time.get_ticks_usec() - start) / 1000.0)
	return best
