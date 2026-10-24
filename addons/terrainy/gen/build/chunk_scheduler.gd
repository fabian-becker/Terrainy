@tool
extends RefCounted

## Frame-budget accountant and the chunk work queue (track B, design D7.1-D7.3).
##
## One instance per generator, owned by [ChunkApplier]. It answers exactly two questions:
##
##   1. *How much main-thread terrain time is left in this frame?* - [method begin_frame] opens the
##      window, [method spend] charges every unit of work to it, [method can_spend] closes it. The
##      budget is the **total** for all terrain work in the frame (mesh commit, collision commit,
##      LOD dispatch, residency, navigation kick-off), not a per-stage allowance, so a stage that
##      ran long leaves the next one no time instead of starting with a fresh allowance and blowing
##      the frame (design D7.1).
##
##   2. *What is the next thing worth doing?* - a seven-class priority queue drained high to low,
##      FIFO inside a class (design D7.2), with a starvation guard so a permanent stream of edits
##      cannot hide collision forever.
##
## The unit of work is one chunk: a unit popped by [method take_next] is either dispatched or
## explicitly re-enqueued by the caller, never silently dropped.
##
## The accountant deliberately knows nothing about chunks, cameras or meshes - it is a queue and a
## stopwatch, which is what makes it testable without a scene tree.

## Work classes, drained in this order (design D7.2).
## [constant EDIT] is what the user is looking at right now, [constant LOD_REFINE] sharpens a
## chunk the camera is approaching (quality the player can see), [constant LOD_COARSEN] cheapens a
## chunk it is leaving (a win the player cannot see, hence lower priority).
enum Priority { EDIT, NEAR, LOD_REFINE, LOD_COARSEN, COLLISION, SCATTER, NAV }

const PRIORITY_COUNT := 7

## Name of each class, for diagnostics and tests. Indexed by [enum Priority].
const PRIORITY_NAMES: Array[String] = ["edit", "near", "lod_refine", "lod_coarsen", "collision", "scatter", "nav"]

## Total main-thread milliseconds the terrain may spend this frame. `<= 0` means unbudgeted, which
## is the documented escape hatch for bakes and tests (design D7.1 rule 6).
var budget_ms: float = 8.0
## A queued unit is promoted one class per this many frames it waited, so no class starves.
var boost_after_frames: int = 60
## A unit that costs more than `budget_ms * slow_unit_factor` is counted as a slow unit, which is
## how a regression in unit size gets noticed instead of hiding (design D7.1 rule 4).
var slow_unit_factor: float = 2.0
## Optional resolver used by [method enqueue_keys]: key -> Chunk. Without it, key-only entries are
## dropped at [method take_next] because there is nothing to dispatch.
var chunk_lookup: Callable = Callable()

## One FIFO per class. Entries are dictionaries shared with [member _entries].
var _queues: Array = []
## Chunk key -> entry, so re-queueing a chunk updates its entry instead of stacking rebuilds.
var _entries: Dictionary = {}

var _frame: int = 0
var _now_msec: int = 0
var _spent_ms: float = 0.0
var _seq: int = 0
var _units: int = 0
var _drops: int = 0
var _overruns: int = 0
var _slow_units: int = 0

func _init() -> void:
	clear()

# --- Budget accountant -------------------------------------------------------------------------

## Open a new frame window. [param now_msec] is the frame clock the starvation guard counts in.
func begin_frame(now_msec: int) -> void:
	_frame += 1
	_now_msec = now_msec
	_spent_ms = 0.0
	# Note: `_overruns` and `_slow_units` are deliberately *not* reset here - they are cumulative
	# health counters, not per-frame numbers; `spent_ms()` is the per-frame value.

## Charge [param ms] of main-thread work to this frame.
func spend(ms: float) -> void:
	var cost := maxf(ms, 0.0)
	_spent_ms += cost
	if budget_ms > 0.0 and cost > budget_ms * slow_unit_factor:
		_slow_units += 1

## Milliseconds spent so far this frame.
func spent_ms() -> float:
	return _spent_ms

## Milliseconds still available; [constant INF] when unbudgeted.
func remaining_ms() -> float:
	if budget_ms <= 0.0:
		return INF
	return maxf(budget_ms - _spent_ms, 0.0)

## True while this frame may still start another unit. Checked *between* units, never inside one,
## so the contract is "worst frame <= budget + one unit + O(1)" (design D7.1 rule 2).
func can_spend() -> bool:
	if budget_ms <= 0.0:
		return true
	return _spent_ms < budget_ms

## Count a frame whose terrain work exceeded the budget. Called by the host once per frame.
## Kept separate from [method can_spend] because a single unit is allowed to overshoot.
func note_overrun(overrun: bool) -> void:
	if overrun:
		_overruns += 1

# --- Queue -------------------------------------------------------------------------------------

