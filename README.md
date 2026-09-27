![Terrainy Logo](logo.png)

A hybrid node-based and spatial terrain editor for Godot 4 with live preview and blending capabilities.

## Features

- **Spatial Workflow**: Create terrain by placing and positioning feature nodes directly in the 3D viewport
- **Live Preview**: Real-time terrain updates as you modify features
- **Node-Based Composition**: Combine multiple terrain features using a hierarchical node structure
- **Rich Feature Library**: Includes primitives, gradients, landscapes, and noise-based terrain generation

### Terrain Features

**Primitives**

- Hills, Mountains, Volcanoes
- Craters and Islands

**Gradients**

- Radial and Linear gradients
- Cone and Hemisphere shapes

**Landscapes**

- Mountain Ranges
- Canyons
- Dune Seas

**Procedural**

- Perlin Noise
- Voronoi patterns

**Object Scattering**

- Scatter packed scenes (grass, trees, props, buildings) after terrain generation
- Deterministic placement with seed, density, and transform variation controls
- Optional AABB overlap rejection
- Scope-aware placement:
  - If `ScatterNode` is child of a terrain feature, placement is constrained to the parent feature influence area
  - If `ScatterNode` is direct child of `TerrainComposer`, placement uses the full terrain area

### Terrain Modifiers

All terrain features support modifiers that can be applied to adjust their appearance:

**Smoothing**

- **None**: No smoothing applied (default)
- **Light**: Subtle smoothing for reducing sharp edges
- **Medium**: Balanced smoothing for most use cases
- **Heavy**: Strong smoothing for very rounded terrain

Smoothing is particularly useful for reducing the spikiness of procedural terrain like mountains and noise patterns. Adjust the `smoothing_radius` to control the area of influence.

**Terracing**

- Creates stepped, layered terrain effects
- Adjust `terrace_levels` for the number of steps
- Control `terrace_smoothness` for hard edges vs smooth transitions

**Height Clamping**

- Limit minimum and/or maximum height values
- Useful for creating plateaus or preventing extreme elevation changes

## Installation

1. Copy the `addons/terrainy` folder to your Godot project's `addons` directory
2. Enable the plugin in Project Settings → Plugins

## Usage

1. Add a `TerrainComposer` node to your scene
2. Add `TerrainFeatureNode` children (or any of the specific feature types)
3. Position and configure the features in the 3D viewport
4. The terrain mesh will automatically update with your changes

## Quickstart Tutorial (Editor Preview)

1. Create a new 3D scene and add a `TerrainComposer`.
2. Add a `HillNode` (or any feature) as a child of the composer.
3. Move/scale the feature using the gizmos to see live updates.
4. If updates lag during heavy edits, toggle `Auto Update` off, tweak, then press **Rebuild Terrain**.

### GPU Acceleration

Terrainy uses compute shaders whenever a `RenderingDevice` is available (Forward+ / Mobile). Three switches on `TerrainComposer` control it:

- **Use GPU Composition** — blends feature heightmaps and applies modifiers (smoothing/terracing/clamping) on the GPU
- **Use GPU Feature Evaluation** — evaluates the *shape* of feature nodes with compute kernels. Feature types without noise (hills, mountains, craters, volcanoes, islands, shapes, gradients, heightmaps) match the CPU result exactly; noise-based features are always evaluated on the CPU, so the preview and the bake agree

All GPU paths fall back to the CPU automatically when a feature cannot be evaluated on the GPU (mask textures, noise-based features, allocation failures), so enabling a switch never breaks a terrain.

### Compatibility Renderer Note

If you are using the Compatibility renderer (or running headless), GPU composition/modifiers are automatically disabled and the plugin falls back to CPU. This prevents editor freezes but may be slower.

### Headless and Server Builds

When terrain is cooked before shipping (baking, dedicated servers, export tools), consider:

