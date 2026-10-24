@tool
extends RefCounted

## Distance-based LOD policy and the skirt edge mask (track B, design D5.1-D5.5).
##
## The controller owns every decision about *which resolution a chunk should have*, and nothing
## else: it does not build meshes, does not dispatch, and never touches a neighbour's geometry.
## [ChunkApplier] calls [method update] once per frame; the chunks whose target level changed are
## returned and enqueued in the [ChunkScheduler], never dispatched directly (design D7.3), so a
## camera flying across ten chunks spreads its LOD churn over ten frames.
##
## Three rules that are easy to get wrong, and are the reason this is a class instead of 20 lines in
## the applier:
##
## **1. Hysteresis.** A chunk only coarsens once the camera is `lod_hysteresis` *past* the switch
## distance and only refines once it is `lod_hysteresis` *closer* than it. Without the margin, a
## camera hovering on a boundary rebuilds the same chunk every frame - a visible stutter and pure
## wasted worker time (design D5.3, hazard H4).
##
## **2. Distance is measured to the chunk rectangle**, not to its centre. A 128 m chunk whose centre
## is 300 m away has a corner 240 m away, and popping it a level early on the centre distance is
## exactly the "the ground under my feet changed resolution" artefact.
##
## **3. Seams are sealed by skirts, and the mask says where.** Two neighbours at different LOD
## levels sample their shared edge at different resolutions, so their triangle strips no longer meet
## and a hairline crack opens. The chunk that owns an edge emits a wall down from it
## ([SeamBuilder]), and [method edges_for] is the bitmask that says which of its four edges need
## one. Stitching was rejected on purpose: it would make a chunk's mesh depend on a neighbour's LOD,
## which is exactly the coupling that makes parallel generation unsafe (design D5.4).

## Edge bits of the skirt mask (design D5.4).
enum Edge { NORTH = 1, EAST = 2, SOUTH = 4, WEST = 8 }

const ChunkScheduler = preload("res://addons/terrainy/gen/build/chunk_scheduler.gd")

## Skip re-evaluation while the camera moved less than this (metres) *and* no refresh interval has
## passed. Standing still must not re-evaluate 256 chunks every frame; the interval catches changes
## the camera position cannot see (window resize changes the derived distances).
const CAMERA_MOVE_MIN_M := 16.0
## ... but never go longer than this without re-evaluating.
const REFRESH_INTERVAL_MS := 250

var host = null

## Cached switch distances from the last [method update], so [method level_for] can answer without
## a camera.
var _distances: PackedFloat32Array = PackedFloat32Array()
var _cell: float = 1.0
var _camera_pos: Vector3 = Vector3.INF
var _last_eval_ms: int = -1000000

var _changes: int = 0
var _flips: int = 0
## last direction of a level change per chunk key (+1 coarsened, -1 refined), for the flip counter.
var _last_dir: Dictionary = {}

func _init(p_host = null) -> void:
	host = p_host

## Forget the camera position so the next [method update] re-evaluates every chunk.
func invalidate() -> void:
	_camera_pos = Vector3.INF
	_last_eval_ms = -1000000

# --- Per-frame step ----------------------------------------------------------------------------

