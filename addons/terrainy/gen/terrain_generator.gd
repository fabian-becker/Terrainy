@tool
@icon("res://addons/terrainy/icons/generator.svg")
class_name TerrainGenerator
extends Node3D

## Root of a Terrainy 2 terrain: owns the composition tree below it, the rebuild pipeline and
## the output (chunk meshes, collision, navigation, material, scatter).
##
## Pipeline (see docs/terrainy2-design.md §4):
##   1 plan scan -> 2 field eval -> 3 compose -> 4 Global pass -> 5 paint -> 6 control maps
##   -> 7 dirty chunks (mesh + LOD, collision, navigation, scatter)
## Stages 1 and 7 run on the main thread; stages 2-6 run as one worker task (or inline when
## use_multithreading is off). Finished chunks are applied under chunk_apply_budget_ms per
## frame, so generation never blocks the editor or the game for longer than the budget.

const TerrainGrid = preload("res://addons/terrainy/gen/eval/terrain_grid.gd")
const CompositionPlan = preload("res://addons/terrainy/gen/eval/composition_plan.gd")
const PaintStage = preload("res://addons/terrainy/gen/paint/paint_stage.gd")
const PaintController = preload("res://addons/terrainy/gen/paint/paint_controller.gd")
const ChunkManager = preload("res://addons/terrainy/gen/build/chunk_manager.gd")
const ChunkApplier = preload("res://addons/terrainy/gen/build/chunk_applier.gd")
const RebuildController = preload("res://addons/terrainy/gen/build/rebuild_controller.gd")
const MaterialBuilder = preload("res://addons/terrainy/gen/build/material_builder.gd")
const ControlMaps = preload("res://addons/terrainy/gen/build/control_maps.gd")
const Diagnostics = preload("res://addons/terrainy/gen/build/diagnostics.gd")
const BakeExporter = preload("res://addons/terrainy/gen/build/bake_exporter.gd")
const GpuCompositor = preload("res://addons/terrainy/gen/build/gpu/gpu_compositor.gd")
const GpuFieldEvaluator = preload("res://addons/terrainy/gen/build/gpu/gpu_field_evaluator.gd")
const GpuPaint = preload("res://addons/terrainy/gen/build/gpu/gpu_paint.gd")

## Fired per applied dirty region (one chunk's world AABB, generator space -> world).
signal terrain_region_updated(aabb: AABB)
signal terrain_resized
signal texture_layers_changed
signal paint_layers_changed
signal navigation_mesh_baked(navigation_mesh: NavigationMesh, chunk: Vector2i)
signal terrain_build_failed(message: String)
## Editor hook: terrain_size / paint_layer_grid changed while paint layers hold data. The
## plugin answers with resample_paint_layers() or by reverting the property. Without a
## listener the layers are resampled bilinearly right away.
signal paint_resample_requested(old_size: float, new_size: float, old_grid: int, new_grid: int)

enum CollisionQuality { EXACT, BALANCED, FAST }

const MIN_RESOLUTION := 16
const MAX_RESOLUTION := 4096
## Smallest allowed world-space cell size (meters). Only guards against zero/negative input.
const MIN_CELL_SIZE := 0.05

@export_group("Terrain")
## Meters per side (square terrain). Growing it keeps [member cell_size] (see
## [member preserve_cell_size]), so a bigger terrain gets more cells instead of coarser ones.
@export_range(1.0, 65536.0, 0.5, "or_greater", "suffix:m") var terrain_size: float = 256.0:
	set(value):
		value = maxf(value, 1.0)
		if is_equal_approx(value, terrain_size):
			return
		var old := terrain_size
		terrain_size = value
		_retune_sizing()
		_on_sizing_changed(old, paint_layer_grid)
		update_gizmos()

## Meters per grid cell. This is the quality knob: it derives [member terrain_resolution] from
## [member terrain_size], and it is what stays fixed when the terrain is resized. Detail therefore
## never depends on how big the terrain is - only the chunk count does.
@export_range(0.05, 64.0, 0.01, "or_greater", "suffix:m") var cell_size: float = 1.0:
	set(value):
		value = maxf(value, MIN_CELL_SIZE)
		if is_equal_approx(value, cell_size):
			return
		cell_size = value
		if _sizing_lock > 0:
			return
		if _retune_sizing(true):
			_request_rebuild()
			terrain_resized.emit()

## Keep [member cell_size] when [member terrain_size] changes: the cell count follows the new
## world size, so 4096 m at 1 m cells means 4096 cells (and 8x more chunks), not 16 m cells.
## Off restores the 0.x fixed-cell-count behaviour, where resizing coarsens the whole terrain.
@export var preserve_cell_size: bool = true:
	set(value):
		if value == preserve_cell_size:
			return
		preserve_cell_size = value
		if value and _retune_sizing():
			_request_rebuild()
			terrain_resized.emit()

## Cells per side; the vertex grid is terrain_resolution + 1 samples (256 cells over 256 m =
## 1 m cells). Changing it re-evaluates every configuration; paint layers keep their own grid.
## [member cell_size] is updated to `terrain_size / terrain_resolution`.
@export_range(16, 4096, 1) var terrain_resolution: int = 256:
	set(value):
		value = clampi(value, MIN_RESOLUTION, MAX_RESOLUTION)
		if value == terrain_resolution:
			return
		terrain_resolution = value
		_sync_cell_size()
		if _sizing_lock > 0:
			return
		_request_rebuild()
		terrain_resized.emit()

