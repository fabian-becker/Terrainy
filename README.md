![Terrainy Logo](logo.png)

A hybrid node-based and spatial terrain editor for Godot 4 with live preview and blending capabilities.

> **Terrainy 2** (configuration-driven fields, paint layers, `TerrainyAPI`) is the current
> version in `addons/terrainy` — see [docs/terrainy2/README.md](docs/terrainy2/README.md).
> The 0.x feature descriptions below are kept for migration reference; see
> [the migration table](docs/terrainy2/coexistence.md) for how nodes map to 2.0.

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

**Surface Control**

- `TextureAreaNode` repaints a texture layer over its influence area and nothing else: it has no height, so it never moves the terrain
- Every feature node carries `Surface Contributions` (`TerrainSurfaceContribution` resources), so a `RoadNode` can lay grit along its corridor or a feature can suppress grass where it sits
- See [Surface Contributions](#surface-contributions)

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

### Compositional Terrain

Since the compositional redesign, features compose hierarchically instead of blending as a flat list:

**Groups** — Add a `TerrainGroupNode` and set child features to `Contribute` scope. The group composes its children into one internal landform (blended inside the group), which then blends into the terrain as a single feature. Children default to `Independent`, so existing scenes keep their behaviour exactly. Switching a child's `composition_scope` at runtime (or moving a child in or out of a group) is picked up automatically: the composer notices that its composition plan no longer matches the tree and rescans before the next rebuild.

**Modifier nodes** — `SmoothingModifier`, `TerracingModifier`, `HeightClampModifier`, `RemapRangeModifier` and `FlattenModifier` are scene-tree children placed under the feature or group they modify. Scene order (top to bottom) is the application order — reorder children in the scene dock to reorder the stack. `evaluation_space` controls WHAT they apply to: the owner's own heightmap (`Local`), the group's composited output (`Group`) or the final terrain after all composition (`World` — the world pass runs in scene order on the finished map, so constraints like "this region sits at elevation 40" hold no matter what the features did).

**Masks** — `ShapeMaskNode` (analytic circle/rectangle/ellipse with falloff) and `TextureMaskNode` (red-channel texture) are pure weight fields. Reference one from a modifier's `mask` NodePath: the modifier applies only where its own influence AND the mask overlap. `invert` flips a mask to protect an area instead.

**Paths** — `RoadNode` and `RiverNode` follow the `Curve3D` of a `Path3D` child node through the terrain (add the child and edit its curve in the viewport — there is no inspector curve export). The corridor width, `edge_falloff` banks and the curve's baked elevation profile define the shape: a road pins the terrain to the curve height, a river carves its bed `depth` units below it. Both use the `Replace` blend mode, which moves the terrain toward the path surface instead of adding to it.

**Presets & preview** — Save any feature subtree as a `TerrainPreset` resource (packed scene + default transform) and instantiate it under a composer. `preview_isolate_node` on the composer temporarily previews only one subtree — everything else renders flat — for quick inspection of a single landform; clear it to restore the full terrain.

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

### Editing and Rebuilds

Editing a feature — dragging a feature's inspector value, a `Path3D` child's curve, or a modifier — queues a rebuild, so a drag that changes several parameters costs one rebuild instead of one per edit. Each rebuild composes the heightmap and then regenerates **only the chunks the edit can affect**, taken from the feature's world-space influence bounds. Editing the far end of a long road therefore rebuilds the chunks along that road, not the whole terrain.

The compose itself always runs over the full grid, so on a large terrain a rebuild is still a multi-second, main-thread operation on the CPU — that is what the GPU composition switch and `chunk_apply_budget_ms` are for. `debug_logging` on the composer prints a one-line timing summary of every rebuild. Roads and rivers are the cheap case: both their influence map and their heightmap are rasterised along the curve's corridor instead of scanned over the whole grid, so a `Path3D` curve edit is dominated by the full-grid blend, not by the path.

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

### Surface Contributions

The layers above are global: each layer's weight is an analytic function of world height and slope, so no node can decide what the ground looks like. `surface_contributions` on any feature node closes that gap. It holds `TerrainSurfaceContribution` resources; each one points at a `TerrainTextureLayer` and describes how it is applied:

- `texture_layer` — the layer to paint. When a feature is accepted, its layers are appended to the **material's** palette, so a node can paint a texture that is not listed in `TerrainComposer.texture_layers`. Such a layer exists only for its contributions: it has no global weight of its own and shows exactly where one of its contributions paints (its own height/slope settings still gate that). Listing the layer in `texture_layers` as well makes it a normal palette layer — it is then shared, and its global height/slope blend also applies outside the contribution
- `mode`:
  - **Replace** — the layer claims the surface inside the influence, so a full-strength contribution takes the area over completely (grit over grass) even where the palette's own height/slope blend would give that layer no weight. The claim is settled after the layers are normalized and takes its share from the others, so `strength` fades between the palette's blend (`0`) and the layer alone (`1`). When several contributions claim the same surface they share it in proportion to their strength, so two full-strength `Replace` contributions on one node produce an even mix of their layers instead of an over-bright sum
  - **Add** — add the contribution's weight on top of the layer's own analytic weight (gravel that also appears wherever the slope suits it)
  - **Suppress** — fade the layer out, `weight *= 1 - strength * influence` (worn grass on a path)
- `strength` (0–1), `enabled` and `respect_layer_gate` — scale the contribution, switch it off without deleting it, or let the target layer's own height/slope blend scale it. With `respect_layer_gate` on, the layer only paints where it would apply anyway, which turns a corridor into a surface selector: give two contributions complementary slope ranges (rock on the steep cut, sand on the flat road bed) and each layer takes the parts of the influence its own slope range allows — where neither applies, the palette's blend shows through

`TextureAreaNode` is the ready-made feature for "this patch has different textures": it contributes no height at all (it is an additive feature with a flat profile, which is by definition a no-op for the height blend) and exists only to carry contributions. Its `Influence Shape`, `Influence Size` and `Edge Falloff` describe the patch that gets repainted, exactly like any other feature's influence.

```gdscript
var patch := TextureAreaNode.new()
patch.influence_shape = TerrainFeatureNode.InfluenceShape.RECTANGLE
patch.influence_size = Vector2(40.0, 40.0)

var contribution := TerrainSurfaceContribution.new()
contribution.texture_layer = preload("res://gravel_layer.tres")
contribution.mode = TerrainSurfaceContribution.Mode.REPLACE
contribution.strength = 0.85

var contributions: Array[TerrainSurfaceContribution] = [contribution]
patch.surface_contributions = contributions

composer.add_child(patch)
```

The influence map that already drives the node's geometric blend doubles as the surface weight, so the influence gizmo shows exactly the patch that gets repainted, and a `RoadNode`'s curved corridor is used instead of a box around the node. A contribution-only edit reuses the cached control map and rebuilds the material without recomposing heights.

Contributions are collected from every feature of the composition plan, group children included: a `RoadNode` nested in a `TerrainGroupNode` is folded into the group's geometry and never blends into the terrain on its own, but it still paints its own gravel inside the group. Each contributing feature costs one control-map slice, whatever number of contributions it carries, up to 16 controls in total.

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
- **Surface contributions are sampled per feature, on the heightmap grid.** Every contributing feature costs one control-map slice in the `control_maps` texture array, and the shader applies at most **16 contributions** (`MAX_SURFACE_CONTROLS`); a feature whose contributions do not fit is skipped whole and a warning is printed. The maps are rasterised at the composer's `resolution`, so a coarse heightmap also gives a coarse patch edge (the influence is smooth, the transition is not sharper than one heightmap cell)
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

0.7.0

## License

MIT License - see [LICENSE](LICENSE) for details

## Author

LuckyTeapot
