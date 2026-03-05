@tool
class_name TerrainBakeMetadata
extends Resource

## Binary metadata stored alongside baked chunk resources.

@export var bake_version: int = 1
@export var terrain_hash: String = ""
@export var chunk_entries: Array[Dictionary] = []
