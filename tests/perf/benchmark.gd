extends SceneTree

## Terrainy 2 performance benchmark harness (headless).
##
## Usage:
##     godot --headless --path . --script res://tests/perf/benchmark.gd
##     godot --headless --path . --script res://tests/perf/benchmark.gd -- --quick   # 3 rounds
##     godot --headless --path . --script res://tests/perf/benchmark.gd -- --full    # + reference scale
##
## Answers "where does the time go" for the 2.0 pipeline (plan scan -> field eval -> compose ->
## Global pass -> paint -> control maps -> chunks). Every measurement runs `_repeats` rounds and
## reports best / median / mean: the best run is the least noisy estimate of the intrinsic cost,
## the spread shows how much the environment interferes.
##
## Phase attribution is read from the generator's own TerrainDiagnostics, so the reported stages
## are the ones the rebuild actually ran rather than a guess from outside.
##
## Exit code is always 0 -- this is a measurement tool, not a gate.
##
## Headless has no RenderingDevice, so every GPU path is skipped and composition runs on the CPU.
## The `use_gpu_*` flags are forced off here rather than left to fall back, so the numbers say
## "CPU worst case" honestly: the editor's GPU paths are not measured by this script.

const BrushStamp = preload("res://addons/terrainy/gen/paint/brush_stamp.gd")

const DEFAULT_REPEATS := 5
const QUICK_REPEATS := 3

## The design's performance contract names "1024**2 / 4 km**2" as the reference scale, which reads
## as a 1024-cell grid over a 4 km**2 square: 2048 m x 2048 m, i.e. 2 m cells. `--full` adds it; the
## default sweep stays quick (a 1024-cell rebuild is minutes, not seconds).
const SCALES: Array[Dictionary] = [
	{"label": "256 cells / 256 m", "cells": 256, "size": 256.0},
	{"label": "512 cells / 512 m", "cells": 512, "size": 512.0},
	{"label": "1024 cells / 2048 m (reference, 4 km2)", "cells": 1024, "size": 2048.0},
]

var _quick := false
var _full := false
var _repeats := DEFAULT_REPEATS
var _section := ""
var _rows: Array[Dictionary] = []
var _attribution: Array[Dictionary] = []
var _cache_stats: Array[Dictionary] = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--quick":
			_quick = true
			_repeats = QUICK_REPEATS
		elif arg == "--full":
			_full = true

func _process(_delta: float) -> bool:
	_header()
	for scale in _scales():
		_bench_full_rebuild(scale)
		_bench_cached_rebuild(scale)
		_bench_one_field_edit(scale)
		_bench_paint_stroke(scale)
	_report()
	quit(0)
	return true

# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------

func _bench_full_rebuild(scale: Dictionary) -> void:
	_section = "full rebuild | %s" % scale["label"]
	var gen := _make_terrain(scale["cells"], scale["size"])
	gen.rebuild_now()  # settle: the first rebuild also lays out chunks
	_measure("force_rebuild + rebuild_now", func() -> void:
		gen.force_rebuild()
		gen.rebuild_now(), "cache-cleared recompose of the whole pipeline")
	_attribution.append({"label": scale["label"], "diag": gen.get_diagnostics()})
	_free(gen)

func _bench_cached_rebuild(scale: Dictionary) -> void:
	_section = "cached rebuild | %s" % scale["label"]
	var gen := _make_terrain(scale["cells"], scale["size"])
	gen.rebuild_now()
	_measure("rebuild_now (nothing changed)", func() -> void:
		gen.rebuild_now(), "should reuse the compose signature and rebuild no chunk")
	_free(gen)

func _bench_one_field_edit(scale: Dictionary) -> void:
	_section = "one field edit | %s" % scale["label"]
	var gen := _make_terrain(scale["cells"], scale["size"])
	var field := gen.get_node("Mountain") as TerrainFieldNode
	gen.rebuild_now()
	var first: Dictionary = gen.get_diagnostics()["counters"]
	var first_evaluated := int(first.get("fields_evaluated", 0))
	_measure("edit profile_height + rebuild_now", func() -> void:
		field.profile_height += 1.0
		gen.rebuild_now(), "one field re-evaluated, the rest replayed from cache")
	var after: Dictionary = gen.get_diagnostics()["counters"]
	_cache_stats.append({
		"label": scale["label"],
		"first_evaluated": first_evaluated,
		"evaluated": int(after.get("fields_evaluated", 0)),
		"reused": int(after.get("fields_reused", 0)),
	})
	_free(gen)

