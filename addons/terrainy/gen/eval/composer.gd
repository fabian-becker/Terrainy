@tool
extends RefCounted

## Stages 2-4 on the CPU: evaluates every plan unit and composes the tree (worker safe).
##
## - Siblings blend in tree order into their target.
## - Local-space children of a field shape the field's own map before it is blended.
## - Group-space children (the default) apply to the nearest group composite (the terrain
##   composite at the root) right after their parent unit landed.
## - Groups compose their children into their own composite (starting at 0) and blend it with
##   the union of their children's coverage.
## - Global-space units run afterwards on the whole-terrain composite, in scene order.
##
## Group composites and the own maps of additive fields are deltas over the enclosing composite,
## while a flatten modifier's [member ModifierSnapshot.target_height] is an absolute world height
## (the plane its gizmo draws). [param datum] threads the enclosing absolute map down so the
## flatten can subtract it, keeping the composed terrain on the plane the editor shows.
##
## Per-field evaluations are cached by their own signature: an edit only re-evaluates the field
## that changed, every other unit replays its cached maps.

const HMap = preload("res://addons/terrainy/gen/eval/hmap.gd")
const CompositionPlan = preload("res://addons/terrainy/gen/eval/composition_plan.gd")
const BandTask = preload("res://addons/terrainy/gen/eval/band_task.gd")

## Fewest rows a band may own before splitting a pass stops paying for itself.
const BAND_MIN_ROWS: int = 8

var grid = null
## Worker pool budget for the passes inside this compose (1 = everything inline on the caller).
## The compose itself already runs on a worker task, so the passes nest a group task into it.
var worker_threads: int = 1
## signature -> {"h": HMap, "w": HMap}; read from the previous compose, written for this one.
var previous_cache: Dictionary = {}
var cache: Dictionary = {}
## node_id -> HMap of the weight the unit was blended with (surface contributions, queries).
var unit_weights: Dictionary = {}
## Pre-evaluated maps by signature (GPU field kernels fill this before the worker runs).
var injected: Dictionary = {}
## FIELD units this compose produced a map for: CPU evaluation, a prefetched evaluation, or a map a
## GPU kernel injected. Every applied field counts exactly once here or in [member reused]; the
## injected ones used to be invisible, so a GPU build reported one field fewer than the plan has.
var evaluated: int = 0
## Of [member evaluated], how many maps came from an injected GPU kernel.
var gpu_evaluated: int = 0
## Signatures filled by [method _prefetch_fields] that no apply has counted yet.
var fresh: Dictionary = {}
var reused: int = 0

## Compose [param plan]. Returns the terrain composite as a full-grid HMap.
func compose(plan, p_grid, base_height: float, min_height: float = -INF, max_height: float = INF) -> RefCounted:
	grid = p_grid
	cache = {}
	unit_weights = {}
	evaluated = 0
	reused = 0
	fresh = {}
	var composite := HMap.new(grid.full_rect(), base_height)
	_prefetch_fields(plan)
	_compose_children(plan.root.children, composite, composite, composite, -1)
	for unit in plan.post:
		_apply_unit(unit, composite, composite, composite, -1)
	if min_height > -INF or max_height < INF:
		var full: Rect2i = grid.full_rect()
		_clamp_rows(composite.data, full.size.x, full.size.y, min_height, max_height)
	return composite

## Clamp a full-width buffer of [param rows] rows in place, in bands.
func _clamp_rows(d: PackedFloat32Array, width: int, rows: int, lo: float, hi: float) -> void:
	BandTask.run_rows(worker_threads, rows, 0, func(y0: int, y1: int) -> void:
		var i := y0 * width
		var last := y1 * width
		while i < last:
			d[i] = clampf(d[i], lo, hi)
			i += 1, BAND_MIN_ROWS)

