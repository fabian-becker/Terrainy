@tool
extends Node

## Registers the `.tpaint` resource format (autoload installed by the Terrainy plugin).
##
## A scene that paints stores the bundle as a real resource reference
## ([member TerrainGenerator.paint_bundle]), so the exporter has to follow it into the exported
## build and the runtime has to be able to load it. Neither works for a custom extension unless
## the loader is registered *before* the scene that references the bundle is loaded — which is
## why this runs as an autoload rather than from the generator: node `_ready()` runs after the
## scene's exported resources are already loaded.
##
## Registration is process-wide; [method register] is idempotent, so the plugin can call it in
## the editor session without double-registering.

static var _registered: bool = false

static func register() -> void:
	if _registered:
		return
	_registered = true
	ResourceLoader.add_resource_format_loader(TerrainPaintBundleLoader.new(), true)
	# Savers live on ResourceSaver (loaders on ResourceLoader) — the editor needs this one to
	# write a `.tpaint` through ResourceSaver; saving a project uses the bundle's own writer.
	ResourceSaver.add_resource_format_saver(TerrainPaintBundleSaver.new(), true)

static func is_registered() -> bool:
	return _registered

func _enter_tree() -> void:
	register()
