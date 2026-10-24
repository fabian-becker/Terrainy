@tool
@icon("res://addons/terrainy/icons/paint_layer.svg")
class_name TerrainPaintLayer
extends Node

## One entry of a generator's paint stack (a direct child of the [TerrainGenerator]; scene
## order = application order, drag to reorder).
##
## Paint is always the last stage in height order: procedural recomposition never destroys or
## displaces a stroke, strokes stay anchored in world XZ and re-compose against the new surface.
## Each layer keeps its own grid of `TerrainGenerator.paint_layer_grid` pixels across the
## terrain, independent of terrain_resolution. The pixel data lives in the scene's paint bundle
## (`.tpaint`), not in the scene file.
##
## Data encoding per kind:
## - HEIGHT_DELTA: FORMAT_RF, signed meters added to the composed height
## - HEIGHT_ABSOLUTE: FORMAT_RGF, R = pinned height (generator-local meters), G = coverage
## - SMOOTH: FORMAT_R8, smoothing strength
## - TEXTURE: FORMAT_R8, weight plane of palette layer [member texture_layer_index]
## - MASK: FORMAT_R8, coverage, referenced through [TerrainMaskPaint]

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")

enum PaintKind { HEIGHT_DELTA, HEIGHT_ABSOLUTE, SMOOTH, TEXTURE, MASK }

signal layer_changed(layer: TerrainPaintLayer)

@export var kind: PaintKind = PaintKind.HEIGHT_DELTA:
	set(value):
		if kind == value:
			return
		kind = value
		if _data != null:
			_data = null
			_ensure_data()
		_changed(true)

@export var enabled: bool = true:
	set(value):
		enabled = value
		_changed(true)

## Layer blend strength.
@export_range(0.0, 1.0, 0.001) var opacity: float = 1.0:
	set(value):
		opacity = clampf(value, 0.0, 1.0)
		_changed(true)

@export var mask: TerrainMaskResource:
	set(value):
		if mask and mask.changed.is_connected(_on_mask_changed):
			mask.changed.disconnect(_on_mask_changed)
		mask = value
		if mask:
			mask.changed.connect(_on_mask_changed)
		_changed(true)

@export var invert_mask: bool = false:
	set(value):
		invert_mask = value
		_changed(true)

## TEXTURE kind: palette index (TerrainGenerator.texture_layers + contribution-owned layers).
@export var texture_layer_index: int = 0:
	set(value):
		texture_layer_index = maxi(value, 0)
		_changed(true)

## SMOOTH kind: blur radius in meters.
@export_range(0.5, 32.0, 0.1) var smooth_radius: float = 3.0:
	set(value):
		smooth_radius = value
		_changed(true)

## Stable identity inside the paint bundle.
@export var layer_uid: String = ""

## Bumped on every data/parameter commit; joins the compose signature.
@export_storage var revision: int = 0

var _data: Image = null
var _float_cache: Array = []
var _float_cache_revision: int = -1
## Pixel rect that may hold non-zero data (conservative).
var content_rect: Rect2i = Rect2i()
var _grid: int = 0

func _init() -> void:
	if layer_uid.is_empty():
		layer_uid = _new_uid()

static func _new_uid() -> String:
	return "%08x%08x" % [randi(), Time.get_ticks_usec() & 0xffffffff]

func _validate_property(property: Dictionary) -> void:
	match property["name"]:
		"texture_layer_index":
			if kind != PaintKind.TEXTURE:
				property["usage"] = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE
		"smooth_radius":
			if kind != PaintKind.SMOOTH:
				property["usage"] = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE
		"layer_uid":
			property["usage"] = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE

func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		var generator := get_generator()
		if generator:
			generator.notify_paint_structure_changed()
	elif what == NOTIFICATION_EXIT_TREE:
		var generator := get_parent()
		if generator is TerrainGenerator:
			generator.notify_paint_structure_changed()

func get_generator() -> TerrainGenerator:
	return get_parent() as TerrainGenerator

func is_weight_kind() -> bool:
	return kind == PaintKind.SMOOTH or kind == PaintKind.TEXTURE or kind == PaintKind.MASK

static func format_for(p_kind: int) -> int:
	match p_kind:
		PaintKind.HEIGHT_DELTA:
			return Image.FORMAT_RF
		PaintKind.HEIGHT_ABSOLUTE:
			return Image.FORMAT_RGF
	return Image.FORMAT_R8