## Evaluate every field the compose will need up front, on the pool: the fields are independent
## snapshots, so the whole stage-2 evaluation of a compose is one group task instead of a
## per-unit serial walk inside the (order dependent) blend. Every unit that a band writes is
## registered in [member cache] first, so [method evaluate_field] finds it and does no work.
func _prefetch_fields(plan) -> void:
	var pending: Array = []
	var seen: Dictionary = {}
	for unit in plan.all_units():
		if unit.kind != CompositionPlan.UnitKind.FIELD:
			continue
		var sig: String = unit.snap.signature
		if cache.has(sig) or injected.has(sig) or previous_cache.has(sig) or seen.has(sig):
			continue
		seen[sig] = true
		pending.append(unit)
	if pending.is_empty():
		return
	var jobs: Array = []
	for unit in pending:
		var snap = unit.snap
		var rect: Rect2i = snap.pixel_rect(grid)
		var ev := {"h": HMap.new(rect), "w": HMap.new(rect)}
		cache[unit.snap.signature] = ev
		fresh[unit.snap.signature] = true
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		var count := BandTask.band_count(rect.size.y, worker_threads, BAND_MIN_ROWS)
		for b in count:
			var rng := BandTask.band_range(rect.size.y, count, b)
			jobs.append({
				"snap": snap, "rect": rect, "y0": rng.x, "y1": rng.y,
				"hd": ev["h"].data, "wd": ev["w"].data,
			})
	if jobs.is_empty():
		return
	BandTask.run(worker_threads, jobs.size(), func(i: int) -> void:
		var job: Dictionary = jobs[i]
		job["snap"].evaluate_band(grid, job["rect"], job["y0"], job["y1"], job["hd"], job["wd"]))

func _compose_children(children: Array, own, group, datum, datum_mode: int) -> void:
	for child in children:
		var target = own if child.space == 0 else group
		_apply_unit(child, target, group, datum, datum_mode)

## [param datum] is the absolute (generator-local) map that [param target]'s delta is measured
## against; [param datum_mode] is the blend mode of that relationship (ADD/SUBTRACT need the
## rebase, target modes are already absolute levels).
func _apply_unit(unit, target, group, datum = null, datum_mode: int = -1) -> void:
	match unit.kind:
		CompositionPlan.UnitKind.MODIFIER:
			_apply_modifier(unit.snap, target, datum, datum_mode)
		CompositionPlan.UnitKind.FIELD:
			_apply_field(unit, target, group, datum, datum_mode)
		CompositionPlan.UnitKind.GROUP:
			_apply_group(unit, target, datum)

func _apply_modifier(snap, target, datum, datum_mode: int) -> void:
	var offset := 0.0
	var scale := 1.0
	if datum != null and snap.uses_target_height():
		var gp: Vector2 = grid.sample_of(snap.center)
		var level: float = datum.sample_bilinear(gp.x, gp.y)
		match datum_mode:
			TerrainTypes.BlendMode.ADD:
				offset = -level
			TerrainTypes.BlendMode.SUBTRACT:
				offset = level
				scale = -1.0
	snap.apply(target, grid, offset, scale, worker_threads)

func evaluate_field(unit) -> Dictionary:
	var sig: String = unit.snap.signature
	if cache.has(sig):
		# A prefetched field counts as evaluated when it is first applied, not when it was filled.
		if fresh.erase(sig):
			evaluated += 1
		else:
			reused += 1
		return cache[sig]
	var ev = injected.get(sig)
	if ev != null:
		# A GPU kernel filled this map. It is still this field's evaluation, so it counts as
		# evaluated; gpu_evaluated is what separates it from the CPU ones.
		evaluated += 1
		gpu_evaluated += 1
	else:
		ev = previous_cache.get(sig)
		if ev != null:
			reused += 1
	if ev == null:
		ev = unit.snap.evaluate(grid)
		evaluated += 1
	cache[sig] = ev
	return ev

