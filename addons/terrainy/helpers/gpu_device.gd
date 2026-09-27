extends Object

## Process-wide local [RenderingDevice] shared by every Terrainy GPU helper.
##
## A local rendering device is a full Vulkan logical device, and drivers only allow a small
## number of them per process (roughly 16-32 on NVIDIA/AMD). Terrainy used to create one per
## GPU helper instance - one per feature node owning a modifier pipeline, plus one per
## composer for composition and evaluation - and never released them. Scenes with a handful
## of Terrainy nodes therefore exhausted the driver limit, and the next
## [method RenderingServer.create_local_rendering_device] call crashed inside the driver with
## an access violation. Editor sessions leaked one more device on every scene reload.
##
## Every helper now shares this single device. RIDs are device-scoped, so a helper must still
## free only the RIDs it created itself, and nobody may free the shared device while other
## helpers still hold RIDs on it.
##
## The device is created lazily on first use and kept until the process exits. It is never
## freed explicitly: helpers may be disposed in any order and freeing the device underneath a
## helper that still holds RIDs on it would be unsafe. The engine reports it as one leaked
## ObjectDB instance (plus two driver-internal objects) at exit - this used to be reported
## once per helper instance.

static var _device: RenderingDevice = null
static var _unavailable: bool = false


## Returns the shared rendering device, or [code]null[/code] when GPU work is unavailable
## (compatibility renderer, headless/dummy driver, a non-main-thread caller) or when its
## creation already failed.
static func get_device() -> RenderingDevice:
	if _device != null:
		return _device
	if _unavailable:
		return null
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		# Local rendering devices may only be created and used from the main thread, so a
		# worker thread falls back to the CPU instead of racing a second device.
		return null
	if not RenderingServer.get_rendering_device():
		_unavailable = true
		return null
	_device = RenderingServer.create_local_rendering_device()
	if _device == null:
		_unavailable = true
	return _device


## Whether a shared rendering device is available. Creates it on first call.
static func is_available() -> bool:
	return get_device() != null