- **`Use Multithreading`** — leave it off for headless/`--headless` runs. Chunk meshes are then built synchronously on the calling thread. A worker thread still busy when the node leaves the tree makes `_exit_tree()` wait up to 5 seconds before forcing the exit (with a warning), which is easy to hit in short-lived headless processes
- **`Chunk Apply Budget`** — main-thread milliseconds a frame may spend applying finished chunk meshes and collision shapes (default 8 ms). Worker results are queued and drained over several frames, so a long rebuild no longer blocks the editor in one frame. Set it to `0` for bakes and tools that need everything applied before the call returns
- **`Collision Quality`** — chunks that contain holes need a `ConcavePolygonShape3D` (trimesh) collision shape, which is the most expensive part of a rebuild, because a physics shape update costs roughly 2 µs per triangle. The preset is a triangle budget per chunk: **Exact** (default) keeps every visual triangle, **Balanced** aims for 65 536, **Fast** for 8 192. Coarser presets use every Nth heightmap sample, so the collision surface no longer follows detail between the samples; the sample step has to divide the chunk resolution evenly, so a preset can overshoot its budget (on a 513² chunk: Balanced → step 2 / ~131k triangles, Fast → step 8 / 8 192 triangles). `Collision Triangle Budget` overrides the preset with an explicit triangle count; chunks without holes always use the cheap `HeightMapShape3D` and ignore both. Setting a collision property only queues the refresh: the shapes are rebuilt over the following frames (or synchronously with `Chunk Apply Budget = 0` + `use_multithreading = false`)
- **`Generate Navigation Mesh`** — bakes a `NavigationMesh` for the terrain surface and hands it to an internal `NavigationRegion3D` child, so navigation agents can path over the terrain without the project baking it from the chunk meshes itself. See [Navigation](#navigation)
- **`Debug Logging`** — prints per-rebuild timings, cache hit/miss statistics, which features were evaluated on the GPU vs. the CPU, and a one-line summary of every rebuild (`Rebuild #12 in 431 ms (mesh 210 ms, collision 180 ms) [chunks=16, collision_decimated=4]`)
- **`Auto Update`** — turn it off and call `rebuild_terrain()` explicitly when driving the terrain from a script

## Texture Layers

`TerrainComposer.texture_layers` holds `TerrainTextureLayer` resources (albedo/normal/roughness/metallic/AO). Each layer is projected in **world space from above** and blended by height range and slope range:

- `uv_scale` / `uv_offset` are in world units per texture tile (e.g. `Vector2(10, 10)` = one texture tile per 10 m)
- `blend_mode`: **Normal** layers are averaged by their weight, **Add** layers contribute additively, **Multiply** layers modulate (tint/darken) the blended result
- The material supports up to **32 layers** (`MAX_LAYERS`). Additional layers are ignored and a warning is printed
- `texture_array_size` (256–8192, default 2048) is the edge length of the `Texture2DArray` that holds the layers. Sources larger than this are downscaled, never upscaled — raise it to keep large source textures crisp, lower it to save VRAM

## Runtime Queries

`TerrainComposer` exposes read-only helpers for gameplay code (spawning, water, camera logic) that would otherwise need a raycast:

```gdscript
# Composed terrain height in world space (base_height included), sampled bilinearly
var y: float = composer.get_height_at_world_position(world_pos)

# true inside a HoleNode opening
var is_hole: bool = composer.is_hole_at_world_position(world_pos)

# highest WaterNode surface covering the position, -INF if none
var level: float = composer.get_water_level_at_world_position(world_pos)

# features whose influence area contains the position
var features: Array[TerrainFeatureNode] = composer.get_features_at_world_position(world_pos)
```

`get_height_at_world_position()` returns `global_position.y + base_height` when the terrain has not been built yet or the position is outside `terrain_size`; `is_hole_at_world_position()` returns `false` in the same cases.

## Navigation

Navigation is opt-in per composer. With **`Generate Navigation Mesh`** enabled, the terrain bakes a `NavigationMesh` after every rebuild that changed the surface and exposes it through an internal `NavigationRegion3D` child named `TerrainNavigation`:

```gdscript
# Bake on demand (the bake is queued, never run inline in the setter)
composer.rebuild_navigation_mesh()

# The mesh of the last finished bake, null before the first one
var navmesh: NavigationMesh = composer.get_navigation_mesh()

# True while a bake is queued or in flight
if composer.is_baking_navigation_mesh():
    await composer.navigation_mesh_baked   # signal: navigation_mesh_baked(navigation_mesh)
```

- **`navigation_mesh_template`** — a `NavigationMesh` whose settings (cell size, agent radius/height, max slope, region sizes, ...) every bake copies onto a fresh mesh. The template is never written to; each bake produces a new resource, which is what makes the navigation server pick up the updated polygons
- **`navigation_triangle_budget`** — triangles per chunk fed to the rasteriser (`0` uses 16 384). The bake rasterises into cells (0.25 units by default), so a budget that is far below the visual triangle count costs no quality: 500k triangles per chunk buy no detail, they only make the bake slower. Holes are honored — carved chunks contribute the carved surface, so agents cannot path through a `HoleNode` opening
- The bake follows `use_multithreading`: on a worker thread (the callback lands on the main thread a few frames later) or blocking when multithreading is off. Bakes are coalesced: a rebuild that changes the terrain during a bake queues exactly one follow-up bake
- Turning the option off drops the region (and with it the navigation server's polygons)

`is_rebuilding()` tells you whether the composer still has work in flight (chunk jobs, a queued collision refresh or queued results that have not been applied yet), which is what tools and tests should wait on instead of counting frames.

## Known Limitations

- **Texture projection is top-down (planar), not triplanar.** Albedo/normal maps are mapped from world XZ, so textures stretch on near-vertical cliffs and the projection does not follow node rotation. Rotating or translating a `TerrainComposer` also moves the texture projection relative to the terrain
- **Terrain bounds are treated as world space** for queries and scattering while chunk vertices are generated around the composer's local origin. Keep the composer at the origin (or offset the query positions yourself) if you translate it in X/Z
- **Noise-based features are CPU-only**: their kernels would have to reimplement `FastNoiseLite` to match the CPU result, so they always run on the CPU (see `Use GPU Feature Evaluation`)
- **Scattering happens after the heightmap is composed** — instances are placed on the sampled surface, so holes are not taken into account for placement
- **Collision can be decimated**: with `Collision Quality` set to *Balanced* or *Fast* (or a positive `Collision Triangle Budget`), the trimesh collision of chunks with holes follows a coarser grid than the visible mesh, so detail between samples is not collidable (the surface is slightly flatter than it looks). *Exact* (the default) keeps collision and visuals identical; chunks without holes always use a heightmap shape
- **The navigation mesh is baked from the decimated surface** and rasterised into cells (`NavigationMesh.cell_size`), so it is intentionally coarser than the rendered terrain. Small ledges below the cell height do not become walkable surfaces

## Tests

A dependency-free headless suite lives in `addons/terrainy/tests` (no GUT required):

```bash
godot --headless --path . --script res://addons/terrainy/tests/run_tests.gd
# optional: -- --verbose  (print every check)  |  -- --filter=modifier
```

It exits with code `0` on success and `1` on failure, which makes it suitable for CI (see `.github/workflows/run_tests.yml`). GPU/CPU parity cases skip themselves when no `RenderingDevice` is available, so run the suite **without** `--headless` to cover them. See [addons/terrainy/tests/README.md](addons/terrainy/tests/README.md).

## Demo Scene (Included in Addon)

The addon now includes a minimal demo scene at:

- [addons/terrainy/demo/terrainy_demo.scn](addons/terrainy/demo/terrainy_demo.scn)

## Configuration

The `TerrainComposer` node provides several options:

- **Terrain Size**: Overall dimensions of the terrain mesh
- **Resolution**: Detail level (16-512)
- **Auto Update**: Enable/disable automatic rebuilding
- **Performance**: Threading, chunking, and parallel processing options

## Version

0.6.0

## License

MIT License - see [LICENSE](LICENSE) for details

## Author

LuckyTeapot