## Cells per chunk side (the stage-7 rebuild unit).
@export_range(8, 1024, 1) var chunk_size: int = 128:
	set(value):
		chunk_size = clampi(value, 8, 1024)
		_rebuild.layout_dirty = true
		_request_rebuild()

## Mesh cells per chunk side at LOD 0 (0 = every cell). Collision always uses every cell.
@export_range(0, 1024, 1) var chunk_resolution: int = 0:
	set(value):
		chunk_resolution = maxi(value, 0)
		_mark_all_chunks()

## Final safety clamp of the composite (generator-local meters).
@export var min_height: float = -1000.0:
	set(value):
		min_height = value
		_request_rebuild()

@export var max_height: float = 1000.0:
	set(value):
		max_height = value
		_request_rebuild()

## Starting height of the composite.
@export var base_height: float = 0.0:
	set(value):
		base_height = value
		_request_rebuild()
		update_gizmos()

## Combined into every relief source's seed: the generator owns determinism.
@export var noise_seed: int = 0:
	set(value):
		noise_seed = value
		_request_rebuild()

@export var auto_update: bool = true

## Preview only this node's subtree (everything else flat). Never saved with the scene.
@export_custom(PROPERTY_HINT_NODE_TYPE, "Node3D", PROPERTY_USAGE_EDITOR) var preview_isolate_node: Node3D:
	set(value):
		preview_isolate_node = value
		_request_rebuild()

@export_group("Pipeline")
@export var use_gpu_composition: bool = true:
	set(value):
		use_gpu_composition = value
		_request_rebuild()
@export var use_gpu_feature_evaluation: bool = true:
	set(value):
		use_gpu_feature_evaluation = value
		_request_rebuild()
## Apply brush stamps with the paint_apply compute kernel when a RenderingDevice exists.
@export var use_gpu_paint: bool = true
@export var use_multithreading: bool = true
@export_range(1, 32, 1) var max_worker_threads: int = 4
## Main-thread milliseconds per frame for applying finished chunks (0 = no budget).
@export_range(0, 100, 1) var chunk_apply_budget_ms: int = 8
@export var debug_logging: bool = false:
	set(value):
		debug_logging = value
		if _diagnostics:
			_diagnostics.set_report_enabled(value)

@export_group("LOD")
@export var enable_lod: bool = true
## Camera distances at which each further LOD level (half the mesh resolution) starts. Only used
## when [member lod_auto] is off.
@export var lod_distances: PackedFloat32Array = PackedFloat32Array([384.0, 768.0, 1536.0])
## Derive the LOD switch distances from [member cell_size], the camera FOV and the viewport instead
## of using [member lod_distances]: level n starts where one cell still covers
## [member lod_pixel_error] pixels. Keeps LOD sane at any terrain scale (fixed distances made every
## chunk of a 4 km terrain jump straight to the coarsest level).
@export var lod_auto: bool = true:
	set(value):
		lod_auto = value
		_mark_all_chunks()
## Pixel size a single cell may shrink to before the next (half-resolution) LOD level takes over.
@export_range(0.5, 8.0, 0.1, "or_greater") var lod_pixel_error: float = 1.5
## Number of derived LOD levels (each one halves the mesh resolution of the previous level).
@export_range(1, 4, 1) var lod_levels: int = 3:
	set(value):
		lod_levels = clampi(value, 1, 4)
		_mark_all_chunks()

@export_group("Collision")
## Collision is always maintained (also in exported builds). Detail of holed chunks' trimesh.
@export var collision_quality: CollisionQuality = CollisionQuality.EXACT:
	set(value):
		collision_quality = value
		_applier.collision_refresh_pending = true
@export_range(0, 2000000, 1) var collision_triangle_budget: int = 0:
	set(value):
		collision_triangle_budget = maxi(value, 0)
		_applier.collision_refresh_pending = true
@export_flags_3d_physics var collision_layer: int = 1:
	set(value):
		collision_layer = value
		_applier.apply_collision_layers()
@export_flags_3d_physics var collision_mask: int = 1:
	set(value):
		collision_mask = value
		_applier.apply_collision_layers()

@export_group("Navigation")
## Auto-rebake the per-chunk navigation regions (debounced) after terrain edits.
@export var navigation_enabled: bool = true:
	set(value):
		navigation_enabled = value
		if not value:
			_applier.clear_navigation()
		else:
			_applier.mark_all_nav_dirty()
@export var navigation_mesh_template: NavigationMesh:
	set(value):
		navigation_mesh_template = value
		_applier.mark_all_nav_dirty()
@export_range(0, 2000000, 1) var navigation_triangle_budget: int = 0
@export_range(0, 10000, 1) var navigation_debounce_ms: int = 600

@export_group("Texturing")
@export var texture_layers: Array[TerrainyTextureLayer] = []:
	set(value):
		for layer in texture_layers:
			if layer and layer.layer_changed.is_connected(_on_texture_layer_changed):
				layer.layer_changed.disconnect(_on_texture_layer_changed)
		texture_layers = value
		for layer in texture_layers:
			if layer and not layer.layer_changed.is_connected(_on_texture_layer_changed):
				layer.layer_changed.connect(_on_texture_layer_changed)
		_request_rebuild()
		texture_layers_changed.emit()
@export_range(256, 8192, 1) var texture_array_size: int = 2048:
	set(value):
		texture_array_size = value
		_material_dirty = true