func grid_size() -> int:
	if _data != null:
		return _data.get_width()
	var generator := get_generator()
	return generator.paint_layer_grid if generator else 1024

## The layer image (allocated empty on first use).
func get_data() -> Image:
	_ensure_data()
	return _data

func has_data() -> bool:
	return _data != null and content_rect.size.x > 0 and content_rect.size.y > 0

func _ensure_data() -> void:
	var size := grid_size()
	if _data != null and _data.get_format() == format_for(kind):
		return
	_data = Image.create(size, size, false, format_for(kind))
	content_rect = Rect2i()

## Replace the data image (bundle load, resample, undo). The format must match the kind.
## [param bump] is false when restoring stored data (bundle load): the revision recorded with
## the data already describes it, and opening a scene must not make the bundle look edited.
func set_data(image: Image, p_content_rect: Rect2i = Rect2i(-1, -1, 0, 0), bump: bool = true) -> void:
	if image != null and image.get_format() != format_for(kind):
		image = image.duplicate()
		image.convert(format_for(kind))
	_data = image
	if p_content_rect.position.x < 0:
		content_rect = compute_content_rect(image)
	else:
		content_rect = p_content_rect
	if bump:
		commit_data()
	else:
		_float_cache_revision = -1
		layer_changed.emit(self)

## Clear all painted data.
func clear() -> void:
	_data = null
	_ensure_data()
	commit_data()

## Record a data change (stroke commit, undo). Invalidates caches and signatures.
func commit_data() -> void:
	revision += 1
	_float_cache_revision = -1
	layer_changed.emit(self)

## Float view of the data: [value] for single channel kinds, [value, coverage] for absolute.
## Cached per revision.
func get_float_channels() -> Array:
	_ensure_data()
	if _float_cache_revision == revision and not _float_cache.is_empty():
		return _float_cache
	var channels: Array = []
	if kind == PaintKind.HEIGHT_ABSOLUTE:
		var rg := _data.get_data().to_float32_array()
		var v := PackedFloat32Array()
		var c := PackedFloat32Array()
		v.resize(rg.size() / 2)
		c.resize(rg.size() / 2)
		for i in v.size():
			v[i] = rg[i * 2]
			c[i] = rg[i * 2 + 1]
		channels = [v, c]
	elif kind == PaintKind.HEIGHT_DELTA:
		channels = [_data.get_data().to_float32_array()]
	else:
		var copy := _data.duplicate() as Image
		copy.convert(Image.FORMAT_RF)
		channels = [copy.get_data().to_float32_array()]
	_float_cache = channels
	_float_cache_revision = revision
	return channels

## Refresh the float cache inside a paint px rect after the image was edited there (strokes),
## instead of reconverting the whole layer.
func patch_float_cache(rect: Rect2i) -> void:
	if _float_cache.is_empty() or _float_cache_revision < 0:
		_float_cache_revision = -1
		return
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, _data.get_size()))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		_float_cache_revision = revision
		return
	var region := _data.get_region(clipped)
	var g := _data.get_width()
	var channels: Array
	match kind:
		PaintKind.HEIGHT_ABSOLUTE:
			var rg := region.get_data().to_float32_array()
			var v := PackedFloat32Array()
			var c := PackedFloat32Array()
			v.resize(rg.size() / 2)
			c.resize(rg.size() / 2)
			for i in v.size():
				v[i] = rg[i * 2]
				c[i] = rg[i * 2 + 1]
			channels = [v, c]
		PaintKind.HEIGHT_DELTA:
			channels = [region.get_data().to_float32_array()]
		_:
			region.convert(Image.FORMAT_RF)
			channels = [region.get_data().to_float32_array()]
	for ci in channels.size():
		var dst: PackedFloat32Array = _float_cache[ci]
		var src: PackedFloat32Array = channels[ci]
		for y in clipped.size.y:
			var drow := (clipped.position.y + y) * g + clipped.position.x
			var srow := y * clipped.size.x
			for x in clipped.size.x:
				dst[drow + x] = src[srow + x]
	_float_cache_revision = revision
	layer_changed.emit(self)

func get_float_data() -> PackedFloat32Array:
	return get_float_channels()[0]