func _bench_paint_stroke(scale: Dictionary) -> void:
	_section = "paint stroke | %s" % scale["label"]
	var gen := _make_terrain(scale["cells"], scale["size"])
	var layer := TerrainPaintLayer.new()
	layer.name = "Sculpt"
	layer.kind = TerrainPaintLayer.PaintKind.HEIGHT_DELTA
	gen.add_child(layer)
	gen.rebuild_now()
	var strokes := 0
	_measure("paint_stamps (24 m radius)", func() -> void:
		strokes += 1
		var stamp := BrushStamp.new()
		stamp.op = BrushStamp.StrokeOp.RAISE
		stamp.position = Vector3(20.0 + strokes * 4.0, 0.0, 20.0)
		stamp.radius = 24.0
		stamp.strength = 1.5
		gen.paint_stamps(layer, [stamp]), "stamp + local recompose of the stroke rect")
	_free(gen)

# ---------------------------------------------------------------------------
# Terrain fixture
# ---------------------------------------------------------------------------

func _relief(weight: float, freq: float, seed_value: int, scale: Vector2 = Vector2.ONE, follow: bool = false) -> TerrainReliefSource:
	var r := TerrainReliefSource.new()
	r.weight = weight
	r.noise.frequency = freq
	r.noise_seed = seed_value
	r.scale = scale
	r.follow_profile = follow
	return r

func _curve(points: Array) -> Curve:
	var c := Curve.new()
	for p in points:
		c.add_point(Vector2(p[0], p[1]), p[2] if p.size() > 2 else 0.0, p[3] if p.size() > 3 else 0.0)
	return c

func _layer(layer_name: String, color: Color) -> TerrainyTextureLayer:
	var l := TerrainyTextureLayer.new()
	l.layer_name = layer_name
	l.albedo_color = color
	return l

## A composition that exercises every stage: a Global noise base, a profiled Region mountain with
## a Local terrace (nested sculpting), a Replace plateau, a texture palette and a painted layer.
## Same shapes as the demo recipes, so the mix is representative rather than synthetic.
func _make_terrain(cells: int, size: float) -> TerrainGenerator:
	var gen := TerrainGenerator.new()
	gen.name = "BenchTerrain"
	# Benchmark an exact grid: no "keep the meters per cell" derivation on resize.
	gen.preserve_cell_size = false
	gen.terrain_resolution = cells
	gen.terrain_size = size
	gen.chunk_size = 128
	gen.navigation_enabled = false
	gen.use_gpu_composition = false
	gen.use_gpu_feature_evaluation = false
	gen.use_gpu_paint = false
	var grass := _layer("Grass", Color(0.32, 0.5, 0.22))
	grass.slope_max = 30.0
	var rock := _layer("Rock", Color(0.45, 0.42, 0.4))
	rock.slope_min = 28.0
	var snow := _layer("Snow", Color(0.93, 0.95, 0.97))
	snow.height_min = 34.0
	gen.texture_layers = [grass, rock, snow] as Array[TerrainyTextureLayer]
	root.add_child(gen)

	var base := TerrainFieldNode.new()
	base.name = "RollingHills"
	base.domain_kind = TerrainTypes.DomainKind.GLOBAL
	base.profile_height = 0.0
	base.relief_layers = [_relief(5.0, 0.012, 1), _relief(1.2, 0.05, 2)] as Array[TerrainReliefSource]
	gen.add_child(base)

	var mountain := TerrainFieldNode.new()
	mountain.name = "Mountain"
	mountain.position = Vector3(-55, 0, -50)
	mountain.region_size = Vector2(120, 120)
	mountain.profile_height = 45.0
	mountain.profile = _curve([[0, 0, 0, 0.5], [0.55, 0.45, 1.2, 1.2], [1, 1, 0.3, 0]])
	mountain.relief_layers = [_relief(10.0, 0.03, 3, Vector2.ONE, true)] as Array[TerrainReliefSource]
	gen.add_child(mountain)
	var terrace := TerrainTerraceModifier.new()
	terrace.name = "MountainTerraces"
	terrace.space = TerrainTypes.Space.LOCAL
	terrace.step_height = 6.0
	mountain.add_child(terrace)

	var plateau := TerrainFieldNode.new()
	plateau.name = "Plateau"
	plateau.position = Vector3(60, 0, 60)
	plateau.domain_kind = TerrainTypes.DomainKind.REGION
	plateau.region_shape = TerrainTypes.RegionShape.RECTANGLE
	plateau.region_size = Vector2(120, 90)
	plateau.blend_mode = TerrainTypes.BlendMode.REPLACE
	plateau.profile_height = 26.0
	plateau.elevation_origin = TerrainTypes.ElevationOrigin.WORLD
	plateau.profile_offset = 26.0
	gen.add_child(plateau)
	return gen