## Replaces the auto material. A ShaderMaterial still receives the weight-plane uniforms.
@export var custom_material: Material:
	set(value):
		custom_material = value
		_material_dirty = true
@export var cast_shadows: GeometryInstance3D.ShadowCastingSetting = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

@export_group("Painting")
## Paint grid pixels across terrain_size (independent of terrain_resolution).
@export_range(64, 8192, 1) var paint_layer_grid: int = 1024:
	set(value):
		value = clampi(value, 64, 8192)
		if value == paint_layer_grid:
			return
		var old := paint_layer_grid
		paint_layer_grid = value
		_on_sizing_changed(terrain_size, old)
## Explicit bundle path override. Leave empty for the normal behaviour: the referenced bundle
## below, else `res://<scene>_terrainy.tpaint` next to the edited scene.
@export_file("*.tpaint") var paint_bundle_path: String = ""
## The scene's paint bundle, held as a resource reference and not only as a path. A resource
## reference in the `.tscn` is a dependency the exporter follows and the runtime can load; a
## bare path string is neither, which silently dropped all paint from exported builds.
@export var paint_bundle: TerrainPaintBundle = null
## This generator's section key inside the bundle.
@export var paint_section: String = ""

# --- Runtime state -------------------------------------------------------------------------

var _grid = null
var _plan = null
var _procedural = null
var _final = null
var _final_image: Image = null
var _holes = null
var _nav_holes = null
var _has_holes: bool = false
var _planes: Dictionary = {}
var _planes_revision: int = 0
var _unit_weights: Dictionary = {}
var _palette: Array = []
var _owned: Array = []
var _palette_capture: Array = []
var _eval_cache: Dictionary = {}
## Grid signature the evaluated field maps in [_eval_cache] belong to. Field snapshot signatures
## do not include the grid, so maps evaluated on another grid must not be reused.
var _eval_grid_signature: String = ""
## Bumped whenever paint data changes while a compose job may be in flight. Jobs carry the epoch
## they were built with; a stale result is dropped instead of overwriting a newer stroke.
var _paint_epoch: int = 0
var _compose_signature: String = ""
var _paint_signature: String = ""
var _ready_done: bool = false
var _built_once: bool = false

var _material_dirty: bool = true

var _chunks = null
var _material_builder = null
var _diagnostics = null
var _last_rebuild_report: String = ""
var _stats: Dictionary = {}
var _paint = null
var _applier = null
var _rebuild = null

func _init() -> void:
	if paint_section.is_empty():
		paint_section = "gen_%08x" % (randi() & 0x7fffffff)
	_rebuild = RebuildController.new(self)
	_rebuild.compose_reused.connect(_on_compose_reused)
	_rebuild.build_failed.connect(func(message: String) -> void: terrain_build_failed.emit(message))
	_applier = ChunkApplier.new(self)
	_applier.region_updated.connect(_on_region_updated)
	_applier.navigation_baked.connect(func(mesh: NavigationMesh, key: Vector2i) -> void:
		navigation_mesh_baked.emit(mesh, key))
	_applier.all_applied.connect(_on_chunks_applied)
	_paint = PaintController.new(self)
	_paint.rebuild_requested.connect(_request_rebuild)
	_paint.resample_requested.connect(func(old_size: float, new_size: float, old_grid: int, new_grid: int) -> void:
		paint_resample_requested.emit(old_size, new_size, old_grid, new_grid))

func _ready() -> void:
	_diagnostics = Diagnostics.new()
	_diagnostics.set_report_enabled(debug_logging)
	_material_builder = MaterialBuilder.new()
	_rebuild.diagnostics = _diagnostics
	_applier.diagnostics = _diagnostics
	_applier.pipeline.diagnostics = _diagnostics
	if _chunks == null:
		_chunks = ChunkManager.new(self)
	_ready_done = true
	TerrainyAPI.register(self)
	var tree := get_tree()
	if tree and not tree.node_added.is_connected(_on_tree_node_changed):
		tree.node_added.connect(_on_tree_node_changed)
		tree.node_removed.connect(_on_tree_node_changed)
	load_paint()
	_request_rebuild(true)
	set_process(true)

func _exit_tree() -> void:
	var tree := get_tree()
	if tree and tree.node_added.is_connected(_on_tree_node_changed):
		tree.node_added.disconnect(_on_tree_node_changed)
		tree.node_removed.disconnect(_on_tree_node_changed)
	_rebuild.wait_for_task()
	if _applier:
		_applier.pipeline.wait_for_pending()
	if _paint.has_pending_save():
		save_paint()
	TerrainyAPI.unregister(self)

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and _ready_done:
		_request_rebuild()
	elif what == NOTIFICATION_ENTER_TREE:
		set_notify_transform(true)

# --- Change notifications -------------------------------------------------------------------

## Called by composable nodes on every parameter / transform change.
func notify_node_changed(_node: Node) -> void:
	_request_rebuild()

func notify_scatter_changed(node: Node) -> void:
	if not _applier.scatter_queue.has(node.get_instance_id()):
		_applier.scatter_queue.append(node.get_instance_id())

func notify_paint_structure_changed() -> void:
	_paint_epoch += 1
	_paint_signature = ""
	_request_rebuild()
	paint_layers_changed.emit()

func _on_tree_node_changed(node: Node) -> void:
	if node == self or not is_inside_tree() or not _ready_done:
		return
	if is_ancestor_of(node) and not _is_internal(node):
		if node is TerrainScatterNode:
			_applier.scatter_dirty_all = true
		_request_rebuild()