func _apply_field(unit, target, group, datum, datum_mode: int = -1) -> void:
	var ev := evaluate_field(unit)
	var h = ev["h"]
	var w = ev["w"]
	if h.is_empty():
		return
	var has_local := false
	for child in unit.children:
		if child.space == 0:
			has_local = true
			break
	if has_local:
		h = h.duplicate_map()
		# An additive field's own map is a delta over the composite it blends into; a target-mode
		# field's map already holds absolute levels.
		var delta := TerrainTypes.is_delta_blend(unit.blend_mode)
		var local_datum = (datum if datum != null else target) if delta else h
		var local_mode: int = unit.blend_mode if delta else -1
		for child in unit.children:
			if child.space == 0:
				_apply_unit(child, h, group, local_datum, local_mode)
	var weights: PackedFloat32Array = w.data
	if unit.mask != null:
		weights = weights.duplicate()
		var m: PackedFloat32Array = unit.mask.weights(grid, w.rect, target, worker_threads)
		for i in weights.size():
			weights[i] *= m[i]
	_blend(target, h, weights, unit.blend_mode, 1.0)
	var wmap := HMap.new(Rect2i())
	wmap.rect = w.rect
	wmap.data = weights
	unit_weights[unit.node_id] = wmap
	for child in unit.children:
		if child.space != 0:
			_apply_unit(child, group, group, datum, datum_mode)

func _apply_group(unit, target, datum) -> void:
	# A group only needs the part of the grid its children can reach. Allocating two full-grid maps
	# per group (composite + coverage, 134 MB at 4096 cells) was what a group whose children occupy
	# 50 m cost; the composite is identical because everything outside the union stays 0.
	var rect := _group_rect(unit)
	if rect.size.x <= 0 or rect.size.y <= 0:
		rect = grid.full_rect()
	var gmap := HMap.new(rect)
	gmap.set_meta("coverage", HMap.new(rect))
	# Delta groups accumulate deltas over the enclosing absolute map; target-mode groups hold
	# absolute levels in their own map, which becomes the datum for their children.
	var delta := TerrainTypes.is_delta_blend(unit.blend_mode)
	var child_datum = (datum if datum != null else target) if delta else gmap
	var child_mode: int = unit.blend_mode if delta else -1
	_compose_children(unit.children, gmap, gmap, child_datum, child_mode)
	var coverage = gmap.get_meta("coverage")
	var weights: PackedFloat32Array = coverage.data
	_blend(target, gmap, weights, unit.blend_mode, unit.strength)
	var wmap := HMap.new(Rect2i())
	wmap.rect = coverage.rect
	wmap.data = weights
	unit_weights[unit.node_id] = wmap

## Pixel rect a group composite needs: the union of its children's own rects, clipped to the grid.
## Returns an empty rect (= "use the full grid") when any child is unbounded, because such a child
## writes beyond any union and clipping it would change the composite.
func _group_rect(unit) -> Rect2i:
	var union := Rect2i()
	var first := true
	for child in unit.children:
		var r := _unit_rect(child)
		if r.size.x <= 0 or r.size.y <= 0:
			return Rect2i()
		union = r if first else union.merge(r)
		first = false
	if first:
		return Rect2i()
	return union.intersection(grid.full_rect())

## The rect a unit writes into its group composite, or an empty rect when it has none.
func _unit_rect(unit) -> Rect2i:
	match unit.kind:
		CompositionPlan.UnitKind.FIELD:
			return unit.snap.pixel_rect(grid)
		CompositionPlan.UnitKind.MODIFIER:
			# A blur reads a margin from the whole map; clipped to the group rect it would clamp at
			# that edge instead of reading the zeros outside it.
			if not unit.snap.has_bounds or unit.snap.reads_neighbours():
				return Rect2i()
			return grid.rect_for_world(unit.snap.bounds, 1)
		CompositionPlan.UnitKind.GROUP:
			return _group_rect(unit)
	return Rect2i()

## Optional GPU blend hook, injected by the generator. The evaluation layer must not preload the
## build layer -- that closes eval -> build -> eval -- so the caller supplies it instead.
## Callable(target, src, weights, mode, scale) -> bool: true when the GPU applied the blend.
var gpu_blend_hook: Callable = Callable()

## GPU compositor when the hook is supplied (main-thread composition) and the target carries no
## coverage bookkeeping; the CPU twin otherwise.
var gpu_blends: int = 0

