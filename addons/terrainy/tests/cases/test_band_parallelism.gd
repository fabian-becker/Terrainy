extends "res://addons/terrainy/tests/framework/test_case.gd"

## The compose's row-band parallelism contract: the band split itself, the invariant that a band
## split can never change a composed value, and the failure paths that must not publish a
## half-written map.
##
## The grid cell of these cases is deliberately 0.3 m (76.8 / 256, 230.4 / 768): a cell that is not
## exactly representable in binary, which is where a band-seeded world coordinate stops being equal
## to the per-row product.

const TerrainGrid = preload("res://addons/terrainy/gen/eval/terrain_grid.gd")
const BandTask = preload("res://addons/terrainy/gen/eval/band_task.gd")
const Composer = preload("res://addons/terrainy/gen/eval/composer.gd")
const CompositionPlan = preload("res://addons/terrainy/gen/eval/composition_plan.gd")
const PlanBuilder = preload("res://addons/terrainy/gen/eval/plan_builder.gd")
const ModifierSnapshot = preload("res://addons/terrainy/gen/eval/modifier_snapshot.gd")

## Duck-typed stand-in for [TerrainGrid] that can lie about a row's world Z and counts the calls,
## so a test can prove the pixel loop reads it per row instead of carrying an accumulator.
class StubGrid extends RefCounted:
	var origin: Vector2 = Vector2.ZERO
	var cell: float = 0.3
	var row_lift: float = 0.0
	var z_calls: int = 0

	func world_x(px: int) -> float:
		return origin.x + px * cell

	func world_z(py: int) -> float:
		z_calls += 1
		return origin.y + py * cell + row_lift

	func full_rect() -> Rect2i:
		return Rect2i(0, 0, 2, 2)

	func world_rect() -> Rect2:
		return Rect2(origin, Vector2(cell, cell))

	func rect_for_world(_world: Rect2, _padding: int = 1) -> Rect2i:
		return Rect2i(0, 0, 2, 2)

# --- band_task: the split itself -------------------------------------------------------------

func test_band_ranges_are_contiguous_and_cover_every_row() -> void:
	for rows in [1, 7, 8, 9, 64, 100, 123, 769]:
		for threads in [1, 2, 3, 8, 16]:
			for min_rows in [1, 4, 8]:
				var count := BandTask.band_count(rows, threads, min_rows)
				var label := "rows=%d threads=%d min=%d" % [rows, threads, min_rows]
				t.check(count >= 1 and count <= maxi(threads, 1), "band_count in 1..threads (%s)" % label)
				var covered := 0
				var previous_end := 0
				var saw_empty := false
				for i in count:
					var rng := BandTask.band_range(rows, count, i)
					t.check(rng.y >= rng.x, "band %d not inverted (%s)" % [i, label])
					t.check(rng.x >= 0 and rng.y <= rows, "band %d inside 0..rows (%s)" % [i, label])
					t.check_eq(rng.x, previous_end, "band %d starts where %d ended (%s)" % [i, i - 1, label])
					# A band can own no rows (ceil rounding), but only at the tail: once a band is
					# empty, no later band may claim rows.
					t.check(not (saw_empty and rng.y > rng.x), "empty bands stay at the tail (%s)" % label)
					if rng.y == rng.x:
						saw_empty = true
					covered += rng.y - rng.x
					previous_end = rng.y
				t.check_eq(covered, rows, "every row covered exactly once (%s)" % label)

func test_band_count_is_one_when_splitting_cannot_pay() -> void:
	t.check_eq(BandTask.band_count(1024, 1), 1, "one thread runs inline")
	t.check_eq(BandTask.band_count(1024, 0), 1, "no threads runs inline")
	t.check_eq(BandTask.band_count(0, 8), 1, "no rows runs inline")
	t.check_eq(BandTask.band_count(7, 8, 8), 1, "fewer rows than min_rows runs inline")
	t.check_eq(BandTask.band_count(1024, 8, 8), 8, "enough rows fills the budget")
	t.check_eq(BandTask.band_count(40, 8, 8), 5, "rows / min_rows caps the band count")

func test_band_run_visits_every_index_once() -> void:
	for threads in [1, 2, 4, 16]:
		var seen := PackedInt32Array()
		seen.resize(37)
		var ok := BandTask.run(threads, 37, func(i: int) -> void: seen[i] += 1)
		t.check(ok, "run(%d) reports success" % threads)
		var total := 0
		var repeated := 0
		for v in seen:
			total += v
			if v > 1:
				repeated += 1
		t.check_eq(total, 37, "every index ran once with %d threads" % threads)
		t.check_eq(repeated, 0, "no index ran twice with %d threads" % threads)
	# An empty pass is a success, not a failure.
	t.check(BandTask.run(4, 0, func(_i: int) -> void: pass), "empty pass succeeds")

