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

var grid = null
## signature -> {"h": HMap, "w": HMap}; read from the previous compose, written for this one.
var previous_cache: Dictionary = {}
var cache: Dictionary = {}
## node_id -> HMap of the weight the unit was blended with (surface contributions, queries).
var unit_weights: Dictionary = {}
## Pre-evaluated maps by signature (GPU field kernels fill this before the worker runs).
var injected: Dictionary = {}
var evaluated: int = 0
var reused: int = 0

## Compose [param plan]. Returns the terrain composite as a full-grid HMap.
func compose(plan, p_grid, base_height: float, min_height: float = -INF, max_height: float = INF) -> RefCounted:
	grid = p_grid
	cache = {}
	unit_weights = {}
	evaluated = 0
	reused = 0
	var composite := HMap.new(grid.full_rect(), base_height)
	_compose_children(plan.root.children, composite, composite, composite, -1)
	for unit in plan.post:
		_apply_unit(unit, composite, composite, composite, -1)
	if min_height > -INF or max_height < INF:
		var d := composite.data
		for i in d.size():
			d[i] = clampf(d[i], min_height, max_height)
	return composite

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
	snap.apply(target, grid, offset, scale)

func evaluate_field(unit) -> Dictionary:
	var sig: String = unit.snap.signature
	if cache.has(sig):
		reused += 1
		return cache[sig]
	var ev = injected.get(sig)
	if ev == null:
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
		var m: PackedFloat32Array = unit.mask.weights(grid, w.rect, target)
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
	var gmap := HMap.new(grid.full_rect())
	gmap.set_meta("coverage", HMap.new(grid.full_rect()))
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
	blend(target, src, weights, mode, scale)

## Blend [param src] into [param target] over their overlap. [param weights] is laid out like
## src. When the target carries a coverage map (group composites), coverage = max(coverage, w).
static func blend(target, src, weights: PackedFloat32Array, mode: int, scale: float) -> void:
	var rect: Rect2i = target.rect.intersection(src.rect)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var td: PackedFloat32Array = target.data
	var sd: PackedFloat32Array = src.data
	var tw: int = target.rect.size.x
	var sw: int = src.rect.size.x
	var coverage = target.get_meta("coverage") if target.has_meta("coverage") else null
	var cd: PackedFloat32Array = coverage.data if coverage != null else PackedFloat32Array()
	for y in rect.size.y:
		var gy := rect.position.y + y
		var trow: int = (gy - target.rect.position.y) * tw + (rect.position.x - target.rect.position.x)
		var srow: int = (gy - src.rect.position.y) * sw + (rect.position.x - src.rect.position.x)
		for x in rect.size.x:
			var si := srow + x
			var ws := weights[si] * scale
			if ws <= 0.0:
				continue
			var ti := trow + x
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