## Bounding rect of non-zero pixels (coverage channel for absolute layers).
static func compute_content_rect(image: Image) -> Rect2i:
	if image == null or image.is_empty():
		return Rect2i()
	var data: PackedFloat32Array
	var stride := 1
	var channel := 0
	match image.get_format():
		Image.FORMAT_RF:
			data = image.get_data().to_float32_array()
		Image.FORMAT_RGF:
			data = image.get_data().to_float32_array()
			stride = 2
			channel = 1
		_:
			var copy := image.duplicate() as Image
			copy.convert(Image.FORMAT_RF)
			data = copy.get_data().to_float32_array()
	return content_rect_of(data, image.get_width(), image.get_height(), stride, channel)

static func content_rect_of(data: PackedFloat32Array, w: int, h: int, stride: int = 1, channel: int = 0) -> Rect2i:
	var x0 := w
	var x1 := -1
	var y0 := h
	var y1 := -1
	var row_len := w * stride
	for y in h:
		var row := data.slice(y * row_len, (y + 1) * row_len)
		if row.count(0.0) == row_len:
			continue
		y0 = mini(y0, y)
		y1 = y
		for x in w:
			if row[x * stride + channel] != 0.0:
				x0 = mini(x0, x)
				break
		for x in range(w - 1, -1, -1):
			if row[x * stride + channel] != 0.0:
				x1 = maxi(x1, x)
				break
	if x1 < 0 or y1 < 0:
		return Rect2i()
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)

## World XZ bounds of the painted content (empty Rect2 when nothing is painted).
func get_content_world_rect() -> Rect2:
	var generator := get_generator()
	if generator == null or not has_data():
		return Rect2()
	var world: Rect2 = generator.get_terrain_world_rect()
	var px := world.size.x / float(grid_size())
	return Rect2(world.position + Vector2(content_rect.position) * px, Vector2(content_rect.size) * px)

## Value at a world position (bilinear; coverage-weighted value for absolute layers).
func sample_world(world_xz: Vector2) -> float:
	var generator := get_generator()
	if generator == null:
		return 0.0
	var world: Rect2 = generator.get_terrain_world_rect()
	var g := grid_size()
	var fx := (world_xz.x - world.position.x) / world.size.x * g - 0.5
	var fy := (world_xz.y - world.position.y) / world.size.y * g - 0.5
	var channels := get_float_channels()
	return Raster.sample_buffer(channels[0], Vector2i(g, g), fx, fy)

## Snapshot used by the paint stage. [param copy] duplicates the pixel buffers (required for
## worker jobs; main-thread stroke updates pass false and read the live cache).
func make_snapshot(context: Dictionary, copy: bool = true) -> Dictionary:
	var mask_snap = null
	if mask:
		var mask_ctx := context.duplicate()
		var gen_xform: Transform3D = context.get("generator_xform", Transform3D.IDENTITY)
		mask_ctx["owner_xform"] = gen_xform
		mask_ctx["owner_node"] = get_parent()
		mask_snap = mask.make_snapshot(mask_ctx)
		if invert_mask:
			mask_snap.invert = not mask_snap.invert
	var channels := get_float_channels()
	return {
		"uid": layer_uid,
		"name": String(name),
		"kind": int(kind),
		"opacity": opacity,
		"mask": mask_snap,
		"texture_layer": texture_layer_index,
		"smooth_radius": smooth_radius,
		"grid": grid_size(),
		"value": channels[0].duplicate() if copy else channels[0],
		"coverage": (channels[1].duplicate() if copy else channels[1]) if channels.size() > 1 else PackedFloat32Array(),
		"content_rect": content_rect,
		"revision": revision,
		"signature": "%s:%d:%d:%s:%s:%d:%s:%d" % [layer_uid, int(kind), revision, var_to_str(opacity),
			var_to_str(smooth_radius), texture_layer_index, var_to_str(mask_snap.signature) if mask_snap else "-", int(invert_mask)],
	}

func _on_mask_changed() -> void:
	_changed(true)

func _changed(bump: bool) -> void:
	if bump:
		revision += 1
	layer_changed.emit(self)

## Pixel rect (absolute paint px) read back from the data, for undo.
func copy_rect(rect: Rect2i) -> Image:
	_ensure_data()
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, _data.get_size()))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return null
	return _data.get_region(clipped)

## Write a pixel rect back (undo / redo). [param content] is the content rect to restore.
func paste_rect(image: Image, at: Vector2i, content: Rect2i) -> void:
	_ensure_data()
	if image == null:
		return
	_data.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), at)
	content_rect = content
	commit_data()
	var generator := get_generator()
	if generator:
		generator.notify_paint_rect_changed(self, Rect2i(at, image.get_size()))