func _blend(target, src, weights: PackedFloat32Array, mode: int, scale: float) -> void:
	if gpu_blend_hook.is_valid() and not target.has_meta("coverage"):
		if gpu_blend_hook.call(target, src, weights, mode, scale):
			gpu_blends += 1
			return
	var rect: Rect2i = target.rect.intersection(src.rect)
	var count := BandTask.band_count(rect.size.y, worker_threads, BAND_MIN_ROWS)
	if count <= 1:
		blend(target, src, weights, mode, scale)
		return
	BandTask.run(worker_threads, count, func(i: int) -> void:
		var rng := BandTask.band_range(rect.size.y, count, i)
		blend(target, src, weights, mode, scale, rect.position.y + rng.x, rect.position.y + rng.y))

## Blend [param src] into [param target] over their overlap. [param weights] is laid out like
## src. When the target carries a coverage map (group composites), coverage = max(coverage, w).
##
## Rows `[y_from, y_to)` (absolute grid rows, -1 = the whole overlap) are the unit of parallel
## work: a band only reads and writes its own rows of [param target], so bands never overlap.
static func blend(target, src, weights: PackedFloat32Array, mode: int, scale: float,
		y_from: int = -1, y_to: int = -1) -> void:
	var rect: Rect2i = target.rect.intersection(src.rect)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var y0: int = rect.position.y if y_from < 0 else maxi(rect.position.y, y_from)
	var y1: int = rect.end.y if y_to < 0 else mini(rect.end.y, y_to)
	if y1 <= y0:
		return
	var td: PackedFloat32Array = target.data
	var sd: PackedFloat32Array = src.data
	var tw: int = target.rect.size.x
	var sw: int = src.rect.size.x
	var coverage = target.get_meta("coverage") if target.has_meta("coverage") else null
	var cd: PackedFloat32Array = coverage.data if coverage != null else PackedFloat32Array()
	var x_off: int = rect.position.x - target.rect.position.x
	var sx_off: int = rect.position.x - src.rect.position.x
	# ADD is what a plain terrain field blends with, i.e. most of the pixels: inline it rather than
	# calling blend_value() per sample.
	var is_add := mode == TerrainTypes.BlendMode.ADD
	for gy in range(y0, y1):
		var trow: int = (gy - target.rect.position.y) * tw + x_off
		var srow: int = (gy - src.rect.position.y) * sw + sx_off
		for x in rect.size.x:
			var si := srow + x
			var ws := weights[si] * scale
			if ws <= 0.0:
				continue
			var ti := trow + x
			if is_add:
				td[ti] = td[ti] + sd[si] * ws
			else:
				td[ti] = blend_value(td[ti], sd[si], ws, mode)
			if coverage != null:
				cd[ti] = maxf(cd[ti], minf(weights[si], 1.0))

## Single-sample blend (CPU reference for the GPU compositor; keep in sync with blend.glsl).
## ADD/SUBTRACT/MULTIPLY/REPLACE keep the 0.7 formulas; MAX/MIN/AVERAGE are lerped by the
## weight so they stay continuous at the domain edge.
static func blend_value(t: float, h: float, ws: float, mode: int) -> float:
	match mode:
		TerrainTypes.BlendMode.ADD:
			return t + h * ws
		TerrainTypes.BlendMode.SUBTRACT:
			return t - h * ws
		TerrainTypes.BlendMode.MAX:
			return t + (maxf(t, h) - t) * minf(ws, 1.0)
		TerrainTypes.BlendMode.MIN:
			return t + (minf(t, h) - t) * minf(ws, 1.0)
		TerrainTypes.BlendMode.MULTIPLY:
			return t * (1.0 + h * ws)
		TerrainTypes.BlendMode.AVERAGE:
			return t + ((t + h) * 0.5 - t) * minf(ws, 1.0)
		TerrainTypes.BlendMode.REPLACE:
			return t + (h - t) * minf(ws, 1.0)
	return t + h * ws
