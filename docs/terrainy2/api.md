# TerrainyAPI

Static integration API (`addons/terrainy/api/terrainy_api.gd`). Every call takes the terrain
explicitly, so several generators can coexist. Generators register on `_ready` and unregister
on `_exit_tree`. Queries read the last **applied** composition, never trigger a rebuild, and
are main-thread calls.

## Registry & signals

```gdscript
TerrainyAPI.get_terrains() -> Array[TerrainGenerator]
TerrainyAPI.find_terrain_at(world_pos: Vector3) -> TerrainGenerator   # null outside every terrain
TerrainyAPI.register(terrain) / unregister(terrain)                   # automatic

TerrainyAPI.signals.region_changed(terrain, aabb: AABB)   # one rebuilt + applied chunk
TerrainyAPI.signals.terrain_added(terrain)
TerrainyAPI.signals.terrain_removed(terrain)
```

`TerrainGenerator` also emits `terrain_region_updated(aabb)`, `terrain_resized`,
`texture_layers_changed`, `paint_layers_changed`, `navigation_mesh_baked(mesh, chunk)` and
`terrain_build_failed(message)`.

## Queries

| Call | Returns |
|---|---|
| `get_height_at(terrain, pos)` | World height, bilinear, `base_height` included. Outside: generator y + base_height. Invalid terrain: `NAN` |
| `get_normal_at(terrain, pos, eps = 1.0)` | Central-difference normal |
| `get_hole_at(terrain, pos)` | `true` inside a hole |
| `get_paint_at(terrain, layer, pos)` | Layer value: delta meters / pinned height / 0..1 weight |
| `get_texture_blend_at(terrain, pos)` | `{palette index: weight}` (CPU mirror of the auto material, without its cosmetic blend noise) |
| `get_fields_at(terrain, pos)` | `Array[TerrainFieldNode]` acting there (weight > 0 after masks) |
| `sample_region(terrain, rect, resolution)` | `Heightfield2D` (world heights + hole flags) |
| `sample_region_async(terrain, rect, resolution)` | awaitable: settles first, then samples |
| `get_painted_region_aabb(terrain, layers = [])` | World AABB of painted content |
| `is_rebuilding(terrain)` | Any stage queued, running or being applied |
| `await wait_for_settle(terrain, timeout_sec = 60)` | `OK`, `ERR_TIMEOUT` or `ERR_INVALID_PARAMETER` |
| `get_diagnostics(terrain)` | Rebuild id/report, phase timings, counters, chunk + GPU state |

`Heightfield2D`: `rect`, `resolution`, `heights`, `holes`, `get_height(x, y)`,
`is_hole(x, y)`, `world_position(x, y)`, `to_image()`, `min_max()`.

Runtime **editing** is declarative in 2.0: change node configuration from code and the terrain
rebuilds (debounced in the editor, next frame at runtime; `rebuild_now()` for synchronous).
Brush stamping is editor-only; a public stamp surface is a 3.x candidate.

```gdscript
var terrain := TerrainyAPI.find_terrain_at(player.global_position)
await TerrainyAPI.wait_for_settle(terrain)
var ground := TerrainyAPI.get_height_at(terrain, player.global_position)
var blend := TerrainyAPI.get_texture_blend_at(terrain, player.global_position)
var on_sand: bool = blend.get(SAND_INDEX, 0.0) > 0.5
TerrainyAPI.signals.region_changed.connect(func(t, aabb): navigation_cache.invalidate(aabb))
```

## Water interop

Terrainy 2 has no water node, shader or carving. Your water system owns rendering; the terrain
is data:

```gdscript
var ground: float = TerrainyAPI.get_height_at(terrain, world_position)
var submerged: bool = world_position.y < water_level and ground < water_level
# Basins / river beds: carve them with fields (Corridor + Curve elevation, Global MIN fields,
# World elevation origin). A water plane at that level reads get_height_at() for shore
# snapping and debris placement; sample_region() gives a shoreline/depth texture.
```

## Custom materials

The auto material is the zero-config default. `TerrainGenerator.custom_material` replaces it.
When it is a `ShaderMaterial`, the generator still binds:

| Uniform | Content |
|---|---|
| `sampler2DArray terrainy_weight_planes` | R8, slice *i* = claim of palette layer *i* (surface REPLACE contributions + TEXTURE paint, paint wins), Σ ≤ 1 |
| `sampler2DArray terrainy_modulation_planes` | RG8, slice *i*: R = ADD contribution, G = SUPPRESS contribution |
| `int terrainy_layer_count` | palette size (`texture_layers` + contribution-owned layers) |
| `bool terrainy_has_claims`, `bool terrainy_has_modulation` | whether the planes carry data (otherwise a 1×1 dummy is bound) |
| `vec2 terrainy_terrain_origin`, `vec2 terrainy_terrain_size` | world XZ rect the planes cover |

Sample with `uv = (world_pos.xz - terrainy_terrain_origin) / terrainy_terrain_size`. The planes
use the paint grid when a TEXTURE layer holds paint, otherwise the composition grid. Palette
order: `texture_layers` first, then layers that only surface contributions reference.
`TerrainGenerator.get_weight_planes()` returns the same images on the CPU.
