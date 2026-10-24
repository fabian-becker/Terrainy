@tool
class_name TerrainySignalHub
extends RefCounted

## Statically reachable signal hub: `TerrainyAPI.signals.region_changed.connect(...)`.

## A dirty region (one chunk's world AABB) of [param terrain] was rebuilt and applied.
signal region_changed(terrain: TerrainGenerator, aabb: AABB)
## A generator entered the tree and registered itself.
signal terrain_added(terrain: TerrainGenerator)
## A generator left the tree.
signal terrain_removed(terrain: TerrainGenerator)
