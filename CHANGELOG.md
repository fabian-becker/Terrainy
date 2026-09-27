# Changelog

All notable changes to the Terrainy plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0] - 2026-09-28

### Added

- **Runtime terrain queries** on `TerrainComposer`: `get_height_at_world_position()` (bilinear sample of the composed heightmap, world space, `base_height` included) and `is_hole_at_world_position()` (bilinear sample of the hole mask) for placing objects, water and gameplay logic without raycasts
- **`noise_seed` export** on noise-based feature nodes (noise, primitives, landscapes). Terrain is deterministic by default: rebuilds, bakes and scene reloads reproduce the exact same noise
- **GPU feature evaluation opt-in** on `TerrainComposer`: `use_gpu_feature_evaluation` (on) evaluates noise-free features with the compute kernels at CPU parity. Noise-based features always stay on the CPU, so the preview, the bake and the runtime terrain agree
- **`texture_array_size`** (256–8192, default 2048) on `TerrainComposer` to control the resolution of the terrain texture `Texture2DArray`
- **`debug_logging`** on `TerrainComposer`: per-rebuild timings, compose/feature cache statistics, GPU-vs-CPU feature evaluation counts and a one-line summary of every rebuild through `TerrainDiagnostics`
- **`chunk_apply_budget_ms`** (0–100, default 8) on `TerrainComposer`: main-thread milliseconds a single frame may spend applying finished chunk meshes and collision shapes. Worker results are queued and drained over several frames instead of blocking the editor on one long frame; `0` applies every finished result in the frame it arrives (the behaviour before frame budgeting, useful for baking and tests)
- **`collision_quality`** (`Exact`/`Balanced`/`Fast`) and **`collision_triangle_budget`** on `TerrainComposer`: the collision mesh of chunks that contain holes (which use a `ConcavePolygonShape3D`) is built from a triangle budget per chunk. Physics shape updates cost roughly 2 µs per triangle, so `Balanced` aims for 65 536 triangles per chunk and `Fast` for 8 192, while `Exact` (the default) keeps the visual geometry. The sample step has to divide the chunk resolution evenly, so a preset can overshoot its budget (on a 513² chunk, which has 524 288 triangles: `Balanced` → step 2 / 131 072 triangles, `Fast` → step 8 / 8 192). `collision_triangle_budget` overrides the preset with an explicit count
- **Navigation bake hook** on `TerrainComposer`: `generate_navigation_mesh`, `navigation_mesh_template`, `navigation_triangle_budget`, `rebuild_navigation_mesh()`, `get_navigation_mesh()`, `is_baking_navigation_mesh()` and the `navigation_mesh_baked` signal bake a `NavigationMesh` from the terrain surface and keep it on an internal `NavigationRegion3D`. The source geometry is the decimated chunk surface with the holes carved out, so a bake costs a fraction of a bake from the visual meshes
- **`is_rebuilding()`** on `TerrainComposer`: true while chunk jobs, a queued collision refresh or queued results are still in flight, so tools and gameplay code can wait for a settled terrain instead of counting frames
- **Headless test suite** in `addons/terrainy/tests` (dependency-free, no GUT) covering heightmap composition, modifiers, material packing, scattering, seed determinism, world-space queries, GPU/CPU parity, collision shapes, navigation and diagnostics, plus a GitHub Actions workflow running it in CI
- **Mountain range shape controls** on `MountainRangeNode`: `ridge_meander` (how far the crest wanders across the range), `peak_prominence` (gentle rolling summits vs contrasted peaks) and `foothill_strength` (subsidiary ridgelets in the outer flanks). Wired through to the GPU evaluator so the preview, the bake and the CPU path agree

### Changed

