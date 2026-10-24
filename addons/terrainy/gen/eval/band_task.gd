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

## Fewest rows worth a task: below this the hand-off costs more than the work.
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
## otherwise on up to [param threads] threads, the caller taking the last share.
static func run(threads: int, count: int, fn: Callable) -> void:
	var workers := mini(threads, count)
	if workers <= 1:
		for i in count:
			fn.call(i)
		return
	var handles: Array[Thread] = []
	for w in workers - 1:
		var th := Thread.new()
		handles.append(th)
		th.start(_run_share.bind(fn, w, workers, count))
	_run_share(fn, workers - 1, workers, count)
	for th in handles:
		th.wait_to_finish()

## Run `fn(y0, y1)` over [param rows] split into bands. [param offset] is added to both ends, so a
## caller can band a sub-rectangle while the callback sees absolute rows.
static func run_rows(threads: int, rows: int, offset: int, fn: Callable, min_rows: int = MIN_ROWS_PER_BAND) -> void:
	var count := band_count(rows, threads, min_rows)
	if count <= 1:
		fn.call(offset, offset + rows)
		return
	run(threads, count, func(i: int) -> void:
		var rng := band_range(rows, count, i)
		fn.call(offset + rng.x, offset + rng.y))

## Interleaved share of the elements: worker [param w] takes `w, w + workers, ...`.
static func _run_share(fn: Callable, w: int, workers: int, count: int) -> void:
	var i := w
	while i < count:
		fn.call(i)
		i += workers

