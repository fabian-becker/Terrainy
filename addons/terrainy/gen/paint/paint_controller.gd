extends RefCounted

## Paint layers: discovery, brush strokes, resampling and `.tpaint` persistence.
##
## Extracted from TerrainGenerator so the node keeps the composition pipeline and this class
## keeps everything about painted *data*. It does not own the recompose: after a stroke it calls
## back into the host, which knows how to rebuild the terrain under the touched rect.
##
## The host is duck-typed (a TerrainGenerator) and must provide:
##
##   properties: terrain_size, paint_layer_grid, paint_section, paint_bundle_path, paint_bundle,
##               use_gpu_paint
##   methods:    get_terrain_world_rect() -> Rect2
##               local_height_at(Vector2) -> float
##               notify_paint_rect_changed(layer, px_rect) -> void
##
## It emits:
##
##   rebuild_requested(immediate)   the host queues a rebuild
##   resample_requested(...)        the host re-emits `paint_resample_requested`

const PaintStamper = preload("res://addons/terrainy/gen/paint/paint_stamper.gd")
const GpuPaint = preload("res://addons/terrainy/gen/build/gpu/gpu_paint.gd")
const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")

const PAINT_SAVE_DEBOUNCE_MS := 1500

signal rebuild_requested(immediate: bool)
signal resample_requested(old_size: float, new_size: float, old_grid: int, new_grid: int)

var _host = null
var _gpu_paint = null
## Brush batches the GPU paint kernel applied. Diagnostics only: [method TerrainGenerator.
## get_diagnostics] reports "paint_used" from this, because `GpuPaint.is_available()` is not use.
var gpu_stamps: int = 0
var _save_due_msec: int = 0
# Sizing change waiting for the editor's "resample?" answer.
var _sizing_pending: Dictionary = {}

func _init(host) -> void:
	_host = host

# --- Layers ---------------------------------------------------------------------------------

func layers() -> Array:
	var out: Array = []
	for child in _host.get_children():
		if child is TerrainPaintLayer:
			out.append(child)
	return out

func find(layer_name: String) -> TerrainPaintLayer:
	for layer in layers():
		if String(layer.name) == layer_name or layer.layer_uid == layer_name:
			return layer
	return null

func has_painted_layers() -> bool:
	for layer in layers():
		if layer.has_data():
			return true
	return false

func clear_layers() -> void:
	for layer in layers():
		layer.clear()

## Add a paint layer child (editor tool / scripts). Returns it.
func add_layer(kind: int, layer_name: String = "") -> TerrainPaintLayer:
	var layer := TerrainPaintLayer.new()
	layer.kind = kind
	layer.name = layer_name if not layer_name.is_empty() else "Paint%s" % TerrainPaintLayer.PaintKind.keys()[kind].capitalize().replace(" ", "")
	_host.add_child(layer, true)
	if Engine.is_editor_hint() and _host.is_inside_tree() and _host.get_tree().edited_scene_root:
		layer.owner = _host.get_tree().edited_scene_root
	return layer

# --- Strokes --------------------------------------------------------------------------------

## Apply a batch of brush stamps to [param layer] (CPU or GPU kernel) and hand the touched rect
## to the host for a local recompose. Returns the touched paint pixel rect.
func apply_stamps(layer: TerrainPaintLayer, stamps: Array) -> Rect2i:
	if layer == null or stamps.is_empty():
		return Rect2i()
	var world: Rect2 = _host.get_terrain_world_rect()
	var rect := Rect2i()
	if _host.use_gpu_paint and GpuPaint.is_available():
		if _gpu_paint == null:
			_gpu_paint = GpuPaint.new()
		rect = _gpu_paint.apply_to_layer(layer, stamps, world, _host.local_height_at)
		if rect.size.x > 0 and rect.size.y > 0:
			gpu_stamps += 1
	if rect.size == Vector2i.ZERO:
		rect = PaintStamper.apply_to_layer(layer, stamps, world, _host.local_height_at)
	if rect.size.x <= 0:
		return rect
	layer.revision += 1
	layer.patch_float_cache(rect)
	_host.notify_paint_rect_changed(layer, rect)
	return rect

# --- Resampling -----------------------------------------------------------------------------

func store_pending(old_size: float, old_grid: int) -> void:
	_sizing_pending = {"old_size": old_size, "old_grid": old_grid}

func has_pending() -> bool:
	return not _sizing_pending.is_empty()

func pending() -> Dictionary:
	return _sizing_pending

func clear_pending() -> void:
	_sizing_pending = {}