- **Heightmap composition batches GPU work**: all feature heightmaps are evaluated in one compute submit, all influence maps in another, and all feature modifiers are applied in a single batch instead of one submit and one `RenderingDevice` per feature
- **Modifiers are applied once, by the heightmap builder**, through the shared `ModifierPipeline` in the same order on both paths (smoothing → terracing → clamping, identical normalization and world-space radius semantics)
- **Cache invalidation is input-driven**: feature bounds, influence maps and per-feature heightmaps are only discarded when an input that can change them is edited. Editing scatter placement settings (density, seed, scene) no longer recomposes the heightmap or regenerates chunk meshes, and cached heightmaps are discarded when the resolution or bounds of the grid change
- **Scatter instances are only regenerated when their placement signature changes** (terrain content version, node parameters, parent feature revision, transform, scene, scope)
- **Collision is applied by the rebuild pipeline, never by the setter**: assigning several collision properties in a row (loading a scene, dragging in the inspector) now costs one collision refresh, which is queued and lands over the following frames. Layer/mask changes are pure property writes and are applied before a refresh would be
- **The composer is split into helpers**: chunk job dispatch and the result queues moved to `helpers/terrain_chunk_pipeline.gd`, the collision geometry to `helpers/terrain_collision_builder.gd`, the navigation source geometry to `helpers/terrain_navigation_builder.gd` and every threshold/report to `helpers/terrain_diagnostics.gd`. `TerrainComposer` keeps orchestration and the public API
- Texture layers are capped at **32 per terrain material** (`MAX_LAYERS`); exceeding it now prints a warning instead of silently misrendering
- **Mountain range crest and foothills are profiled differently**: the crest cross-section is now a Gaussian whose width `ridge_sharpness` controls, so the top is rounded at every parameter value instead of ending in a cusp; peaks sit at noise maxima instead of zero-crossings (which produced a dense sawtooth ridge); and the foothills are sampled anisotropically (high frequency perpendicular to the crest, low frequency along it) so their sub-ridges run parallel to the range instead of appearing as blobs. Crest height, ridge width and range length are derived from the support function of the influence shape, so they stay correct whichever way `direction` points. Existing scenes keep their parameters but render a different mountain, since the underlying profile changed
- **Influence maps are rasterised only inside the feature's bounds**: the pass used to walk every pixel of the terrain grid and write `0.0` outside the feature, so a feature covering 1 % of the terrain paid for 100 % of it. Both the flat and the 3D-hole generator now iterate just the pixels the feature can reach, leaving those outside at the image's initial `0.0`, which is exactly what the full pass wrote there. The clip rectangle comes from the context's rotation-aware AABB; holes tilted about X or Z use a conservative square from the squared half extents, because `compute_rotation_aware_aabb()` only transforms the four corners at `y = 0` and would otherwise truncate their vertical extent

### Fixed

- **WaterNode `water_level` is now a world-space height**: the water surface mesh is offset so it always sits at world Y = `water_level`, matching carving and the query APIs. Moving the node vertically no longer moves the surface
- **CanyonNode meandering had no effect**: the evaluation context never received the node's noise, so `meander_strength` produced straight canyons on the CPU while the GPU kernel meandered. CPU, GPU and bakes now agree
- **Scatter instances were duplicated on every rebuild**: the container's internal children were skipped when clearing, so each refresh stacked a new set of instances on top of the previous one
- **A hidden or inactive ScatterNode aborted the whole scatter refresh** (a missing scope passed `null` into an argument typed as `Dictionary`), leaving every other scatter stale
- **Normal maps are projected top-down**: the decoded map XY is a world XZ height gradient, not a tangent-space normal. The material now perturbs the geometric world normal with that gradient and re-expresses the result in the tangent frame, so slopes are lit correctly instead of as if they were flat
- **Terrain material shader** now honors texture layer `blend_mode`: **Add** layers contribute additively using their raw height/slope weight and **Multiply** layers modulate the blended result (Normal layers, first-layer fallback, and existing all-Normal stacks behave exactly as before)
- **GPU helpers crashed the driver in scenes with many Terrainy nodes**: every GPU helper instance (one per feature node owning a modifier pipeline, plus the compositor, feature evaluator and modifier of each builder) created its own local RenderingDevice and never released it. Drivers only allow a handful of logical devices per process, so the next `RenderingServer.create_local_rendering_device()` call died with an access violation, and each editor scene reload leaked another device. All helpers now share one process-wide device (`helpers/gpu_device.gd`)
- **GPU modifier batching never actually dispatched**: heightmap uploads happened while a compute list was being recorded, which the rendering device rejects, so every batch failed and silently fell back to the CPU implementation. Resources are now prepared before the compute list is opened
- **Chunk meshes were built off the main thread**, which corrupted the renderer's RID table (`Attempting to initialize the wrong RID`) and led to an intermittent access violation — on Windows usually a crash inside the graphics driver at load time or shutdown, and easier to hit the more chunk builds ran in parallel. Worker threads now only produce raw surface arrays; `ArrayMesh` creation moved to the main thread (`TerrainMeshGenerator.generate_surface_arrays()` / `mesh_from_arrays()`, ~10 ms per 513² chunk)
- **Feature nodes emitted `changed` twice per edit**, so every parameter change triggered two rebuilds instead of one
- **Surface normals along the heightmap border were half as steep as they should be**: the one-sided difference at the outer edges was scaled by `0.5 / step` like an interior central difference. Edge shading now matches the interior
- **The "slow collision update" warning also covers trimesh collisions** and names the shape kind, triangle count and the budget-derived sample step, so the remaining main-thread cost of chunks with holes is visible
- **Hole detection disagreed by one pixel**: the composer treated a heightmap pixel as a hole above `0.5` while the mesh generator carved from `HOLE_THRESHOLD` upwards, so a pixel at exactly the threshold produced a holed mesh with a hole-filling `HeightMapShape3D`. Both now use the same test

