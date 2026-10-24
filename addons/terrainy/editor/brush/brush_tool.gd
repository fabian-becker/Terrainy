@tool
extends RefCounted

## Editor brush tool: viewport input -> stamp lists -> TerrainGenerator.paint_stamps().
##
## One EditorUndoRedoManager action per stroke commit, storing the affected layer rect before
## and after (rectangular diff, cheap for stroke-sized regions). No runtime API in 2.0.

const BrushStamp = preload("res://addons/terrainy/gen/paint/brush_stamp.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")
const StrokeOp = BrushStamp.StrokeOp

signal changed

var undo_redo: EditorUndoRedoManager = null
var generator: TerrainGenerator = null
## Active paint layer (null = pick / create one for the op).
var layer: TerrainPaintLayer = null
## -1 = brush off.
var op: int = -1
var radius: float = 8.0
var strength: float = 0.5
## Meters per stamp for height ops at strength 1.
var height_scale: float = 1.0
var falloff: Curve = null
## TEXTURE op: palette index.
var texture_index: int = 0
## TEXTURE op: erase the selected texture's weight instead of adding it (persistent mode; Ctrl
## does the same for a single stroke).
var texture_erase: bool = false
## FLATTEN: absolute target (used while Shift is held or when use_absolute is on).
var absolute_height: float = 0.0
var use_absolute: bool = false
var noise_seed: int = 0

var _stroking: bool = false
var _stroke_layer: TerrainPaintLayer = null
var _before: Image = null
var _before_content: Rect2i = Rect2i()
var _stroke_rect: Rect2i = Rect2i()
var _last_pos: Vector3 = Vector3.INF
var _flatten_target: float = 0.0
var _cursor: Vector3 = Vector3.INF
var _erase: bool = false
var _noise: FastNoiseLite = null

func _init() -> void:
	falloff = Curve.new()
	falloff.add_point(Vector2(0, 0), 0, 0)
	falloff.add_point(Vector2(1, 1), 0, 0)

func is_active() -> bool:
	return op >= 0 and generator != null and is_instance_valid(generator)

func get_cursor() -> Vector3:
	return _cursor

## Ray-march the composed terrain (no physics needed). Returns Vector3.INF on a miss.
func raycast(camera: Camera3D, screen: Vector2) -> Vector3:
	if generator == null or not generator.has_terrain():
		return Vector3.INF
	var origin := camera.project_ray_origin(screen)
	var dir := camera.project_ray_normal(screen)
	var step: float = maxf(generator.terrain_size / float(generator.terrain_resolution), 0.25)
	var max_dist: float = generator.terrain_size * 4.0 + origin.distance_to(generator.global_position)
	var prev := origin
	var prev_above := prev.y - generator.get_height_at(prev)
	var dist := 0.0
	while dist < max_dist:
		dist += step
		var p := origin + dir * dist
		var above := p.y - generator.get_height_at(p)
		if above <= 0.0 and prev_above > 0.0:
			var a := prev
			var b := p
			for _i in 12:
				var m := (a + b) * 0.5
				if m.y - generator.get_height_at(m) > 0.0:
					a = m
				else:
					b = m
			var hit := (a + b) * 0.5
			if generator.get_terrain_world_rect().has_point(Vector2(hit.x, hit.z)):
				return hit
			return Vector3.INF
		prev = p
		prev_above = above
	return Vector3.INF

## Returns true when the event was consumed.
func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if not is_active():
		return false
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_BRACKETLEFT:
			radius = maxf(radius / 1.15, 0.5)
			changed.emit()
			return true
		if event.keycode == KEY_BRACKETRIGHT:
			radius = minf(radius * 1.15, 512.0)
			changed.emit()
			return true
	if event is InputEventMouseMotion:
		_cursor = raycast(camera, event.position)
		if _stroking and _cursor != Vector3.INF:
			_erase = event.ctrl_pressed
			_stroke_to(_cursor)
		return _stroking
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var hit := raycast(camera, event.position)
			if hit == Vector3.INF:
				return false
			_erase = event.ctrl_pressed
			_begin_stroke(hit, event.shift_pressed)
			return true
		elif _stroking:
			_end_stroke()
			return true
	return false

func _resolve_layer() -> TerrainPaintLayer:
	var kinds: Array = []
	match op:
		StrokeOp.TEXTURE:
			for l in generator.get_paint_layers():
				if l.kind == TerrainPaintLayer.PaintKind.TEXTURE and l.texture_layer_index == texture_index:
					return l
			var created := generator.add_paint_layer(TerrainPaintLayer.PaintKind.TEXTURE, "Texture%d" % texture_index)
			created.texture_layer_index = texture_index
			return created
		StrokeOp.MASK:
			kinds = [TerrainPaintLayer.PaintKind.MASK]
		StrokeOp.SMOOTH:
			kinds = [TerrainPaintLayer.PaintKind.SMOOTH, TerrainPaintLayer.PaintKind.HEIGHT_DELTA, TerrainPaintLayer.PaintKind.HEIGHT_ABSOLUTE]
		_:
			kinds = [TerrainPaintLayer.PaintKind.HEIGHT_DELTA, TerrainPaintLayer.PaintKind.HEIGHT_ABSOLUTE]
	if layer and is_instance_valid(layer) and layer.get_parent() == generator and kinds.has(int(layer.kind)):
		return layer
	for l in generator.get_paint_layers():
		if kinds.has(int(l.kind)):
			return l
	var kind: int = kinds[0] if op != StrokeOp.SMOOTH else TerrainPaintLayer.PaintKind.HEIGHT_DELTA
	return generator.add_paint_layer(kind, "Mask" if op == StrokeOp.MASK else "Sculpt")

