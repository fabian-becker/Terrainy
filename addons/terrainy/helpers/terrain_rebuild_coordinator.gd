@tool
extends Node

## Singleton for coordinating terrain rebuilds across multiple TerrainComposer instances
## Prevents GPU/CPU resource saturation by limiting concurrent rebuilds

const MAX_CONCURRENT_REBUILDS = 2

var _active_rebuilds: int = 0
var _rebuild_queue: Array = []  # Array of TerrainComposer references
var _mutex: Mutex = Mutex.new()

## Check if a rebuild can start, or queue it
## Returns true if rebuild can start now, false if queued
func request_rebuild(composer) -> bool:
	_mutex.lock()
	
	if _active_rebuilds >= MAX_CONCURRENT_REBUILDS:
		# Queue this rebuild
		if not _rebuild_queue.has(composer):
			_rebuild_queue.append(composer)
			var queue_size = _rebuild_queue.size()
			_mutex.unlock()
			print("[TerrainRebuildCoordinator] Queued rebuild for '%s' (%d active, %d queued)" % [
				composer.name, _active_rebuilds, queue_size
			])
			return false
		_mutex.unlock()
		return false
	
	# Start rebuild
	_active_rebuilds += 1
	var active = _active_rebuilds
	_mutex.unlock()
	
	print("[TerrainRebuildCoordinator] Starting rebuild for '%s' (%d active)" % [composer.name, active])
	return true

## Called when a rebuild completes
func rebuild_completed(composer) -> void:
	_mutex.lock()
	_active_rebuilds = max(0, _active_rebuilds - 1)
	
	# Start next queued rebuild if any
	if _rebuild_queue.size() > 0:
		var next_composer = _rebuild_queue.pop_front()
		var remaining = _rebuild_queue.size()
		_mutex.unlock()
		
		if is_instance_valid(next_composer) and next_composer.is_inside_tree():
			print("[TerrainRebuildCoordinator] Processing next queued rebuild (%d remaining)" % remaining)
			next_composer.call_deferred("rebuild_terrain")
		else:
			# Invalid composer, try next
			rebuild_completed(null)
	else:
		_mutex.unlock()

## Remove a composer from the queue (e.g., when freed)
func cancel_rebuild(composer) -> void:
	_mutex.lock()
	_rebuild_queue.erase(composer)
	_mutex.unlock()

## Get current status (for debugging)
func get_status() -> Dictionary:
	_mutex.lock()
	var status = {
		"active_rebuilds": _active_rebuilds,
		"queued_rebuilds": _rebuild_queue.size()
	}
	_mutex.unlock()
	return status