### Performance

- **Mesh builds are ~3.2× faster** (513² chunk: 1124 ms → 351 ms, 257²: 89 ms, 129²: 22 ms). `SurfaceTool.generate_tangents()`, which accounted for ~82 % of the build, is replaced by analytic tangents derived from the height gradient, so tangent generation no longer depends on surface-tool triangle adjacency
- **Chunk meshes are built in parallel** with a `WorkerThreadPool` group task over a refcounted result holder instead of a serial loop (previously one mesh at a time). Four 513² chunks now finish within ~50 ms of each other instead of ~1.5 s apart, and a rebuild of the demo terrain dropped from ~13.5 s to ~5.2 s (collision shape generation on the main thread is now the dominant remaining cost)
- **Collision shapes are built from worker-thread data**: the triangle soup of chunks with holes is produced by the same chunk job as the visual mesh (no extra `SurfaceTool`/`ArrayMesh` pass), the shapes are handed to the physics server incrementally and the `ConcavePolygonShape3D` instance is reused across rebuilds. The demo terrain's holed chunk went from ~1350 ms to ~630 ms at the default exact budget, and `collision_quality = Fast` cuts the whole main-thread collision cost to a few tens of milliseconds
- **Applying a rebuild is frame-budgeted**: finished chunk meshes and collision shapes are drained over several frames (`chunk_apply_budget_ms`), so a large terrain no longer freezes the editor in one multi-second frame while the same work still gets done in the same overall time
- **Navigation bakes reuse the collision decimation**: the bake is fed the decimated chunk surface instead of the visual meshes (500k+ triangles per 513² chunk that the rasteriser discards anyway), and it runs off the rebuild, on a worker thread when multithreading is on
- **Influence maps are ~184–206× cheaper for small features** (513²: 662 ms → 3.6 ms, 1025²: 2637 ms → 12.8 ms; a feature spanning the whole grid still gains 1.2× at 873 ms → 733 ms). Clipping the pass to the feature bounds removes work that the previous loop spent writing zeroes over the rest of the terrain, and the resulting maps are bit-identical to the full-grid ones (12 flat cases plus 8 tilted 3D-hole cases, `maxdiff 0.0`)
- **The smoothing pass is ~3.3× faster** (513², radius 2: 933 ms → 281 ms; radius 8: 2711 ms → 795 ms). The polar angle and the two world-space offsets built from `cos`/`sin` were recomputed per pixel and per sample although they only depend on the sample index; they are now precomputed once per call. The weights are kept as an untyped `Array` (Float64) rather than a `PackedFloat32Array`: storing them as f32 shifted the output by up to ~1.9e-6 on 7 of 9 configurations, while the f64 array reproduces the original bit for bit (19 of 19 configurations)
- **A rebuild with nothing to regenerate is ~7.9× faster** (963 ms → 122 ms at 1025²). `_compute_influence_bounds()` scans an entire influence map to find its non-zero rectangle (~79 ms per feature) and ran on every compose, including the ones that hit the influence cache and regenerated nothing. The rectangle is a property of the image, so it is now memoized alongside it and dropped by every path that drops the image
- **A cold compose of the demo terrain is ~1.7× faster** (1025²: 25.6 s → 14.9 s; 513²: 6.4 s → 3.7 s; 257²: 1.6 s → 0.9 s), and `invalidate_influence` went from 3.9 s to 1.3 s, as a result of the bounds clipping and the hoisted smoothing offsets

## [0.6.0] - 2026-05-03

### Added

#### Terrain Features

- **WaterNode** — Creates water bodies that carve terrain depressions and render animated water surfaces with configurable wave displacement, foam, depth-based coloring, shore slopes, and optional custom materials
- **HoleNode** — Creates passable openings in the terrain mesh with configurable edge types (sharp or beveled), bevel width controls, and 3D influence support for rotated holes
- **ScatterNode** — Places PackedScene instances on the generated terrain with density controls, deterministic random seed, min/max instance clamps, AABB overlap rejection, and scope-aware placement (constrained to parent feature influence when nested)
- **MaskTextureNode** — Non-destructive mask node that defines influence areas using a Texture2D; place as a parent of ScatterNodes or other features to restrict their influence to masked regions (white = full influence, black = none)
- **LinearGradientNode** — Linear gradient feature for directional height falloff