## Re-evaluate every chunk's LOD target and queue the ones that changed.
##
## Returns the chunks whose target level (or skirt mask) changed; the caller bumps their revision
## and marks them dirty - a revision bump is what makes an already in-flight build for the old level
## stale and dropped at commit (design D5.5).
func update(camera: Camera3D, chunks: Dictionary, budget) -> Array:
	var changed: Array = []
	if host == null or chunks.is_empty() or camera == null or not camera.is_inside_tree():
		return changed
	if not _camera_moved_enough(camera, chunks):
		return changed

	var cam_xz := Vector2(camera.global_position.x, camera.global_position.z)
	_distances = distances_for(camera, host.get_grid())
	var margin := clampf(float(host.lod_hysteresis), 0.0, 0.45)
	var use_lod: bool = bool(host.enable_lod) and not _distances.is_empty()

	# Pass 1 - target level per chunk. Levels are resolved for *every* chunk before any mask is
	# computed, so a mask sees its neighbours' final level rather than half of this frame's work.
	var seen: Dictionary = {}
	for chunk in chunks.values():
		var d := distance_to_bounds(chunk.world_bounds, cam_xz)
		var want: int = level_with_hysteresis(d, chunk.lod_level, _distances, margin) if use_lod else 0
		if want == chunk.lod_level:
			continue
		var coarsening: bool = want > int(chunk.lod_level)
		var direction := 1 if coarsening else -1
		chunk.lod_level = want
		_changes += 1
		if int(_last_dir.get(chunk.key, 0)) == -direction:
			# The camera crossed back over the same boundary it just crossed: that is a flip, and a
			# flip is a wasted rebuild (design H4, the thing hysteresis exists to prevent).
			_flips += 1
		_last_dir[chunk.key] = direction
		if not chunk.streamed_in:
			# Outside the view distance: correct level, no work. It is queued when it streams back
			# in, at which point it builds straight at this level.
			continue
		if budget != null:
			budget.enqueue(chunk, ChunkScheduler.Priority.LOD_COARSEN if coarsening
				else ChunkScheduler.Priority.LOD_REFINE)
		seen[chunk.key] = true
		changed.append(chunk)

	# Pass 2 - skirt masks. A crack belongs to the *edge*, so when a neighbour changes level the
	# chunk on the other side of that edge also has to rebuild: its mask moved even though its own
	# level did not. Without this pass the finer chunk keeps its old (skirtless) mesh and the crack
	# opens on its side until something else dirties it.
	for chunk in chunks.values():
		if not chunk.streamed_in or seen.has(chunk.key):
			continue
		var mask := edges_for(chunk.key, chunks)
		if mask == int(chunk.skirt_edges):
			continue
		chunk.skirt_edges = mask
		if budget != null:
			budget.enqueue(chunk, ChunkScheduler.Priority.NEAR)
		changed.append(chunk)
	return changed

func _camera_moved_enough(camera: Camera3D, chunks: Dictionary) -> bool:
	var pos := camera.global_position
	var now := Time.get_ticks_msec()
	# The 16 m floor keeps a walking camera from re-evaluating every frame; the cell term keeps the
	# guard sane on 4 km terrains where 16 m is noise (design D5.3).
	var cell := _cell
	if host != null and host.get_grid() != null:
		cell = float(host.get_grid().cell)
	_cell = cell
	var move_min := maxf(CAMERA_MOVE_MIN_M, 2.0 * cell)
	if _camera_pos != Vector3.INF and pos.distance_to(_camera_pos) < move_min \
			and now - _last_eval_ms < REFRESH_INTERVAL_MS:
		return false
	_camera_pos = pos
	_last_eval_ms = now
	return not chunks.is_empty()

# --- Level selection ---------------------------------------------------------------------------

## LOD switch distances in metres, one per further level. With `lod_auto` they are derived from the
## world-space cell size and the camera projection: level n starts where one cell still covers
## `lod_pixel_error` pixels of the viewport. That formula is scale invariant, which the fixed metre
## distances of 0.x were not (design D5.2).
func distances_for(camera: Camera3D, grid) -> PackedFloat32Array:
	if host == null:
		return PackedFloat32Array()
	if not bool(host.lod_auto) or camera == null or grid == null:
		return host.lod_distances
	var view_height := 0.0
	var viewport := camera.get_viewport()
	if viewport != null:
		view_height = viewport.get_visible_rect().size.y
	if view_height < 1.0:
		# Headless / not-yet-sized viewport: the project's window height is the sane stand-in.
		view_height = maxf(float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080)), 1.0)
	var tan_half_fov := tan(deg_to_rad(clampf(camera.fov, 1.0, 179.0)) * 0.5)
	# A cell covers `cell * view_height / (2 * distance * tan(fov/2))` pixels: solve for distance.
	var cell: float = grid.cell
	var level_zero: float = cell * view_height / (2.0 * tan_half_fov * maxf(float(host.lod_pixel_error), 0.1))
	var out := PackedFloat32Array()
	for i in maxi(int(host.lod_levels), 1):
		out.append(level_zero * float(1 << i))
	_cell = cell
	return out

## Target level for a chunk with [param bounds] seen from [param camera_pos], without hysteresis.
## Used where "what level does this distance mean" is the question (diagnostics, tests, masks).
func level_for(bounds: Rect2, camera_pos: Vector3) -> int:
	var d := distance_to_bounds(bounds, Vector2(camera_pos.x, camera_pos.z))
	return level_with_hysteresis(d, 0, _distances, 0.0)