func _is_internal(node: Node) -> bool:
	return _chunks != null and (node == _chunks.get_root() or _chunks.get_root().is_ancestor_of(node))

func _on_texture_layer_changed() -> void:
	_material_dirty = true
	_request_rebuild()

func _request_rebuild(immediate: bool = false) -> void:
	if not _ready_done:
		return
	if not auto_update and _built_once and not immediate:
		return
	_rebuild.request(immediate)

func _mark_all_chunks() -> void:
	if _chunks:
		_chunks.mark_all_dirty()
	_request_rebuild()

# --- Sizing ---------------------------------------------------------------------------------

var _suppress_resample: bool = false

## Guards the three sizing properties (size / cell_size / resolution) against re-entrant derivation.
var _sizing_lock: int = 0
## Suppresses the repeated resolution-clamp warning while the requested cell size stays impossible.
var _resolution_clamp_warned: bool = false

## Re-derive the cell count for the current world size and keep [member cell_size] exact.
## Returns true when the resolution changed. Never emits or requests a rebuild: callers do that, so a
## resize reports once instead of once per derived property. [param force] derives the resolution even
## when [member preserve_cell_size] is off (a direct [member cell_size] edit is always explicit).
func _retune_sizing(force: bool = false) -> bool:
	var wanted := terrain_resolution
	if preserve_cell_size or force:
		var requested := roundi(terrain_size / maxf(cell_size, MIN_CELL_SIZE))
		wanted = clampi(requested, MIN_RESOLUTION, MAX_RESOLUTION)
		if requested > MAX_RESOLUTION and not _resolution_clamp_warned:
			_resolution_clamp_warned = true
			push_warning("[Terrainy] terrain_resolution clamped to %d cells: %.3f m per cell requested, %.3f m used (MAX_RESOLUTION is %d)" % [wanted, cell_size, terrain_size / float(wanted), MAX_RESOLUTION])
		elif requested <= MAX_RESOLUTION:
			_resolution_clamp_warned = false
	var changed := wanted != terrain_resolution
	_sizing_lock += 1
	terrain_resolution = wanted
	cell_size = terrain_size / float(terrain_resolution)
	_sizing_lock -= 1
	return changed

## Pull [member cell_size] from the current size/resolution pair without re-deriving the resolution.
func _sync_cell_size() -> void:
	_sizing_lock += 1
	cell_size = terrain_size / float(terrain_resolution)
	_sizing_lock -= 1

func _on_sizing_changed(old_size: float, old_grid: int) -> void:
	if not _ready_done or _suppress_resample:
		return
	if _paint.has_painted_layers():
		if paint_resample_requested.get_connections().is_empty():
			_paint.resample(old_size, old_grid, 0)
		else:
			_paint.store_pending(old_size, old_grid)
			paint_resample_requested.emit(old_size, terrain_size, old_grid, paint_layer_grid)
	elif old_grid != paint_layer_grid:
		_paint.clear_layers()
	_request_rebuild()
	terrain_resized.emit()

## Resample every paint layer so strokes keep their world XZ anchoring after terrain_size or
## paint_layer_grid changed. interpolation: 0 = bilinear, 1 = nearest.
func resample_paint_layers(old_size: float, old_grid: int, interpolation: int = 0) -> void:
	_paint.resample(old_size, old_grid, interpolation)

## Confirm the resample the editor asked about, using the sizing captured when it was prompted.
func resample_pending_paint_layers(interpolation: int = 0) -> void:
	var pending: Dictionary = _paint.pending()
	if pending.is_empty():
		return
	_paint.resample(pending["old_size"], pending["old_grid"], interpolation)

## Abandon a pending resample prompt by restoring the previous sizing (editor "Cancel").
func cancel_paint_resample() -> void:
	var pending: Dictionary = _paint.pending()
	if pending.is_empty():
		return
	_paint.clear_pending()
	# The paint data still matches the previous sizing: restore it without another prompt.
	_suppress_resample = true
	terrain_size = pending["old_size"]
	paint_layer_grid = pending["old_grid"]
	_suppress_resample = false
	_request_rebuild()
	terrain_resized.emit()

# --- Lifecycle and rebuild ------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _ready_done:
		return
	var now := Time.get_ticks_msec()
	_rebuild.process(now)
	_applier.process(now)
	_paint.poll(now)

## True while any stage of a rebuild is queued, running or being applied.
func is_rebuilding() -> bool:
	return _rebuild.is_rebuilding() or _applier.is_busy()

func is_rebuilding_meshes() -> bool:
	return _rebuild.task_id >= 0 or not _rebuild.job.is_empty() or _applier.has_mesh_work()

## True while navigation regions are waiting for (or running) a bake.
func is_baking_navigation() -> bool:
	return _applier.is_baking_navigation()

## Rebuild synchronously (bakes, tests, tools): composes on the calling thread and applies
## every chunk before returning.
func rebuild_now() -> void:
	if not _ready_done:
		return
	_rebuild.rebuild_now()
	_applier.drain()
	if _applier.collision_refresh_pending:
		_applier.collision_refresh_pending = false
		_applier.refresh_all_collision()
		_applier.drain()
	_applier.process_scatter_queue(true)

## Force a full recomposition (clears every cache).
func force_rebuild() -> void:
	# Replace, do not clear: an in-flight worker may still be reading the old dictionary as its
	# previous-evaluation cache. Bump the paint epoch so that stale compose results are dropped.
	_eval_cache = {}
	_eval_grid_signature = ""
	_paint_epoch += 1
	_compose_signature = ""
	_paint_signature = ""
	_rebuild.layout_dirty = true
	_material_dirty = true
	_applier.scatter_dirty_all = true
	_request_rebuild(true)