## Resample every paint layer so strokes keep their world XZ anchoring after terrain_size or
## paint_layer_grid changed. interpolation: 0 = bilinear, 1 = nearest.
func resample(old_size: float, old_grid: int, interpolation: int = 0) -> void:
	_sizing_pending = {}
	var new_grid: int = _host.paint_layer_grid
	var new_size: float = _host.terrain_size
	for layer in layers():
		var src: Image = layer.get_data()
		if src == null:
			continue
		var channels: Array = layer.get_float_channels()
		var out_channels: Array = []
		for ch in channels:
			var buf := PackedFloat32Array()
			buf.resize(new_grid * new_grid)
			out_channels.append(buf)
		var old_px := old_size / float(old_grid)
		var new_px := new_size / float(new_grid)
		# Both rects are centered on the generator.
		var old_origin := -old_size * 0.5
		var new_origin := -new_size * 0.5
		for y in new_grid:
			var wz := new_origin + (y + 0.5) * new_px
			var fy := (wz - old_origin) / old_px - 0.5
			for x in new_grid:
				var wx := new_origin + (x + 0.5) * new_px
				var fx := (wx - old_origin) / old_px - 0.5
				if fx < -0.5 or fy < -0.5 or fx > old_grid - 0.5 or fy > old_grid - 0.5:
					continue
				for c in channels.size():
					var v: float
					if interpolation == 1:
						v = channels[c][clampi(int(round(fy)), 0, old_grid - 1) * old_grid + clampi(int(round(fx)), 0, old_grid - 1)]
					else:
						v = Raster.sample_buffer(channels[c], Vector2i(old_grid, old_grid), fx, fy)
					out_channels[c][y * new_grid + x] = v
		var image: Image
		match int(layer.kind):
			TerrainPaintLayer.PaintKind.HEIGHT_DELTA:
				image = Image.create_from_data(new_grid, new_grid, false, Image.FORMAT_RF, out_channels[0].to_byte_array())
			TerrainPaintLayer.PaintKind.HEIGHT_ABSOLUTE:
				var rg := PackedFloat32Array()
				rg.resize(new_grid * new_grid * 2)
				for i in new_grid * new_grid:
					rg[i * 2] = out_channels[0][i]
					rg[i * 2 + 1] = out_channels[1][i]
				image = Image.create_from_data(new_grid, new_grid, false, Image.FORMAT_RGF, rg.to_byte_array())
			_:
				image = Image.create_from_data(new_grid, new_grid, false, Image.FORMAT_RF, out_channels[0].to_byte_array())
				image.convert(Image.FORMAT_R8)
		layer.set_data(image)
	schedule_save()
	rebuild_requested.emit(false)

# --- Persistence ----------------------------------------------------------------------------

func schedule_save() -> void:
	_save_due_msec = Time.get_ticks_msec() + PAINT_SAVE_DEBOUNCE_MS
	_host.set_process(true)

func has_pending_save() -> bool:
	return _save_due_msec > 0

## Run the debounced save if it is due. Returns true when a save ran.
func poll(now_msec: int) -> bool:
	if _save_due_msec == 0 or now_msec < _save_due_msec:
		return false
	_save_due_msec = 0
	save()
	return true

## Godot stores resources by UID in exported path fields and in `Resource.resource_path` after a
## `take_over_path()`. A `uid://` string is not a filesystem path: opening `uid://x.tmp` fails
## with ERR_FILE_CANT_OPEN, which made every scene save fail. Resolve it to the real path;
## returns "" when the UID is unknown so the caller can fall back.
static func resolved_path(value: String) -> String:
	if not value.begins_with("uid://"):
		return value
	var id := ResourceUID.text_to_id(value)
	if ResourceUID.has_id(id):
		return ResourceUID.get_id_path(id)
	return ""

## Resolve the bundle path: the explicit override, else the referenced bundle, else derived from
## the edited scene.
func resolve_bundle_path() -> String:
	var explicit := resolved_path(_host.paint_bundle_path)
	if not explicit.is_empty():
		return explicit
	var bundle: TerrainPaintBundle = _host.paint_bundle
	if bundle != null:
		var bundle_path := resolved_path(bundle.resource_path)
		if not bundle_path.is_empty():
			return bundle_path
	var scene_path: String = _host.scene_file_path
	if scene_path.is_empty() and _host.owner:
		scene_path = _host.owner.scene_file_path
	if scene_path.is_empty() and _host.is_inside_tree() and _host.get_tree().edited_scene_root:
		scene_path = _host.get_tree().edited_scene_root.scene_file_path
	if scene_path.is_empty():
		return ""
	return scene_path.get_basename() + "_terrainy.tpaint"

## Write every paint layer into the scene's bundle (merging the sections of other generators of
## the same file). Returns OK, or an error when there is nowhere to save.
func save() -> Error:
	_save_due_msec = 0
	var path := resolve_bundle_path()
	if path.is_empty():
		return ERR_UNCONFIGURED
	var paint_layers := layers()
	var bundle: TerrainPaintBundle = _host.paint_bundle
	if bundle == null:
		bundle = TerrainPaintBundle.load_from_file(path)
	if bundle == null:
		if paint_layers.is_empty():
			return OK
		bundle = TerrainPaintBundle.new()
	var section := {}
	for layer in paint_layers:
		if layer.has_data():
			section[layer.layer_uid] = TerrainPaintBundle.record_from_layer(layer)
	bundle.set_section(_host.paint_section, section)
	# Keep the bundle reachable as a resource, so the `.tscn` stores the `.tpaint` as a
	# dependency instead of a path string the exporter cannot follow.
	if bundle.resource_path != path:
		bundle.take_over_path(path)
	_host.paint_bundle = bundle
	return bundle.save_to_file(path)

## Load this generator's paint layers from the bundle. Missing data leaves layers empty.
func load() -> void:
	# Prefer the bundle the engine loaded for this scene (it is a resource dependency of the
	# `.tscn`); fall back to reading the resolved path directly.
	var bundle: TerrainPaintBundle = _host.paint_bundle
	if bundle == null:
		var path := resolve_bundle_path()
		if path.is_empty():
			return
		bundle = TerrainPaintBundle.load_from_file(path)
	if bundle == null:
		return
	var section := bundle.get_section(_host.paint_section)
	for layer in layers():
		var record: Dictionary = section.get(layer.layer_uid, {})
		if record.is_empty():
			continue
		var image := TerrainPaintBundle.image_from_record(record)
		if image != null:
			layer.revision = int(record.get("revision", layer.revision))
			var content: Rect2i = record.get("content_rect", Rect2i(-1, -1, 0, 0))
			layer.set_data(image, content, false)