func test_run_rows_hands_absolute_rows_to_the_callback() -> void:
	# The callbacks run on 4 threads, and appending to a shared Array from several threads loses
	# entries (the exact hazard the band design avoids) -- so the collector is locked here.
	var seen: Array = []
	var mutex := Mutex.new()
	BandTask.run_rows(4, 64, 10, func(y0: int, y1: int) -> void:
		mutex.lock()
		seen.append(Vector2i(y0, y1))
		mutex.unlock(), 8)
	t.check_eq(seen.size(), 4, "64 rows / 8 min rows = 4 bands over 4 threads")
	for rng in seen:
		t.check(rng.x >= 10 and rng.y <= 74, "offset applied to %s" % str(rng))

# --- the determinism invariant: values never depend on the band split ------------------------

func _stub_snapshot(grid) -> RefCounted:
	var f := make_field(10.0, Vector2(200, 200))
	var rel := TerrainReliefSource.new()
	rel.weight = 4.0
	f.relief_layers = [rel]
	var snap = f.make_snapshot({"grid": grid, "generator_xform": Transform3D.IDENTITY})
	f.free()
	return snap

func test_field_rows_read_the_world_z_from_the_grid_every_row() -> void:
	# A sample's world Z must come from the grid per row. The bug this pins seeded one value per
	# band and added `cell` down the rows, so the value at a given row depended on where the band
	# started -- i.e. on the core count. A grid whose world_z() can be lifted proves the loop asks.
	var rect := Rect2i(0, 0, 9, 12)
	var plain := StubGrid.new()
	plain.origin = Vector2(-1.5, -1.5)
	var lifted := StubGrid.new()
	lifted.origin = Vector2(-1.5, -1.5)
	lifted.row_lift = 0.5
	var snap = _stub_snapshot(plain)
	var a := HMap.new(rect)
	var wa := HMap.new(rect)
	var b := HMap.new(rect)
	var wb := HMap.new(rect)
	snap.evaluate_band(plain, rect, 0, rect.size.y, a.data, wa.data)
	snap.evaluate_band(lifted, rect, 0, rect.size.y, b.data, wb.data)
	t.check_eq(plain.z_calls, rect.size.y, "world_z called once per row, not once per band")
	var moved := 0
	for i in a.data.size():
		if wa.data[i] > 0.0 and a.data[i] != b.data[i]:
			moved += 1
	t.check(moved > 0, "row Z is read from the grid (lifting it moved %d of %d samples)" % [moved, a.data.size()])

func test_field_evaluation_is_band_independent_at_a_non_exact_cell() -> void:
	var grid := TerrainGrid.new(256, 76.8)
	t.check_almost_eq(grid.cell, 0.3, "cell is 0.3 m", 0.000001)
	# Establish that the hazard is real for this cell: seed-and-accumulate is not equal to the
	# per-row product on most rows. If this ever becomes false the case below loses its teeth.
	var rows := grid.samples
	var seed: float = grid.origin.y + 0.0 * grid.cell
	var differing := 0
	for y in rows:
		var accumulated := seed
		for _k in y:
			accumulated += grid.cell
		if accumulated != grid.world_z(y):
			differing += 1
	t.check(differing > rows / 2, "accumulating cell is not equal to the per-row product (%d/%d rows)" % [differing, rows])
	var snap = _stub_snapshot(grid)
	var rect: Rect2i = snap.pixel_rect(grid)
	var serial_h := HMap.new(rect)
	var serial_w := HMap.new(rect)
	snap.evaluate_band(grid, rect, 0, rect.size.y, serial_h.data, serial_w.data)
	for bands in [2, 3, 8, 16, 32]:
		var banded_h := HMap.new(rect)
		var banded_w := HMap.new(rect)
		for b in bands:
			var rng := BandTask.band_range(rect.size.y, bands, b)
			snap.evaluate_band(grid, rect, rng.x, rng.y, banded_h.data, banded_w.data)
		var hd := 0
		var wd := 0
		for i in serial_h.data.size():
			if serial_h.data[i] != banded_h.data[i]:
				hd += 1
			if serial_w.data[i] != banded_w.data[i]:
				wd += 1
		t.check_eq(hd, 0, "heights identical over %d bands" % bands)
		t.check_eq(wd, 0, "weights identical over %d bands" % bands)

