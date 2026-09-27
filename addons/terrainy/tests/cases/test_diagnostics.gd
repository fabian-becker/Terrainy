extends "res://addons/terrainy/tests/framework/test_case.gd"

## Tests for TerrainDiagnostics, the single source of truth for the plugin's timing thresholds.
##
## Every "this took too long" constant used to live at its own call site, so the thresholds drifted
## apart and a rebuild printed unrelated warnings. The cases below pin the contract the call sites
## rely on: a negative threshold never warns, a category maps to its threshold, the counters and
## phases of a rebuild accumulate, and the report is produced whether or not printing is on.

const TerrainDiagnostics = preload("res://addons/terrainy/helpers/terrain_diagnostics.gd")

func test_thresholds_and_the_slow_test() -> void:
	t.check(
		TerrainDiagnostics.is_slow(TerrainDiagnostics.MESH_BUILD_WARN_MS, TerrainDiagnostics.MESH_BUILD_WARN_MS),
		"reaching a threshold counts as slow"
	)
	t.check(
		not TerrainDiagnostics.is_slow(TerrainDiagnostics.MESH_BUILD_WARN_MS - 1, TerrainDiagnostics.MESH_BUILD_WARN_MS),
		"staying below the threshold is not slow"
	)
	t.check(
		not TerrainDiagnostics.is_slow(5000, -1),
		"a negative threshold never warns, which is how a call site silences a measurement"
	)
	t.check(
		TerrainDiagnostics.is_slow(0, 0),
		"a threshold of 0 warns for any measurement"
	)

func test_categories_map_to_their_threshold() -> void:
	t.check_eq(
		TerrainDiagnostics.threshold_for("mesh"), TerrainDiagnostics.MESH_BUILD_WARN_MS,
		"the mesh category uses the mesh threshold"
	)
	t.check_eq(
		TerrainDiagnostics.threshold_for("collision"), TerrainDiagnostics.COLLISION_WARN_MS,
		"the collision category uses the collision threshold"
	)
	t.check_eq(
		TerrainDiagnostics.threshold_for("compose"), TerrainDiagnostics.COMPOSE_WARN_MS,
		"the compose category uses the compose threshold"
	)
	t.check_eq(
		TerrainDiagnostics.threshold_for("something else"), TerrainDiagnostics.REBUILD_WARN_MS,
		"an unknown category falls back to the rebuild threshold"
	)
	t.check(
		TerrainDiagnostics.COMPOSE_WARN_MS > TerrainDiagnostics.MESH_BUILD_WARN_MS,
		"composing a heightmap over the whole terrain may take longer than one chunk mesh"
	)
	t.check(
		TerrainDiagnostics.REBUILD_WARN_MS > TerrainDiagnostics.COMPOSE_WARN_MS,
		"a whole rebuild may take longer than a single phase"
	)

## The warning helpers return whether they warned (asserted here, since pushed warnings cannot be
## inspected from a headless run) and only count the phases that were actually slow.
func test_warn_reports_and_counts_only_slow_phases() -> void:
	var diagnostics := TerrainDiagnostics.new()
	t.check(
		not diagnostics.warn("mesh", "fast chunk", TerrainDiagnostics.MESH_BUILD_WARN_MS - 1),
		"a fast phase does not warn"
	)
	t.check_eq(diagnostics.counter("slow_mesh"), 0, "a fast phase is not counted as slow")
	t.check(
		diagnostics.warn("mesh", "slow chunk", TerrainDiagnostics.MESH_BUILD_WARN_MS),
		"a slow phase warns"
	)
	t.check(
		diagnostics.warn("mesh", "slow chunk again", TerrainDiagnostics.MESH_BUILD_WARN_MS * 4),
		"every slow phase warns on its own"
	)
	t.check_eq(diagnostics.counter("slow_mesh"), 2, "the slow phases are counted")
	t.check(
		not diagnostics.warn("collision", "fast shape", 1, -1),
		"an explicit negative threshold silences the warning"
	)
	t.check(
		diagnostics.warn("collision", "slow shape", 10, 1),
		"an explicit threshold overrides the category default"
	)
	t.check_eq(diagnostics.counter("slow_collision"), 1, "the override still counts the phase")

func test_phases_accumulate_and_the_report_lists_them_sorted() -> void:
	var diagnostics := TerrainDiagnostics.new()
	diagnostics.begin_rebuild(7)
	# A phase that runs once per chunk accumulates instead of overwriting.
	diagnostics.record("mesh", 120)
	diagnostics.record("mesh", 30)
	diagnostics.record("collision", 15)
	diagnostics.record("compose", 0)
	diagnostics.count("chunks", 4)
	diagnostics.count("chunks", 1)
	diagnostics.count("reused")
	t.check_eq(diagnostics.phase_ms("mesh"), 150, "repeated recordings accumulate")
	t.check_eq(diagnostics.phase_ms("missing"), 0, "an unrecorded phase is 0")
	t.check_eq(diagnostics.counter("chunks"), 5, "counters accumulate with an amount")
	t.check_eq(diagnostics.counter("reused"), 1, "counters default to an increment")

	var report := diagnostics.end_rebuild()
	t.check(
		report.contains("collision 15 ms") and report.contains("mesh 150 ms"),
		"the report lists the recorded phases: %s" % report
	)
	t.check(
		report.find("collision") < report.find("mesh"),
		"the phases are sorted by name, not by recording order: %s" % report
	)
	t.check(
		not report.contains("compose"),
		"a phase that did not consume time is left out: %s" % report
	)
	t.check(
		report.contains("chunks=5") and report.contains("reused=1"),
		"the report lists the counters: %s" % report
	)
	t.check(report.begins_with("Rebuild #7 in "), "the report names the rebuild: %s" % report)

func test_a_new_rebuild_starts_from_an_empty_report() -> void:
	var diagnostics := TerrainDiagnostics.new()
	diagnostics.begin_rebuild(1)
	diagnostics.record("mesh", 250)
	diagnostics.count("chunks", 3)
	diagnostics.begin_rebuild(2)
	t.check_eq(diagnostics.phase_ms("mesh"), 0, "a new rebuild drops the previous phases")
	t.check_eq(diagnostics.counter("chunks"), 0, "a new rebuild drops the previous counters")
	var report := diagnostics.end_rebuild()
	t.check(report.begins_with("Rebuild #2 in "), "the report belongs to the new rebuild: %s" % report)

## debug_logging is the only thing that turns printing on; the composer binds it to the setter.
func test_printing_is_opt_in_and_does_not_change_the_report() -> void:
	var diagnostics := TerrainDiagnostics.new()
	t.check(not diagnostics.is_report_enabled(), "the report is off by default")
	diagnostics.begin_rebuild(1)
	diagnostics.record("mesh", 200)
	var quiet := diagnostics.end_rebuild()
	diagnostics.set_report_enabled(true)
	t.check(diagnostics.is_report_enabled(), "the report can be enabled")
	diagnostics.begin_rebuild(2)
	diagnostics.record("mesh", 200)
	var loud := diagnostics.end_rebuild()
	t.check(
		loud.contains("mesh 200 ms") and quiet.contains("mesh 200 ms"),
		"enabling the print does not change what is reported (%s vs %s)" % [quiet, loud]
	)
