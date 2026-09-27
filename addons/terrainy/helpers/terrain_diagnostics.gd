class_name TerrainDiagnostics
extends RefCounted

## Timing thresholds and the optional per-rebuild report for the whole plugin.
##
## Every "this took too long" constant used to live at its own call site (mesh generator,
## composer, heightmap builder) with its own warning, which made the thresholds drift apart and
## turned a rebuild into a fistful of unrelated warnings. They now all come from this file, and
## a composer-owned instance also collects the phase timings so a single report can be printed
## per rebuild.
##
## Deliberately not a Node and not a singleton: a composer owns one instance, a test owns its
## own, and nothing here touches the scene tree, so helper classes that never enter the tree can
## record timings into it too.

## A terrain mesh slower than this pushes a warning (also used as the report's unit of "slow").
const MESH_BUILD_WARN_MS := 100
## A collision shape update slower than this pushes a warning.
const COLLISION_WARN_MS := 100
## Heightmap composition slower than this pushes a warning.
const COMPOSE_WARN_MS := 500
## A whole rebuild slower than this pushes a warning.
const REBUILD_WARN_MS := 2000

## Per-rebuild phase timings, in insertion order of first record.
var _phases: Dictionary = {}
## Counters (feature counts, cache hits, slow phases, ...) of the current rebuild.
var _counters: Dictionary = {}
var _rebuild_id: int = -1
var _rebuild_start_ms: int = 0
var _report_enabled: bool = false

## True when [param elapsed_ms] reached [param threshold_ms]. A negative threshold never
## warns, which is how callers silence a measurement they do not care about.
static func is_slow(elapsed_ms: int, threshold_ms: int) -> bool:
	return threshold_ms >= 0 and elapsed_ms >= threshold_ms

## Print the report of every rebuild (bound to `TerrainComposer.debug_logging`).
func set_report_enabled(value: bool) -> void:
	_report_enabled = value

func is_report_enabled() -> bool:
	return _report_enabled

func begin_rebuild(rebuild_id: int) -> void:
	_rebuild_id = rebuild_id
	_rebuild_start_ms = Time.get_ticks_msec()
	_phases.clear()
	_counters.clear()

## Record a phase duration; recording the same phase twice accumulates, so callers do not have
## to know whether a phase ran once or once per chunk.
func record(phase: String, elapsed_ms: int) -> void:
	_phases[phase] = int(_phases.get(phase, 0)) + elapsed_ms

func count(counter: String, amount: int = 1) -> void:
	_counters[counter] = int(_counters.get(counter, 0)) + amount

func phase_ms(phase: String) -> int:
	return int(_phases.get(phase, 0))

func counter(counter: String) -> int:
	return int(_counters.get(counter, 0))

## Push `[Terrainy] <message>` when `elapsed_ms` is slow for `category`, and count it either way.
## Returns true when the warning was pushed, which is what the tests assert on.
func warn(category: String, message: String, elapsed_ms: int, threshold_ms: int = -1) -> bool:
	var limit := threshold_ms if threshold_ms >= 0 else threshold_for(category)
	if not is_slow(elapsed_ms, limit):
		return false
	count("slow_" + category)
	push_warning("[Terrainy] %s" % message)
	return true

## Default threshold of a category; unknown categories use the rebuild threshold.
static func threshold_for(category: String) -> int:
	match category:
		"mesh":
			return MESH_BUILD_WARN_MS
		"collision":
			return COLLISION_WARN_MS
		"compose":
			return COMPOSE_WARN_MS
		_:
			return REBUILD_WARN_MS

## Finish the current rebuild: returns the one-line report and prints it when enabled.
## The report is always returned, so tools (and tests) can consume it without enabling prints.
func end_rebuild() -> String:
	var total := 0
	if _rebuild_start_ms > 0:
		total = Time.get_ticks_msec() - _rebuild_start_ms
	_rebuild_start_ms = 0

	var parts: Array[String] = []
	var keys: Array = _phases.keys()
	keys.sort()
	for key in keys:
		var phase_ms := int(_phases[key])
		if phase_ms > 0:
			parts.append("%s %d ms" % [key, phase_ms])
	var text := "Rebuild #%d in %d ms" % [_rebuild_id, total]
	if not parts.is_empty():
		text += " (" + ", ".join(parts) + ")"
	var counter_parts: Array[String] = []
	var counter_keys: Array = _counters.keys()
	counter_keys.sort()
	for key in counter_keys:
		counter_parts.append("%s=%d" % [key, int(_counters[key])])
	if not counter_parts.is_empty():
		text += " [" + ", ".join(counter_parts) + "]"

	if _report_enabled:
		print("[TerrainComposer] " + text)
	warn("rebuild", text, total, REBUILD_WARN_MS)
	return text
