@tool
extends RefCounted

## Row-band parallelism for the composition passes (worker safe).
##
## A compose already runs on a [WorkerThreadPool] task; its passes hand their row loops here, and
## this spreads them over plain [Thread]s. Measured on the reference box a group task on the worker
## pool only reached ~2.9x over 16 bands (nested or from the main thread), while raw threads reach
## ~7.4x -- the pool does not scale there, so the compose does not depend on it. The calling thread
## runs one share itself instead of idling through a join.
##
## A band only ever touches rows it owns -- of its own private block, or of the caller's buffers --
## so no pass needs a join copy and two bands can never race on the same pixels.
##
## How many bands run is a performance decision, never a semantic one: every pass recomputes its
## per-row world coordinate from the row index (see [method TerrainGrid.world_z]), so a composed
## value cannot depend on the split.

## Fewest rows worth a task: below this the hand-off costs more than the work.
##
## The one definition: [Composer], [MaskSnapshot] and [ModifierSnapshot] reference it instead of
## keeping a copy, and [HMap.blurred] passes it explicitly.
const MIN_ROWS_PER_BAND: int = 8

## How many bands [param rows] should be split into: enough to fill the pool, never so many that a
## band drops below [param min_rows]. Returns 1 for "run inline".
static func band_count(rows: int, threads: int, min_rows: int = MIN_ROWS_PER_BAND) -> int:
	if rows <= 0 or threads <= 1:
		return 1
	return clampi(rows / maxi(min_rows, 1), 1, maxi(threads, 1))

## Half-open row range `[x, y)` of band [param index] when [param rows] are split into [param count].
static func band_range(rows: int, count: int, index: int) -> Vector2i:
	if count <= 1:
		return Vector2i(0, rows)
	var step := int(ceil(float(rows) / float(count)))
	var y0 := mini(index * step, rows)
	return Vector2i(y0, mini(y0 + step, rows))

## Run `fn(index)` for [param count] elements: inline on this thread when there is nothing to gain,
## otherwise on up to [param threads] threads, the caller taking one share.
##
## Returns false when a share did not finish its elements: the body of a band raised a script error,
## which GDScript reports and then abandons. A [Thread] that could not be started is recoverable and
## is retried inline, so it does not fail the pass; an abandoned band cannot be retried by anyone,
## and the caller must then refuse to publish that buffer (see [method ModifierSnapshot.apply] and
## [method Composer._prefetch_fields]).
##
## The join cannot be skipped by an aborting share: the caller's own share runs inside
## [method _run_share], so an abandoned body returns here and every started thread still gets joined.
static func run(threads: int, count: int, fn: Callable) -> bool:
	if count <= 0:
		return true
	var workers := mini(maxi(threads, 1), count)
	var done: Array = []
	done.resize(count)
	if workers <= 1:
		_run_share(fn, 0, 1, count, done)
		return _all_done(done)
	var handles: Array[Thread] = []
	var started := 0
	for w in workers - 1:
		var th := Thread.new()
		# `start()` returns an Error; discarding it used to leave those elements silently unwritten.
		var err := th.start(_run_share.bind(fn, w, workers, count, done))
		if err != OK:
			push_warning("[Terrainy] band thread refused (error %d): running the rest inline" % err)
			break
		handles.append(th)
		started += 1
	var caller_share: bool = started == workers - 1
	if caller_share:
		_run_share(fn, workers - 1, workers, count, done)
	for th in handles:
		th.wait_to_finish()
	if not caller_share:
		# Fail soft, not silently: the shares that never got a thread run here, after the join, so
		# the pass is still complete -- just slower.
		for w in range(started, workers):
			_run_share(fn, w, workers, count, done)
	return _all_done(done)

## Run `fn(y0, y1)` over [param rows] split into bands. [param offset] is added to both ends, so a
## caller can band a sub-rectangle while the callback sees absolute rows. Returns false when a band
## did not finish (see [method run]).
static func run_rows(threads: int, rows: int, offset: int, fn: Callable, min_rows: int = MIN_ROWS_PER_BAND) -> bool:
	var count := band_count(rows, threads, min_rows)
	if count <= 1:
		fn.call(offset, offset + rows)
		return true
	return run(threads, count, func(i: int) -> void:
		var rng := band_range(rows, count, i)
		fn.call(offset + rng.x, offset + rng.y))

## Interleaved share of the elements: worker [param w] takes `w, w + workers, ...`.
##
## A separate function on purpose: if `fn` raises, GDScript abandons this body and returns to
## [method run], which still reaches its join loop. The element whose body was abandoned keeps its
## [param done] slot unset, so [method run] can report it.
static func _run_share(fn: Callable, w: int, workers: int, count: int, done: Array) -> void:
	var i := w
	while i < count:
		fn.call(i)
		done[i] = true
		i += workers

static func _all_done(done: Array) -> bool:
	for i in done.size():
		if done[i] == null or not bool(done[i]):
			return false
	return true