## Queue [param chunk] for work at [param priority]. A chunk already queued keeps one entry: its
## class and distance are replaced, so a chunk that changes its mind twice is built once.
func enqueue(chunk, priority: int) -> void:
	if chunk == null:
		return
	var key: Vector2i = chunk.key
	var p := clampi(priority, 0, PRIORITY_COUNT - 1)
	var entry = _entries.get(key)
	if entry != null:
		if int(entry["priority"]) == p:
			# Same class: keep its queue position (FIFO fairness) and just refresh the payload.
			entry["chunk"] = chunk
			entry["frame"] = _frame
			return
		entry["priority"] = p
		entry["chunk"] = chunk
		entry["frame"] = _frame
		entry["seq"] = _seq
		_seq += 1
		_queues[p].append(entry)
		return
	var fresh := {
		"key": key, "chunk": chunk, "priority": p, "frame": _frame, "seq": _seq, "cancelled": false,
	}
	_seq += 1
	_entries[key] = fresh
	_queues[p].append(fresh)

## Queue a list of chunk keys. Needs [member chunk_lookup] to resolve them at pop time.
func enqueue_keys(keys: Array, priority: int) -> void:
	for key in keys:
		var chunk = null
		if chunk_lookup.is_valid():
			chunk = chunk_lookup.call(key)
		if chunk == null:
			continue
		enqueue(chunk, priority)

## Drop a queued chunk (it became clean, was removed, or its work is no longer wanted).
func cancel(chunk) -> void:
	if chunk == null:
		return
	cancel_key(chunk.key)

func cancel_key(key: Vector2i) -> void:
	var entry = _entries.get(key)
	if entry == null:
		return
	entry["cancelled"] = true
	_entries.erase(key)
	_drops += 1

## Pop the highest non-empty class up to [param max_priority]. Returns a Chunk, or null when the
## queue is empty. The caller owns the unit from here: dispatch it or re-enqueue it.
func take_next(max_priority: int = Priority.NAV):
	if _entries.is_empty():
		return null
	var limit := clampi(max_priority, 0, PRIORITY_COUNT - 1)
	var best_class := -1
	var best_entry = null
	var best_rank := 1 << 30
	for p in range(0, limit + 1):
		var entry = _front_live(p)
		if entry == null:
			continue
		# Rank is measured in "frames waited, one class = boost_after_frames frames": a unit that
		# waited a full boost period beats one class above it that just arrived, so a busy EDIT
		# stream cannot starve COLLISION or NAV forever (design D7.2 starvation guard).
		var waited := _frame - int(entry["frame"])
		var rank: int = p * maxi(boost_after_frames, 1) - waited
		if rank < best_rank:
			best_rank = rank
			best_class = p
			best_entry = entry
	# `<=` order above means the first class scanned wins a tie, which is exactly "higher class
	# first, FIFO inside a class".
	if best_entry == null:
		return null
	_queues[best_class].pop_front()
	_entries.erase(best_entry["key"])
	_units += 1
	var chunk = best_entry["chunk"]
	if chunk == null:
		_drops += 1
		return null
	return chunk

## True when anything is queued at or above [param max_priority].
func has_work(max_priority: int = Priority.NAV) -> bool:
	if _entries.is_empty():
		return false
	var limit := clampi(max_priority, 0, PRIORITY_COUNT - 1)
	for p in range(0, limit + 1):
		if _front_live(p) != null:
			return true
	return false

## Number of queued units.
func queued() -> int:
	return _entries.size()

## Total units handed out since construction (a unit may be re-enqueued, so this counts work, not
## distinct chunks).
func units_taken() -> int:
	return _units

## Forget everything queued. Called on terrain resize and on teardown.
func clear() -> void:
	_queues = []
	for i in PRIORITY_COUNT:
		_queues.append([])
	_entries.clear()
	_spent_ms = 0.0
	_units = 0
	_drops = 0
	_overruns = 0
	_slow_units = 0

func stats() -> Dictionary:
	var per_class: Dictionary = {}
	for i in PRIORITY_COUNT:
		per_class[PRIORITY_NAMES[i]] = _queue_live_count(i)
	return {
		"queued": _entries.size(),
		"spent_ms": _spent_ms,
		"budget_ms": budget_ms,
		"units": _units,
		"drops": _drops,
		"overruns": _overruns,
		"slow_units": _slow_units,
		"classes": per_class,
	}

# --- Internals ---------------------------------------------------------------------------------

## Front entry of class [param p] that is still wanted, discarding stale duplicates and cancelled
## entries on the way. Returns null when the class has nothing live.
func _front_live(p: int):
	var q: Array = _queues[p]
	while not q.is_empty():
		var entry = q[0]
		if bool(entry["cancelled"]) or int(entry["priority"]) != p:
			# Cancelled, or re-queued into another class: this copy is stale.
			q.pop_front()
			continue
		return entry
	return null

func _queue_live_count(p: int) -> int:
	var n := 0
	for entry in _queues[p]:
		if not bool(entry["cancelled"]) and int(entry["priority"]) == p:
			n += 1
	return n