# --- Geometry -------------------------------------------------------------------------------

func get_grid():
	if _grid == null or not _grid_matches():
		_grid = TerrainGrid.new(terrain_resolution, terrain_size, _center_xz())
	return _grid

func _center_xz() -> Vector2:
	var p := global_position if is_inside_tree() else position
	return Vector2(p.x, p.z)

func _grid_matches() -> bool:
	return _grid.resolution == terrain_resolution and is_equal_approx(_grid.size, terrain_size) \
		and _grid.origin.is_equal_approx(_center_xz() - Vector2(terrain_size, terrain_size) * 0.5)

## World XZ rect of the terrain.
func get_terrain_world_rect() -> Rect2:
	var c := _center_xz()
	return Rect2(c - Vector2(terrain_size, terrain_size) * 0.5, Vector2(terrain_size, terrain_size))

## Context the plan scan and paint snapshots see. The rebuild passes the palette it is about to
## install (PlanBuilder appends contribution-owned indices to [param owned_layers] by reference);
## the paint path passes nothing and gets the current one.
func composition_context(grid, palette = null, owned_layers = null) -> Dictionary:
	var context := {
		"grid": grid,
		"generator": self,
		"generator_xform": global_transform if is_inside_tree() else transform,
		"noise_seed": noise_seed,
		"palette": palette if palette != null else _palette,
		"owned_layers": owned_layers if owned_layers != null else _owned,
		"isolate": preview_isolate_node,
	}
	# Paint goes over as nodes-to-skip plus ready snapshots: the plan scan must not have to know
	# the paint layer type, and paint is the generator's business.
	var paint_nodes := get_paint_layers()
	var snapshots: Array = []
	for layer in paint_nodes:
		if layer.enabled:
			snapshots.append(layer.make_snapshot(context))
	context["paint_nodes"] = paint_nodes
	context["paint_snapshots"] = snapshots
	return context

# --- RebuildController collaboration ----------------------------------------------------------

func get_eval_cache() -> Dictionary:
	return _eval_cache

func get_eval_grid_signature() -> String:
	return _eval_grid_signature

func get_paint_epoch() -> int:
	return _paint_epoch

func get_unit_weights() -> Dictionary:
	return _unit_weights

func get_compose_signature() -> String:
	return _compose_signature

func get_paint_signature() -> String:
	return _paint_signature

## Called by RebuildController after the plan scan. Palette and owned indices are recomputed
## every rebuild; the plan scan appends contribution-owned indices into [param owned] by
## reference, so this must be the same array capture_palette() then used.
func set_palette(palette: Array, owned: Array, capture: Array) -> void:
	_palette = palette
	_owned = owned
	_palette_capture = capture

## Called by RebuildController when the compose signature is unchanged: commit the new plan and
## refresh the material without composing.
func _on_compose_reused(plan) -> void:
	_plan = plan
	_finish_without_compose()

## Commit a finished compose job into the node's composition state, then hand stage 7 the list
## of chunks that changed.
func apply_composition(job: Dictionary) -> void:
	var result: Dictionary = job["result"]
	var timings: Dictionary = result["timings"]
	for key in timings:
		_diagnostics.record(key, timings[key])
	_diagnostics.count("fields_evaluated", job.get("evaluated", 0))
	_diagnostics.count("fields_reused", job.get("reused", 0))
	if int(job.get("paint_epoch", _paint_epoch)) != _paint_epoch:
		# Paint changed after this job was built (stroke, undo or layer edit). Applying its
		# pre-change composite would clobber the local repaint, so drop it and compose again.
		_paint_signature = ""
		_request_rebuild()
		return
	var grid = job["grid"]
	var old_image := _final_image
	_grid = grid
	_plan = job["plan"]
	_procedural = result["procedural"]
	_final = result["final"]
	_final_image = _final.to_image()
	_holes = result["holes"]
	_nav_holes = result["nav_holes"]
	_unit_weights = result["unit_weights"]
	_eval_cache = result["cache"]
	_eval_grid_signature = var_to_str(grid.signature())
	_planes = result["planes"]
	_planes_revision += 1
	_planes["revision"] = _planes_revision
	_compose_signature = job["compose_sig"]
	_paint_signature = job["paint_sig"]
	_stats = {
		"units": _plan.unit_count, "post_units": _plan.post.size(), "holes": _plan.holes.size(),
		"paint_layers": _plan.paint_layers.size(), "evaluated": job.get("evaluated", 0),
		"reused": job.get("reused", 0), "timings": timings, "gpu_fields": job["injected"].size(),
	}
	# Stage 7: decide which chunks changed.
	var layout_changed: bool = _chunks.update_grid(grid, chunk_size) or _rebuild.layout_dirty
	_rebuild.layout_dirty = false
	var dirty: Array = []
	if layout_changed or old_image == null or old_image.get_size() != _final_image.get_size():
		# Seed the hashes so the next compose can compare against this result.
		for chunk in _chunks.chunks.values():
			_update_chunk_hashes(chunk)
		_chunks.mark_all_dirty()
		dirty = _chunks.chunks.values()
		_applier.scatter_dirty_all = true
	else:
		for chunk in _chunks.chunks.values():
			# One region hash per chunk instead of copying two image regions per chunk.
			var image_hash: int = _chunk_image_hash(chunk)
			var holes_hash: int = _chunk_holes_hash(chunk)
			if chunk.is_dirty or not chunk.hashes_valid \
					or image_hash != chunk.image_hash or holes_hash != chunk.holes_hash:
				_chunks.mark_dirty(chunk)
				dirty.append(chunk)
			chunk.image_hash = image_hash
			chunk.holes_hash = holes_hash
			chunk.hashes_valid = true
	_material_dirty = true
	_built_once = true
	_applier.dispatch(dirty, _rebuild.rebuild_id)