## Level for [param distance] metres away whose current level is [param current].
##
## Without hysteresis this is "the number of thresholds the distance has passed". Hysteresis widens
## each threshold into a band: refining needs to get `hysteresis` closer than the boundary,
## coarsening needs to get `hysteresis` farther (design D5.3). Both loops run until stable, so a
## camera that teleported across three levels lands on the right one in a single pass.
static func level_with_hysteresis(distance: float, current: int, distances: PackedFloat32Array,
		hysteresis: float) -> int:
	if distances.is_empty():
		return 0
	var lod: int = clampi(current, 0, distances.size())
	var margin: float = clampf(hysteresis, 0.0, 0.45)
	while lod > 0 and distance < distances[lod - 1] * (1.0 - margin):
		lod -= 1
	while lod < distances.size() and distance >= distances[lod] * (1.0 + margin):
		lod += 1
	return lod

## Distance from [param point] (XZ) to the nearest point of a chunk rectangle.
## A camera *above* a chunk is distance 0 away from it, not its height above the ground: LOD is
## about screen-space size, and a chunk directly below a flying camera is as close as it gets.
static func distance_to_bounds(bounds: Rect2, point: Vector2) -> float:
	var nearest := Vector2(
		clampf(point.x, bounds.position.x, bounds.end.x),
		clampf(point.y, bounds.position.y, bounds.end.y))
	return point.distance_to(nearest)

# --- Seams -------------------------------------------------------------------------------------

## Bitmask of the edges of chunk [param key] whose neighbour is at a *different* mesh step, i.e. the
## edges that need a skirt (design D5.4). Missing and streamed-out neighbours contribute nothing:
## there is no drawn surface on the other side to crack against.
func edges_for(key: Vector2i, chunks: Dictionary) -> int:
	var own = chunks.get(key)
	if own == null or not own.streamed_in:
		return 0
	var mask := 0
	var my_step := step_for(own)
	var east = chunks.get(key + Vector2i(1, 0))
	if east != null and east.streamed_in and step_for(east) != my_step:
		mask |= Edge.EAST
	var west = chunks.get(key + Vector2i(-1, 0))
	if west != null and west.streamed_in and step_for(west) != my_step:
		mask |= Edge.WEST
	var south = chunks.get(key + Vector2i(0, 1))
	if south != null and south.streamed_in and step_for(south) != my_step:
		mask |= Edge.SOUTH
	var north = chunks.get(key + Vector2i(0, -1))
	if north != null and north.streamed_in and step_for(north) != my_step:
		mask |= Edge.NORTH
	return mask

## Mesh step a chunk at its current level builds with. Must match `ChunkApplier.mesh_step()`: the
## step halves per level, and is fitted down until it divides the chunk grid exactly, because a
## step that does not divide it drifts off the fine grid and misaligns both seams and collision
## (design D5.1).
func step_for(chunk) -> int:
	if chunk == null:
		return 1
	var cells: int = chunk.sample_rect.size.x - 1
	var base := 1
	if host != null and int(host.chunk_resolution) > 0 and int(host.chunk_resolution) < cells:
		base = maxi(cells / int(host.chunk_resolution), 1)
	var step: int = base << maxi(int(chunk.lod_level), 0)
	var w: int = chunk.sample_rect.size.x
	var h: int = chunk.sample_rect.size.y
	var fitted := mini(step, mini(w - 1, h - 1))
	while fitted > 1 and ((w - 1) % fitted != 0 or (h - 1) % fitted != 0):
		fitted -= 1
	return maxi(fitted, 1)

## Skirt wall depth in metres for a chunk built at [param step] (design D5.4): two coarse cells,
## clamped to [1, 6] m. The gap a T-junction can open is bounded by the height a coarse cell can
## skip over, so two cells of wall is a safe margin and invisible from any angle.
## `seam_skirt_depth > 0` overrides the derivation.
func skirt_depth(step: int) -> float:
	if host != null and float(host.seam_skirt_depth) > 0.0:
		return float(host.seam_skirt_depth)
	var c := maxf(_cell, 0.0001)
	return clampf(c * float(maxi(step, 1)) * 2.0, 1.0, 6.0)

# --- Queries -----------------------------------------------------------------------------------

## Level changes since construction, and how many of them reversed the previous direction for the
## same chunk. A parked camera must produce zero flips (design §12.1, H4).
func stats() -> Dictionary:
	return {
		"changes": _changes,
		"flips": _flips,
		"distances": _distances,
		"camera": _camera_pos,
	}