#### Editor & Tools

- **Shape Mask Editor** — Built-in editor dialog for ShapeNode with brush-based mask painting (Draw, Erase, Blend modes), brush size/flow/height controls, Replace and Blend paint methods, undo/redo, and image import/export
- **Terrain Baking** — Bake terrain to a standalone PackedScene via `BakeExporter`, exporting chunk meshes, collision shapes, water meshes, and scatter instances for optimized runtime performance
- **ShapeNode Inspector Plugin** — Custom inspector integration for launching the Shape Mask Editor directly from the node inspector

#### Helpers & Infrastructure

- **ModifierPipeline** — Dedicated pipeline for applying terrain modifiers (smoothing, terracing, clamping) with improved performance and consistency
- **ChunkManager** — Dedicated chunk lifecycle and dirty-state management system
- **ScatterManager** — Dedicated helper for scatter placement, overlap rejection, and MultiMesh generation
- **MultiMeshScatter** — GPU-instanced scatter rendering support for ScatterNode
- **GizmoHandle** — Reusable gizmo handle component for cleaner gizmo plugin architecture
- **ScriptUtils** — Shared editor script utilities

#### Demo & Assets

- New demo scene with character controller (`character_body_3d.gd`), sky environment, and sample placements
- Organized demo textures for rock, rocky terrain, sand, and snow environments
- `.gitattributes` configured to handle large demo texture files

### Changed

- Project upgraded to **Godot 4.6**
- Demo scene moved from `terrainy_demo.tscn` to `addons/terrainy/demo/terrainy_demo.scn`
- Demo textures reorganized into `addons/terrainy/demo/textures/`
- **TerrainFeatureNode** refactored for improved modifier handling, mask texture support, and performance
- **TerrainComposer** enhanced with hole depth sentinel, improved chunk handling, scatter rebuild scheduling, and bake integration
- **TerrainMeshGenerator** enhanced with hole support and improved collision handling
- **TerrainHeightmapBuilder** updated with improved extraction logic and chunk handling
- Influence calculations refactored with renamed mask-related variables for consistency
- **ShapeNode** and **ShapeEvaluationContext** enhanced with mask support and improved evaluation
- **EvaluationContext** system expanded with helpers and GPU parameter packing improvements
- **WaterShader** render mode and compatibility adjustments
- **HeightmapNode** now supports `NoiseTexture2D`
- Autoload reference updated to use UID

### Fixed

- Error handling in Shape Mask Editor for import and brush operations
- 3D influence calculations for rotated terrain holes
- Water shader render mode compatibility
- Terrain node functionality edge cases

[Unreleased]: https://github.com/LuckyTeapot/terrainy/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.6.0

## [0.5.1] - 2026-02-12

### Fixed

- Collision mesh offset causing collision to be positioned at chunk corner instead of center, mismatching the visual terrain mesh
- Force rebuild now fully invalidates caches and marks all chunks dirty for a complete terrain refresh

## [0.5.0] - 2026-01-27

### Added

- GPU feature evaluator with compute shader for all terrain features
- GPU parameter packing system for thread-safe evaluation contexts
- Raw heightmap generation method for improved multithreading workflow
- Multithreading toggle (`use_multithreading`) for terrain composition
- Modifier application method for post-generation processing
- Feature type enumeration for GPU kernel dispatching
- Support for gl_compatibility renderer mode

### Changed

- Terrain composer now supports single-threaded mode for compatibility testing
- Influence generator uses half-size for elliptical shape calculations
- Terrain material shader now uses world-space normals for view-independent slope calculations
- Compatibility mode disables ambient occlusion in terrain shader to avoid array sampling issues
- Project upgraded to Godot 4.6
- Autoload path uses UID reference instead of direct file path

### Fixed

- View-dependent slope calculations in terrain material shader
- Ellipse influence calculations now properly use half-size parameters
- Ambient occlusion sampling compatibility issues in gl_compatibility mode

### Performance

- GPU-accelerated feature evaluation for supported renderers
- Improved multithreading workflow with raw heightmap generation

## [0.4.1] - 2026-01-24

### Changed

- Gradient gizmo handles now use the gradient length for front/back controls
- Gizmo manipulation begins on drag and commits parameter changes on release
- Radial gradient safe sampling now uses influence radius and world-position distance
- Terrain composer defers rebuilds during initial setup to avoid premature rescans
- Texture layer height thresholds adjusted for rocky and rocky_terrain examples

### Fixed

- Terrain feature smoothing cache now clears on parameter commits