func test_compose_is_identical_across_worker_thread_counts() -> void:
	# The whole compose, twice: once with every pass inline and once on the default budget. Only
	# the band split differs, so a difference of one bit means a band read something it should not
	# have or computed a value from its own row offset.
	var serial := _parity_build(1)
	var banded := _parity_build(0)
	t.check_eq(serial.compose_worker_threads(), 1, "max_worker_threads = 1 forces one band")
	t.check(banded.compose_worker_threads() >= 1, "default budget is at least one band")
	if OS.get_processor_count() >= 4:
		t.check(banded.compose_worker_threads() > 1, "default budget bands on a multi-core box")
	var serial_image: Image = serial.get_final_image()
	var banded_image: Image = banded.get_final_image()
	t.check(serial_image != null and banded_image != null, "both composes produced an image")
	if serial_image != null and banded_image != null:
		var a := serial_image.get_data()
		var b := banded_image.get_data()
		t.check_eq(a.size(), b.size(), "same image size")
		t.check_eq(hash(a), hash(b), "identical height bytes (%d samples)" % (a.size() / 4))
	# And a repeat of the same run is stable too (no band-order effect across runs).
	banded.force_rebuild()
	banded.rebuild_now()
	var again: Image = banded.get_final_image()
	if banded_image != null and again != null:
		t.check_eq(hash(again.get_data()), hash(banded_image.get_data()), "repeat compose identical")

## A scene that exercises every banded pass: noise field evaluation, a group composite, a blur
## modifier (reads its neighbours), masked modifier weights, and the banded blend/clamp.
func _parity_build(max_threads: int) -> TerrainGenerator:
	var gen := make_generator(96, 28.8, func(g: TerrainGenerator):
		g.max_worker_threads = max_threads)
	var mountains := make_field(18.0, Vector2(20, 20), Vector3(-4, 0, 0))
	var rel := TerrainReliefSource.new()
	rel.weight = 5.0
	rel.noise_seed = 3
	mountains.relief_layers = [rel]
	var hills := make_field(9.0, Vector2(26, 14), Vector3(5, 0, 2))
	var rel2 := TerrainReliefSource.new()
	rel2.weight = 2.5
	rel2.scale = Vector2(2, 1)
	rel2.noise_seed = 11
	hills.relief_layers = [rel2]
	var group := TerrainFieldGroup.new()
	var a := make_field(4.0, Vector2(9, 9), Vector3(-8, 0, 5))
	a.domain_falloff = null
	var b := make_field(6.0, Vector2(9, 9), Vector3(2, 0, 5))
	b.domain_falloff = null
	group.add_child(a)
	group.add_child(b)
	var smooth := TerrainSmoothModifier.new()
	smooth.radius = 2.0
	smooth.space = TerrainTypes.Space.GROUP
	group.add_child(smooth)
	var clamp_mod := TerrainClampModifier.new()
	clamp_mod.use_min = false
	clamp_mod.max_height = 14.0
	var mask := TerrainMaskRegion.new()
	mask.size = Vector2(14, 14)
	mask.falloff = null
	clamp_mod.mask = mask
	var gen_children: Array = [mountains, hills, group, clamp_mod]
	return build(gen, gen_children)

# --- masks: an inverted mask is non-zero outside its bounds ----------------------------------

func test_inverted_mask_modifier_still_acts_outside_the_mask_bounds() -> void:
	# A modifier pass is bounded by its mask's world rect to skip the pixels the mask zeroes. An
	# inverted mask is zero INSIDE that rect and 1 everywhere else, so clipping the pass to the
	# mask bounds silently drops the modifier's whole effect.
	var f := make_field(30.0, Vector2(60, 60))
	f.region_shape = TerrainTypes.RegionShape.RECTANGLE
	f.domain_falloff = null
	var clamp_mod := TerrainClampModifier.new()
	clamp_mod.use_min = false
	clamp_mod.max_height = 0.0
	var mask := TerrainMaskRegion.new()
	mask.size = Vector2(6, 6)
	mask.falloff = null
	mask.invert = true
	clamp_mod.mask = mask
	var gen := build(make_generator(64, 64.0), [f, clamp_mod])
	t.check_almost_eq(h_at(gen, 0, 0), 30.0, "inside the inverted mask the weight is 0: untouched", 0.01)
	t.check_almost_eq(h_at(gen, 20, 0), 0.0, "outside the mask bounds the clamp still acts", 0.01)
	t.check_almost_eq(h_at(gen, 20, 20), 0.0, "in the far corner too", 0.01)
	# The non-inverted mask keeps the fast path (and stays clipped to its bounds).
	mask.invert = false
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "non-inverted: clamped inside the mask", 0.01)
	t.check_almost_eq(h_at(gen, 20, 0), 30.0, "non-inverted: untouched outside", 0.01)