func _chunk_image_hash(chunk) -> int:
	return hash(_final.extract(chunk.sample_rect).data)

func _chunk_holes_hash(chunk) -> int:
	return hash(_holes.extract(chunk.sample_rect).data) if _holes != null else 0

func _update_chunk_hashes(chunk) -> void:
	chunk.image_hash = _chunk_image_hash(chunk)
	chunk.holes_hash = _chunk_holes_hash(chunk)
	chunk.hashes_valid = true

func _finish_without_compose() -> void:
	_material_dirty = true
	# Settings such as chunk_resolution dirty chunks without changing the composition. Forward
	# them to stage 7; an empty dispatch also closes the rebuild (all_applied) and refreshes the
	# material, so this path must not end the rebuild itself.
	var dirty: Array = []
	if _chunks != null:
		for chunk in _chunks.chunks.values():
			if chunk.is_dirty:
				dirty.append(chunk)
	_applier.dispatch(dirty, _rebuild.rebuild_id)


# --- Chunk results (material / bounds; the stage-7 work lives in ChunkApplier) ----------------

## Stage-7 application emits one AABB per applied chunk; surface it on the node's signal and the
## public API with this generator as the emitter.
func _on_region_updated(aabb: AABB) -> void:
	terrain_region_updated.emit(aabb)
	TerrainyAPI.signals.region_changed.emit(self, aabb)

var _min_max_cache: Vector2 = Vector2.ZERO
var _min_max_revision: int = -1

func final_min() -> float:
	_refresh_min_max()
	return _min_max_cache.x

func final_max() -> float:
	_refresh_min_max()
	return _min_max_cache.y

func _refresh_min_max() -> void:
	if _min_max_revision == _rebuild.rebuild_id or _final == null:
		return
	_min_max_revision = _rebuild.rebuild_id
	_min_max_cache = _final.min_max()

func _on_chunks_applied() -> void:
	_update_material()
	if _diagnostics:
		_last_rebuild_report = _diagnostics.end_rebuild()

func current_material() -> Material:
	return custom_material if custom_material else _material_builder.get_material()

func _update_material() -> void:
	if _chunks == null or _material_builder == null:
		return
	_material_builder.texture_array_size = texture_array_size
	var material: Material = _material_builder.update(_palette, _owned, custom_material, _planes, get_terrain_world_rect())
	for chunk in _chunks.chunks.values():
		if chunk.mesh_instance and chunk.mesh_instance.material_override != material:
			chunk.mesh_instance.material_override = material
	_material_dirty = false

# --- Navigation / scatter (public surface; the work lives in ChunkApplier) -------------------

## Re-bake every chunk's navigation region now (manual schedule). [param synchronous] blocks.
func bake_navigation(synchronous: bool = false) -> void:
	_applier.bake_navigation(synchronous)

## Navigation meshes of every chunk that has one (chunk key -> NavigationMesh).
func get_navigation_meshes() -> Dictionary:
	return _applier.navigation_meshes()

func get_scatter_nodes() -> Array:
	return _applier.scatter_nodes()

## Camera the LOD levels are chosen from (editor 3D viewport or the game viewport).
func find_camera() -> Camera3D:
	if Engine.is_editor_hint():
		if Engine.has_singleton("EditorInterface"):
			var ei = Engine.get_singleton("EditorInterface")
			var vp = ei.get_editor_viewport_3d(0)
			return vp.get_camera_3d() if vp else null
		return null
	var viewport := get_viewport()
	return viewport.get_camera_3d() if viewport else null

# --- Paint ----------------------------------------------------------------------------------

func get_paint_layers() -> Array:
	return _paint.layers()

func find_paint_layer(layer_name: String) -> TerrainPaintLayer:
	return _paint.find(layer_name)

## Add a paint layer child (editor tool / scripts). Returns it.
func add_paint_layer(kind: int, layer_name: String = "") -> TerrainPaintLayer:
	return _paint.add_layer(kind, layer_name)

## Generator-local composed height at a world XZ (used by height brush ops).
## Min/max composed terrain height (generator-local) over a world XZ rect. Exact for the built
## grid; returns a zero vector before the first composition or outside the terrain.
func height_range_in_rect(world_rect: Rect2) -> Vector2:
	if _final == null or _grid == null:
		return Vector2.ZERO
	var r: Rect2i = _grid.rect_for_world(world_rect, 1).intersection(_final.rect)
	if r.size.x <= 0 or r.size.y <= 0:
		return Vector2.ZERO
	return _final.extract(r).min_max()

func local_height_at(world_xz: Vector2) -> float:
	if _final == null:
		return base_height
	var g: Vector2 = get_grid().sample_of(world_xz)
	return _final.sample_bilinear(g.x, g.y)

## Apply a batch of brush stamps to [param layer] (CPU or GPU kernel) and update the terrain
## locally. Returns the touched paint pixel rect.
func paint_stamps(layer: TerrainPaintLayer, stamps: Array) -> Rect2i:
	return _paint.apply_stamps(layer, stamps)