func _begin_stroke(hit: Vector3, shift: bool) -> void:
	_stroke_layer = _resolve_layer()
	layer = _stroke_layer
	_before = _stroke_layer.get_data().duplicate()
	_before_content = _stroke_layer.content_rect
	_stroke_rect = Rect2i()
	_stroking = true
	_last_pos = Vector3.INF
	var gy := generator.global_position.y
	_flatten_target = (absolute_height - gy) if (shift or use_absolute) else generator.local_height_at(Vector2(hit.x, hit.z))
	if op == StrokeOp.STAMP_NOISE:
		_noise = FastNoiseLite.new()
		_noise.seed = int(hash([generator.noise_seed, noise_seed]))
		_noise.frequency = 1.0 / maxf(radius, 1.0)
	_stroke_to(hit)

func _stroke_to(pos: Vector3) -> void:
	var spacing := maxf(radius * 0.25, 0.25)
	var stamps: Array = []
	if _last_pos == Vector3.INF:
		stamps.append(_make_stamp(pos))
		_last_pos = pos
	else:
		var flat_from := Vector2(_last_pos.x, _last_pos.z)
		var flat_to := Vector2(pos.x, pos.z)
		var d := flat_from.distance_to(flat_to)
		var n := int(d / spacing)
		for i in n:
			var p := flat_from.move_toward(flat_to, spacing * (i + 1))
			stamps.append(_make_stamp(Vector3(p.x, pos.y, p.y)))
		if n > 0:
			var last := flat_from.move_toward(flat_to, spacing * n)
			_last_pos = Vector3(last.x, pos.y, last.y)
	if stamps.is_empty():
		return
	var rect := generator.paint_stamps(_stroke_layer, stamps)
	if rect.size.x > 0:
		_stroke_rect = rect if _stroke_rect.size.x <= 0 else _stroke_rect.merge(rect)

func _is_erasing() -> bool:
	return _erase or (op == StrokeOp.TEXTURE and texture_erase)

func _make_stamp(pos: Vector3):
	var s := BrushStamp.new(op, pos, radius, strength)
	s.falloff_lut = CurveLut.bake(falloff, 1.0, 64)
	s.erase = _is_erasing()
	match op:
		StrokeOp.RAISE, StrokeOp.LOWER, StrokeOp.STAMP_NOISE:
			s.strength = strength * height_scale
		StrokeOp.FLATTEN:
			s.value = _flatten_target
		StrokeOp.TEXTURE, StrokeOp.MASK:
			s.value = 0.0 if _erase else 1.0
	s.noise = _noise
	return s

func _end_stroke() -> void:
	_stroking = false
	if _stroke_layer == null or _stroke_rect.size.x <= 0 or _before == null:
		return
	var rect := _stroke_rect
	var before := _before.get_region(rect)
	var after := _stroke_layer.copy_rect(rect)
	if undo_redo:
		undo_redo.create_action("terrainy: paint stroke (%s)" % StrokeOp.keys()[op].capitalize())
		undo_redo.add_do_method(_stroke_layer, "paste_rect", after, rect.position, _stroke_layer.content_rect)
		undo_redo.add_undo_method(_stroke_layer, "paste_rect", before, rect.position, _before_content)
		undo_redo.commit_action(false)
	_before = null
	generator.schedule_paint_save()

## Projected brush ring + falloff ring for _forward_3d_draw_over_viewport.
func draw_overlay(overlay: Control, camera: Camera3D) -> void:
	if not is_active() or _cursor == Vector3.INF:
		return
	var erasing := _is_erasing()
	var color := Color(1.0, 0.45, 0.35) if erasing else Color(0.55, 0.95, 0.6)
	for ring in [[1.0, 2.0], [0.5, 1.0]]:
		var r: float = radius * ring[0]
		var points := PackedVector2Array()
		for i in 49:
			var a := TAU * i / 48.0
			var p := _cursor + Vector3(cos(a) * r, 0, sin(a) * r)
			p.y = generator.get_height_at(p) + 0.05
			if camera.is_position_behind(p):
				continue
			points.append(camera.unproject_position(p))
		if points.size() > 1:
			overlay.draw_polyline(points, Color(color, 0.9 if ring[0] == 1.0 else 0.4), ring[1])
	var label := "%s%s  r=%.1f  s=%.2f" % [
		StrokeOp.keys()[op].capitalize(), " (erase)" if erasing else "", radius, strength]
	overlay.draw_string(overlay.get_theme_default_font(), camera.unproject_position(_cursor) + Vector2(12, -12), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)