## [0.3.0] - 2026-01-22

### Added

- Chunked terrain rendering with per-chunk mesh instances
- LOD controls for chunked terrains (distance thresholds and scale factors)
- Terrain rebuild coordinator autoload for queued rebuilds
- Evaluation context helpers for primitives, gradients, landscapes, noise, and shapes
- GPU influence map generation shader and GPU heightmap blender helper
- Terrain heightmap/material builder helpers
- Slow mesh generation logging to surface performance hotspots
- Compatibility check to disable GPU composition on non-GPU renderers

### Changed

- Refactored terrain mesh generation for improved performance and memory usage
- Reworked terrain collision handling for chunked meshes
- Improved terrain material updates and caching
- Terrain feature nodes now evaluate via thread-safe contexts
- GPU heightmap blending now uses influence map generation and updated shader management
- Demo scene updated and renamed to terrainy_demo.tscn
- Version bumped to 0.3.0

### Fixed

- Rebuild scheduling to handle pending changes safely during chunk generation

### Performance

- Multithreaded CPU heightmap composition with precomputed influence maps
- Optimized GPU heightmap blending pipeline
- Chunked mesh generation and LOD for large terrain scalability

### Removed

- Constant terrain node

## [0.2.0] - 2026-01-18

### Added

- GPU-accelerated heightmap compositor for massive performance improvements
- GPU-accelerated heightmap modifiers system with CPU fallback
- Terrain modifiers: Smoothing, Terracing, and Height Clamping
- Threaded mesh generation for improved performance
- Influence shape system (circular, rectangular, elliptical) for terrain features
- Thread-safe height calculation methods across all terrain nodes
- Influence map caching mechanism for better performance
- New GLSL shaders for heightmap composition and modifiers

### Changed

- Refactored `influence_radius` to `influence_size` for more flexible area definitions
- Optimized terrain mesh generation with pre-calculated heights and parallel processing
- Enhanced triplanar normal mapping and weight calculations in terrain shader
- Improved terrain material blending with new BlendMode enum
- Refactored collision shape updates to utilize heightmap data
- Updated gizmo manipulation to be safer and more responsive
- Improved parameter change handling to prevent unnecessary updates during manipulation
- Enhanced GPU resource management and validation across terrain nodes
- Simplified mesh generation by removing chunked generation system
- Optimized shader code to use R32F format for reduced bandwidth
- Normalized blended normal vectors and improved texture sampling

### Fixed

- Thread safety issues in terrain generation
- Main thread blocking during mesh generation
- Signal emission during gizmo manipulation
- Normal vector blending in shader

### Performance

- Significantly reduced terrain generation time through parallel mesh building
- GPU acceleration for heightmap processing where available
- Improved memory usage with optimized heightmap formats
- Enhanced rendering performance with better texture handling and mipmaps

## [0.1.0] - 2026-01-17

### Added

- Initial release of Terrainy plugin for Godot 4
- Hybrid node-based and spatial terrain editor with live preview
- TerrainComposer node for managing terrain composition
- TerrainFeatureNode base class for all terrain features

#### Terrain Features

**Primitives**

- Hill node for creating simple elevation features
- Mountain node for peak formations
- Volcano node for crater-topped mountains
- Crater node for depression features
- Island node for isolated landmass shapes

**Gradients**

- Radial Gradient for circular height falloff
- Linear Gradient for directional height transitions
- Cone shape for pointed elevation
- Hemisphere shape for dome-like features
- Base Gradient node for custom gradient implementations

**Landscapes**

- Mountain Range for creating mountain chains
- Canyon for valley and gorge formations
- Dune Sea for desert-like sandy terrain

**Procedural Generation**

- Noise node for basic noise-based terrain
- Voronoi node for cellular patterns
- Shape node for geometric forms
- Constant node for flat elevation values

#### Features

- Real-time terrain preview with live updates
- Spatial positioning of terrain features in 3D viewport
- Custom gizmo plugin for feature visualization
- Automatic mesh generation and rebuilding
- Configurable terrain resolution (16-512)
- Adjustable terrain size
- Auto-update toggle for performance control
- TerrainMeshGenerator for efficient mesh creation

#### Texturing & Materials

- Terrain texture layer system
- Custom terrain shader with multi-layer support
- PBR material workflow compatibility

[0.7.0]: https://github.com/fabian-becker/Terrainy/releases/tag/0.7.0
[0.5.1]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.5.1
[0.5.0]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.5.0
[0.4.1]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.4.1
[0.3.0]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.3.0
[0.2.0]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.2.0
[0.1.0]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.1.0