## Recompose the terrain under a changed paint pixel rect (strokes, undo).
func notify_paint_rect_changed(layer: TerrainPaintLayer, px_rect: Rect2i) -> void:
	_paint_epoch += 1
	if _final == null or _procedural == null:
		_request_rebuild()
		return
	var world := get_terrain_world_rect()
	var world_rect := PaintStage.paint_rect_to_world(px_rect, layer.grid_size(), world)
	var grid = get_grid()
	var ctx := composition_context(grid)
	var layers: Array = []
	for l in get_paint_layers():
		if l.enabled:
			layers.append(l.make_snapshot(ctx, false))
	match int(layer.kind):
		TerrainPaintLayer.PaintKind.TEXTURE:
			_update_planes_region(world_rect, layers)
		TerrainPaintLayer.PaintKind.MASK:
			# Painted masks can gate fields/modifiers anywhere: recompose.
			_compose_signature = ""
			_request_rebuild(true)
		_:
			var grid_rect: Rect2i = grid.rect_for_world(world_rect, 2)
			if grid_rect.size.x > 0:
				_repaint_region(grid_rect, layers)
	_paint_signature = ""  # next full rebuild re-runs the paint stage
	_paint.schedule_save()
	paint_layers_changed.emit()

func _repaint_region(grid_rect: Rect2i, layers: Array) -> void:
	var world := get_terrain_world_rect()
	var region = PaintStage.apply_region(_procedural, _grid, layers, grid_rect, world)
	_final.paste(region)
	_final_image.blit_rect(region.to_image(), Rect2i(Vector2i.ZERO, region.rect.size), region.rect.position)
	if _plan != null and not _plan.holes.is_empty():
		var gen_y := global_position.y
		var sub_final = _final
		var holes = RebuildController.compute_holes(_plan.holes, sub_final, _grid, gen_y, false)
		_holes = holes
		_nav_holes = RebuildController.compute_holes(_plan.holes, sub_final, _grid, gen_y, true)
	_min_max_revision = -1
	var dirty: Array = _chunks.mark_dirty_for_samples(grid_rect)
	_applier.dispatch(dirty, _rebuild.rebuild_id)

func _update_planes_region(world_rect: Rect2, layers: Array) -> void:
	var size := ControlMaps.plane_size_for(_grid, layers, _palette_capture.size(), paint_layer_grid)
	var current: int = _planes.get("size", -1)
	var units: Array = _planes.get("units", [])
	if size != current or (_planes.get("claims", []) as Array).size() != _palette_capture.size():
		_planes = ControlMaps.build(_grid, get_terrain_world_rect(), _final, units, _unit_weights, layers, _palette_capture, paint_layer_grid)
		_planes["units"] = units
		_planes_revision += 1
		_planes["revision"] = _planes_revision
		_update_material()
		return
	var world := get_terrain_world_rect()
	var px := world.size.x / float(size)
	var region := Rect2i(Vector2i(((world_rect.position - world.position) / px).floor()) - Vector2i.ONE,
		Vector2i((world_rect.size / px).ceil()) + Vector2i(3, 3))
	var part := ControlMaps.build(_grid, world, _final, units, _unit_weights, layers, _palette_capture, paint_layer_grid, size, region)
	var area: Rect2i = part["region"]
	var slices := PackedInt32Array()
	var claims: Array = _planes["claims"]
	for i in claims.size():
		var img: Image = claims[i]
		img.blit_rect(part["claims"][i], Rect2i(Vector2i.ZERO, area.size), area.position)
		slices.append(i)
	_planes["has_claims"] = _planes.get("has_claims", false) or part["has_claims"]
	_material_builder.update_plane_slices(_planes, slices)
	_material_builder.update(_palette, _owned, custom_material, _planes, world)

## Resolve the bundle path: the explicit override, else the referenced bundle, else derived from
## the edited scene.
func resolve_paint_bundle_path() -> String:
	return _paint.resolve_bundle_path()

## Schedule the debounced bundle save. For editor tools that mutate a layer's data directly
## (e.g. an undo/redo action) instead of going through paint_stamps().
func schedule_paint_save() -> void:
	_paint.schedule_save()

## Write every paint layer of this generator into the scene's bundle (merging the sections of
## other generators of the same file). Returns OK, or an error when there is nowhere to save.
func save_paint() -> Error:
	return _paint.save()

## Load this generator's paint layers from the bundle. Missing data leaves layers empty.
func load_paint() -> void:
	_paint.load()

# --- Queries (TerrainyAPI) ------------------------------------------------------------------

func has_terrain() -> bool:
	return _final != null

## World height at a world XZ (bilinear). Outside the terrain: generator y + base_height.
func get_height_at(world_pos: Vector3) -> float:
	var gy := global_position.y
	if _final == null:
		return gy + base_height
	var w := get_terrain_world_rect()
	if world_pos.x < w.position.x or world_pos.z < w.position.y or world_pos.x > w.end.x or world_pos.z > w.end.y:
		return gy + base_height
	var g: Vector2 = get_grid().sample_of(Vector2(world_pos.x, world_pos.z))
	return gy + _final.sample_bilinear(g.x, g.y)