func _free(gen: TerrainGenerator) -> void:
	root.remove_child(gen)
	gen.free()

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

func _scales() -> Array:
	return SCALES if _full else SCALES.slice(0, 2)

func _header() -> void:
	print("================================================================")
	print("Terrainy 2 performance benchmark")
	print("Godot %s | adapter=%s | RenderingDevice=%s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		"yes" if RenderingServer.get_rendering_device() != null else "no (CPU worst case)",
	])
	print("repeats=%d (best/median/mean) | quick=%s | full=%s" % [_repeats, _quick, _full])
	print("================================================================")

## Time [param body] `_repeats` times and record best/median/mean in ms.
func _measure(label: String, body: Callable, note: String = "") -> void:
	var samples: Array[float] = []
	for i in _repeats:
		var start := Time.get_ticks_usec()
		body.call()
		samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
	samples.sort()
	var sum := 0.0
	for s in samples:
		sum += s
	_rows.append({
		"section": _section, "label": label, "min": samples[0],
		"median": samples[samples.size() / 2], "mean": sum / float(samples.size()), "note": note,
	})

func _report() -> void:
	print("")
	print("----------------------------------------------------------------")
	print("timings (ms)")
	print("----------------------------------------------------------------")
	var section := ""
	for row in _rows:
		if row["section"] != section:
			section = row["section"]
			print("\n%s" % section)
			print("  %-42s %10s %10s %10s  %s" % ["measurement", "best", "median", "mean", "note"])
		print("  %-42s %10.2f %10.2f %10.2f  %s" % [row["label"], row["min"], row["median"], row["mean"], row["note"]])

	print("")
	print("----------------------------------------------------------------")
	print("cache behaviour (fields evaluated / reused, from TerrainDiagnostics)")
	print("----------------------------------------------------------------")
	for entry in _cache_stats:
		print("  %-42s first rebuild evaluated %d | after a one-field edit: %d evaluated, %d reused"
			% [entry["label"], entry["first_evaluated"], entry["evaluated"], entry["reused"]])

	print("")
	print("----------------------------------------------------------------")
	print("stage attribution (last full rebuild per scale, from TerrainDiagnostics)")
	print("----------------------------------------------------------------")
	for entry in _attribution:
		var diag: Dictionary = entry["diag"]
		var phases: Dictionary = diag["phases"]
		var counters: Dictionary = diag["counters"]
		print("\n%s  (%d chunks, %d samples/side)" % [entry["label"], diag["chunks"], diag["grid"]["samples"]])
		var parts := PackedStringArray()
		for key in ["plan", "compose", "paint", "controls", "chunk_workers"]:
			if phases.has(key):
				parts.append("%s=%d" % [key, int(phases[key])])
		print("  phases:   %s" % " ".join(parts))
		var counts := PackedStringArray()
		for key in ["units", "fields_evaluated", "fields_reused", "chunks_generated", "chunks_applied", "apply_frames"]:
			counts.append("%s=%d" % [key, int(counters.get(key, 0))])
		print("  counters: %s" % " ".join(counts))
	print("")
	print("Summing phases is not the total: chunk meshing runs on worker threads while the main")
	print("thread applies results, so `chunk_workers` overlaps the frame budget rather than adding")
	print("to it. `tests/perf/benchmark_frame_budget.gd` measures that side directly.")