func test_modifier_with_an_inverted_mask_matches_the_unclipped_reference() -> void:
	var f := make_field(20.0, Vector2(30, 30), Vector3(3, 0, -2))
	var rel := TerrainReliefSource.new()
	rel.weight = 6.0
	f.relief_layers = [rel]
	var smooth := TerrainSmoothModifier.new()
	smooth.radius = 1.5
	smooth.strength = 0.5
	var mask := TerrainMaskRegion.new()
	mask.size = Vector2(8, 8)
	mask.invert = true
	smooth.mask = mask
	var gen := build(make_generator(64, 64.0), [f, smooth])
	var probes := [Vector2(0, 0), Vector2(6, 0), Vector2(-8, 4), Vector2(12, 12), Vector2(-20, -20)]
	var with_mask: Array = []
	for p in probes:
		with_mask.append(h_at(gen, p.x, p.y))
	# The same scene without the mask: an inverted mask over a tiny rect is ~1 everywhere here,
	# so the smoothed heights must land within a hair of the unmasked run.
	smooth.mask = null
	gen.rebuild_now()
	for i in probes.size():
		var p: Vector2 = probes[i]
		var unmasked := h_at(gen, p.x, p.y)
		t.check(absf(with_mask[i] - unmasked) < 1.5, "height at %s within 1.5 m of the unmasked run (%.3f vs %.3f)" % [str(p), with_mask[i], unmasked])

# --- failure containment ---------------------------------------------------------------------

func test_modifier_apply_reports_success_and_touches_the_map() -> void:
	var grid := TerrainGrid.new(32, 32.0)
	var dest := HMap.new(grid.full_rect(), 5.0)
	var snap := ModifierSnapshot.new()
	snap.op = ModifierSnapshot.Op.CLAMP
	snap.use_min = false
	snap.clamp_max = 2.0
	snap.bounds = Rect2(-1, -1, 2, 2)
	var ok: bool = snap.apply(dest, grid, 0.0, 1.0, 4)
	t.check(ok, "apply reports success")
	t.check_almost_eq(dest.get_at(0, 0), 2.0, "clamped", 0.001)
	t.check_almost_eq(dest.get_at(0, 0), 2.0, "banded merge wrote the first row", 0.001)
	t.check_almost_eq(dest.get_at(dest.rect.size.x - 1, dest.rect.size.y - 1), 2.0, "and the last", 0.001)
	t.check_eq(dest.data.size(), dest.rect.size.x * dest.rect.size.y, "map keeps its size")

func test_stitch_guard_rejects_an_incomplete_band_set() -> void:
	var rows := 12
	var w := 4
	var expected := w * rows
	var complete: Array = []
	var partial: Array = []
	for band in 3:
		complete.append(PackedFloat32Array())
		complete[band].resize(w * 4)
		if band < 2:
			partial.append(PackedFloat32Array())
			partial[band].resize(w * 4)
		else:
			partial.append(null)
	t.check(ModifierSnapshot.stitch_complete(complete, expected), "three full blocks stitch")
	t.check(not ModifierSnapshot.stitch_complete(partial, expected), "a missing block does not stitch")
	complete[1] = PackedFloat32Array()
	complete[1].resize(w * 3)
	t.check(not ModifierSnapshot.stitch_complete(complete, expected), "a short block does not stitch")
	t.check(not ModifierSnapshot.stitch_complete([], expected), "no blocks do not stitch")
	t.check(ModifierSnapshot.stitch_complete([], 0), "an empty pass is trivially complete")

# --- diagnostics: the counters must describe what ran ----------------------------------------

func test_evaluated_counts_injected_gpu_maps() -> void:
	var f := make_field(10.0, Vector2(20, 20))
	f.domain_falloff = null
	var gen := build(make_generator(32, 32.0), [f])
	var grid = gen.get_grid()
	var plan = PlanBuilder.build(gen, gen.composition_context(grid, [], []))
	var target = null
	for unit in plan.all_units():
		if unit.kind == CompositionPlan.UnitKind.FIELD:
			target = unit
			break
	t.check(target != null, "the plan has a FIELD unit")
	if target == null:
		return
	var hmap := HMap.new(grid.full_rect(), 2.0)
	var wmap := HMap.new(grid.full_rect(), 1.0)
	var composer := Composer.new()
	composer.injected = {target.snap.signature: {"h": hmap, "w": wmap}}
	composer.worker_threads = 2
	var composite = composer.compose(plan, grid, 0.0)
	t.check_eq(composer.evaluated, 1, "an injected map counts as evaluated")
	t.check_eq(composer.gpu_evaluated, 1, "and as GPU-evaluated")
	t.check_eq(composer.reused, 0, "nothing was reused")
	t.check_almost_eq(composite.get_at(0, 0), 2.0, "the injected heights reached the composite", 0.01)