## World-space surface normal: central differences of [method get_height_at] with step
## [param eps] meters. Lives here, not only on the facade, so the generator's own queries do not
## have to reach out through the public API and back in.
func get_normal_at(world_pos: Vector3, eps: float = 1.0) -> Vector3:
	eps = maxf(eps, 0.001)
	var hl := get_height_at(world_pos - Vector3(eps, 0, 0))
	var hr := get_height_at(world_pos + Vector3(eps, 0, 0))
	var hd := get_height_at(world_pos - Vector3(0, 0, eps))
	var hu := get_height_at(world_pos + Vector3(0, 0, eps))
	return Vector3((hl - hr) / (2.0 * eps), 1.0, (hd - hu) / (2.0 * eps)).normalized()

func get_hole_at(world_pos: Vector3) -> bool:
	if _holes == null:
		return false
	var g: Vector2 = get_grid().sample_of(Vector2(world_pos.x, world_pos.z))
	if g.x < 0 or g.y < 0 or g.x > _grid.samples - 1 or g.y > _grid.samples - 1:
		return false
	return _holes.sample_bilinear(g.x, g.y) >= 0.5

func get_texture_blend_at(world_pos: Vector3) -> Dictionary:
	var out := {}
	if _palette_capture.is_empty():
		return out
	var h := get_height_at(world_pos)
	var n := get_normal_at(world_pos)
	var slope := acos(clampf(n.y, 0.0, 1.0))
	var claims := PackedFloat32Array()
	var add := PackedFloat32Array()
	var sup := PackedFloat32Array()
	var world := get_terrain_world_rect()
	var size: int = _planes.get("size", 0)
	var uv := Vector2((world_pos.x - world.position.x) / world.size.x, (world_pos.z - world.position.y) / world.size.y)
	if _planes.get("has_claims", false) and size > 0:
		for img in _planes["claims"]:
			claims.append(_sample_plane(img, uv, 0))
	if _planes.get("has_modulation", false):
		for img in _planes["modulation"]:
			add.append(_sample_plane(img, uv, 0))
			sup.append(_sample_plane(img, uv, 1))
	var w := MaterialBuilder.blend_weights(_palette_capture, h, slope, claims, add, sup)
	for i in w.size():
		out[i] = w[i]
	return out

static func _sample_plane(img: Image, uv: Vector2, channel: int) -> float:
	var s := img.get_size()
	var px := Vector2i(clampi(int(uv.x * s.x), 0, s.x - 1), clampi(int(uv.y * s.y), 0, s.y - 1))
	var c := img.get_pixelv(px)
	return c.r if channel == 0 else c.g

func get_fields_at(world_pos: Vector3) -> Array[TerrainFieldNode]:
	var out: Array[TerrainFieldNode] = []
	if _plan == null:
		return out
	for unit in _plan.all_units():
		if unit.kind != CompositionPlan.UnitKind.FIELD:
			continue
		var weight: float = unit.snap.weight_at(world_pos.x, world_pos.z)
		if weight > 0.0 and unit.mask != null:
			weight *= unit.mask.value_at(world_pos.x, world_pos.z, get_height_at(world_pos) - global_position.y, 0.0)
		if weight > 0.0:
			var node := instance_from_id(unit.node_id) as TerrainFieldNode
			if node:
				out.append(node)
	return out

## Composite map access for tools (generator-local heights, full grid).
func get_final_map():
	return _final

func get_procedural_map():
	return _procedural

func get_hole_map():
	return _holes

## Navigation-only hole mask (holes that also cut navigation; see compute_holes).
func get_navigation_hole_map():
	return _nav_holes

## The composed heightmap as an Image (chunk jobs slice this per chunk).
func get_final_image() -> Image:
	return _final_image

## Monotonic id of the rebuild in flight; chunk results are validated against it.
func get_rebuild_id() -> int:
	return _rebuild.rebuild_id

func get_weight_planes() -> Dictionary:
	return _planes

func get_palette() -> Array:
	return _palette

func get_chunk_manager():
	return _chunks

func get_diagnostics() -> Dictionary:
	var chunks: int = _chunks.chunks.size() if _chunks else 0
	return {
		"rebuild_id": _rebuild.rebuild_id,
		"rebuilding": is_rebuilding(),
		"last_report": _last_rebuild_report,
		"grid": {"resolution": terrain_resolution, "size": terrain_size, "samples": terrain_resolution + 1},
		"chunks": chunks,
		"dirty_chunks": _chunks.dirty_chunks().size() if _chunks else 0,
		"gpu": {"rendering_device": RenderingServer.get_rendering_device() != null,
			"composition": use_gpu_composition and GpuCompositor.is_available(),
			"field_evaluation": use_gpu_feature_evaluation and GpuFieldEvaluator.is_available(),
			"paint": use_gpu_paint and GpuPaint.is_available()},
		"stats": _stats,
		"phases": _diagnostics._phases.duplicate() if _diagnostics else {},
		"counters": _diagnostics._counters.duplicate() if _diagnostics else {},
		"navigation_in_flight": _applier.nav_in_flight,
	}

# --- Bake -----------------------------------------------------------------------------------

## Bake chunks (static meshes + collision + navigation) and scatter into a PackedScene file.
func bake_to_scene(output_path: String) -> Error:
	if _chunks == null or _chunks.chunks.is_empty() or _final == null:
		push_warning("[TerrainGenerator] Nothing to bake yet")
		return ERR_UNAVAILABLE
	var scene: PackedScene = BakeExporter.export_terrain(self, _chunks.chunks.values(), current_material())
	if scene == null:
		return FAILED
	return ResourceSaver.save(scene, output_path)
