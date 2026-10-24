# Changelog

All notable changes to the Terrainy plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0.html),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Terrainy 2 (`addons/terrainy`, 2.0.0-dev)**: rework per `docs/terrainy2-design.md`, no shared code with 0.x and no colliding class names. This release replaces Terrainy 0.x in `addons/terrainy`; see the migration table in `docs/terrainy2/coexistence.md`. One generic `TerrainFieldNode` (Region / Corridor / Global domain × profile curve × relief stack × blend) replaces the hardcoded landform nodes; `TerrainHeightmapNode`, `TerrainFieldGroup`, five `Terrain*Modifier` nodes, `TerrainHoleNode` (opt-in `punches_navigation`), `TerrainScatterNode` (MultiMesh per chunk); masks are data resources (region, texture, path, slope, elevation, paint). Hierarchy-aware composition with `space` Local / Group / Global. Paint stack (`TerrainPaintLayer`: height delta / absolute / smooth / texture / mask) with an editor brush tool, per-stroke undo and a single atomic `.tpaint` bundle per scene. Stage-6 per-layer R8 weight planes drive the auto material and a documented custom-material contract. Static `TerrainyAPI` (height / normal / hole / paint / texture blend / fields queries, region sampling, settle, signal hub). Worker-thread composition with signature caching and budgeted per-chunk application; collision always maintained; per-chunk debounced navigation. GPU field / blend / paint kernels with CPU twins and a parity suite. No water. User docs in `docs/terrainy2/`, demo scene, own headless test suite in CI

- **Compositional terrain hierarchy**: `TerrainGroupNode` composes child features with `Contribute` scope into one internal landform that blends into the terrain as a single feature. Children default to `Independent`, so existing scenes keep their exact behaviour
- **Modifier nodes** (`SmoothingModifier`, `TerracingModifier`, `HeightClampModifier`, `RemapRangeModifier`, `FlattenModifier`) as ordered scene-tree children under the feature or group they modify. Scene order is the application order; `evaluation_space` selects the target (`Local` feature output, `Group` composited output, `World` final map). World modifiers run in a dedicated composer pass in scene order, so constraints hold on the finished terrain no matter what the features did; modifier edits are covered by the compose-signature cache
- **Elevation offsets on primitives**: `elevation_offset` shifts a generator after shape generation, in `Local` (add) or `World` (pin to a world elevation regardless of node position) space; offset features stay on the CPU (no kernel parity)
- **Mask nodes** (`ShapeMaskNode`, `TextureMaskNode`): pure weight fields limiting where a modifier applies, referenced via the modifier's `mask` NodePath. The modifier's influence and the mask weight are multiplied; `invert` flips a mask. Mask revisions join the compose signature
- **Path features** (`RoadNode`, `RiverNode`): `Curve3D` corridor features with baked world-space polyline evaluation. A road pins the corridor to the curve elevation; a river carves its bed `depth` units below. Paths use the custom CPU influence path (distance-to-polyline); no GPU kernel is claimed
- **`BlendMode.REPLACE`**: lerps the current terrain toward a feature's height by weight (roads, riverbeds); implemented in the CPU blend and the GPU compositor kernel
- **`TerrainPreset` resource**: reusable feature subtree (packed scene + default transform), instantiated under a composer through `preset.instantiate(parent)`
- **Isolate preview**: `preview_isolate_node` on `TerrainComposer` temporarily previews only one subtree with everything else flat; part of the compose signature, cleared to restore the full terrain
- **`respect_layer_gate` on surface contributions**: a contribution can now be scaled by the target layer's own height/slope blend instead of being driven by the feature's influence alone, so a layer only paints where it would apply anyway. Two contributions with complementary slope ranges (rock on the steep cut, sand on the flat road bed) then select the surface inside one corridor, while the default (`off`) keeps the influence-driven `Replace`/`Add`/`Suppress` behaviour. The flag travels to the shader packed next to the mode in the control payload, and the sampled influence is multiplied by the layer's analytic weight before any mode is applied
- **Node-driven surface texturing**: every feature node carries a `surface_contributions` array of `TerrainSurfaceContribution` resources (target `TerrainTextureLayer`, `Replace`/`Add`/`Suppress` mode, `strength`, optional `respect_layer_gate`), so a node can override what the ground looks like inside its influence - a `RoadNode` laying grit along its corridor, a feature suppressing grass where it sits. The feature's influence map is reused as the control map (one `control_maps` slice per contributing feature, up to `MAX_SURFACE_CONTROLS = 16`), a layer is appended to the composer's palette if it is not already there, and a contribution edit reuses the cached control map instead of recomposing heights. Contributions are collected from every feature of the composition plan, group children included, so a `RoadNode` nested in a `TerrainGroupNode` still paints its own grit although the group consumes its geometry. `TextureAreaNode` is the ready-made zero-height feature for "this patch has different textures"

### Changed

- **Terrain sizing is scale invariant**: quality is now expressed in meters per cell (`cell_size`), and `terrain_resolution` is derived from it (`terrain_size / cell_size`). Growing `terrain_size` keeps the cell size (`preserve_cell_size`, default on) instead of silently stretching the grid, so a 4 km terrain gets 4096 cells at 1 m rather than 256 cells at 16 m; the chunk count grows, the per-chunk cost does not. Setting `terrain_resolution` directly still works and writes `cell_size` back, and `preserve_cell_size = false` restores the 0.x fixed-cell-count behaviour. `MAX_RESOLUTION` (4096 cells) is now reported when a requested cell size cannot be represented instead of being clamped silently
- **LOD switch distances are derived instead of fixed**: `lod_auto` (default on) computes the distance where one cell covers `lod_pixel_error` pixels of the viewport from `cell_size`, the camera FOV and the viewport height, for `lod_levels` levels. The old fixed 384/768/1536 m distances meant every chunk of a large terrain was immediately pushed to the coarsest level (32-128 m triangles); chunk distances are also measured to the nearest point of the chunk rect instead of its centre, so a chunk no longer coarsens while the camera is still inside it. `lod_distances` remains as an explicit override (`lod_auto = false`)
- **Paths follow a `Path3D` child's curve**: `RoadNode`/`RiverNode` no longer expose a `curve` property. Add a `Path3D` child and edit its curve in the viewport (the standard Godot workflow); the bake uses the child's transform
- **Path influence maps are rasterised instead of scanned**: a path's influence map was built by walking every pixel of the corridor's *axis-aligned bounding box* (~194 616 px on the demo road) and running a distance scan over all 65 baked curve points per pixel, although the corridor only covers a thin ribbon inside that box. Each segment now visits only the pixels within `width / 2` of itself and writes the maximum weight found. That is exactly the per-pixel scan's result, because the corridor weight is a non-increasing function of the distance to the centreline (`f(min_i d_i) == max_i f(d_i)`). Output is bit-identical (verified on 6 synthetic geometries x 3 grids and on the demo road: 0 differing pixels) and **61.7x faster** (10 968 ms -> 178 ms on the demo road). The new `TerrainFeatureNode.rasterize_influence()` hook lets any feature opt in; the generic per-pixel scan remains the default and is still used for masked paths and degenerate one-point paths
- **Path heightmaps are rasterised too**: the feature heightmap of a road or river is a corridor profile (`elevation * weight` / `elevation - depth`), yet it was generated by the same full-grid walk, paying a distance scan over every baked point for all 1 050 625 pixels *and* a second scan for the curve elevation of the pixels inside the ribbon — 19 900 ms for the demo road. `rasterize_corridor_height()` walks each segment's pixel window once, tracking the two minima the per-pixel pass resolves separately (weight from the XZ distance, elevation from the squared XZ distance, both in 64-bit) and calls into the feature's own `_get_path_height_for_raster()` profile. Bit-identical (**80.5x**: 19 900 ms -> 247 ms) with `TerrainFeatureNode.rasterize_heightmap()` as the opt-in hook

### Fixed

- **Chunk borders no longer show a shading seam**: the mesh generator took one-sided height differences at every chunk edge, so the same world position got a different normal depending on which chunk drew it (and LOD meshes computed normals from the reduced heightmap, so the lighting popped when a chunk changed level). Each chunk mesh is now built with the surrounding one-sample border as its normal source (`MeshGen.generate_surface_arrays(normal_source, normal_stride, normal_offset)`), so the central difference reaches into the neighbour's samples: neighbouring chunks and chunks at different LOD levels agree exactly at their shared samples, and the slope always spans one full-resolution sample so a coarse LOD shades like the fine mesh. Covered by `tests/cases/test_mesh_seams.gd`
- **Navigation baking aborted on large terrains**: the per-chunk bake used the `NavigationMesh` defaults (0.25 m cells) regardless of how big the chunk was, so a chunk of a large terrain needed tens of millions of rasterization cells for one tile and Godot aborted the bake ("Source geometry is suspiciously big for the current Cell Size and Cell Height", 0 polys) above 30 M voxels. The builder now fits the rasterization to the chunk (`NavigationBuilder.scaled_cell_size`), keeping every tile under 1 M cells (roughly a second per tile at any scale), snaps `border_size` to whole cells (Godot warns about the precision loss otherwise) and keeps `edge_max_error` proportional to the cell size, which also removes the "more than 2 edges tried to occupy the same rasterization space" warnings that coarse bakes emitted. A tile that still exceeds 25 M cells reports a Terrainy error naming the chunk instead of letting the engine abort mid-queue
- **Palette albedo tints and textures render washed out**: albedo colors authored as sRGB (every `Color` picked in the editor, e.g. a grass `0.32 0.5 0.22`) were uploaded raw into `layer_color_normal` and - for texture albedos - raw into the texture array, but the renderer lights the scene in linear space and only converts `Color` values on `source_color` uniforms, not packed vector uploads or plain sampler data. The unconverted sRGB values were therefore treated as linear and displayed roughly twice as bright and desaturated. The auto material now linearizes `albedo_color` (`.w = normal_strength` stays raw) and runs `Image.srgb_to_linear()` over the albedo texture slices (after the RGBA8/mipmap pipeline, so the other plane channels are untouched), matching what the engine does for `source_color` textures
- **A contributed texture layer no longer covers the whole terrain**: a `TerrainSurfaceContribution` whose `texture_layer` is not listed in `TerrainComposer.texture_layers` has that layer appended to the material's palette so it can be sampled - but the layer was treated like a normal palette layer on top of that, so an ungated layer (the default: no height/slope limits) blended across every fragment of the terrain and the override simply picked one share of it everywhere. Such a layer is now flagged as contribution-owned (`layer_extra_flags[i].w`) and its analytic weight is gated by the coverage of its own controls, so it shows exactly where a contribution paints it; the fallback that shows a layer where nothing contributes now prefers a layer the terrain lists itself. Listing the layer in `texture_layers` as well keeps the global blend, and promoting a contributed layer into the palette rebuilds the material through the surface signature
- **`Replace` contributions really take the surface over**: a `Replace` contribution used to raise the target layer's raw weight, which the Normal-mode normalization of every `Normal` layer immediately diluted - a full-strength override along a road corridor ended up as one share of the palette mix and was often invisible. `Replace` controls now accumulate a `takeover` claim per layer, which is settled after normalization (`weights[i] = weights[i] * keep + takeover[i] * claim_share`): the claim takes its share away from the other layers, and it counts as contributing surface so a takeover-only fragment does not fall through to the first-layer fallback. Claims that compete for the same fragment - two `Replace` contributions of one feature, say - share the claimed surface in proportion to their strength instead of summing past it and over-brightening the result
- **A feature with several surface contributions no longer reports a missing control map**: `TerrainMaterialBuilder` validated the uploaded controls by comparing their count with the number of control maps, but the contributions of one feature all sample that feature's single influence map, so a node with two contributions was counted as "2 surface contributions but only 1 control maps were supplied" on every rebuild while rendering correctly. The check now validates the map slice each contribution references, which is what the shader indexes
- **Editing a feature no longer throws away an influence map that did not change**: `invalidate_influence_if_changed()` compared each influence cache key unconditionally, but neither cache is written for every feature - a hole feature only ever fills the hole cache, a regular feature only the influence cache. The missing entry therefore read as a change, so any parameter edit dropped the cached influence map (and a hole edit even dropped the hole map) that the function exists to preserve. Each cache is now compared only when it holds an entry for the feature
- **A curve edit now rebuilds the chunks the path actually moved in**: the composer sized the dirty region of a changed feature from its `influence_size` box around the node origin. A road or river whose curve runs away from its node (the normal case - only the first control point tends to sit at the node) therefore marked the wrong chunks: the heightmap *was* re-composed (seconds of work) but no chunk covering the changed ground was rebuilt, so the editor froze and the viewport did not change until a full rebuild. Features now report a canonical world-space XZ `get_terrain_influence_bounds()` - the shape box by default, a path's curve corridor (`width / 2` around the baked curve) for `RoadNode`/`RiverNode`, and the union of the contributing children for a `TerrainGroupNode` - and the composer and the scatter manager both use it. Bounds may be over-reported but never under-reported, so no edit can miss a chunk again
- **A curve edit no longer reuses the previous curve's influence map**: `_get_influence_cache_key()` keyed the influence cache on the node's transform box, shape, falloff, rotation and mask - but not on the geometry a path's influence actually depends on. Editing a `Path3D` child's curve therefore reused the pre-edit corridor influence map: the terrain kept the old road shape (on top of the new heightmap), and the wasted compose only showed up as a long freeze. `TerrainFeatureNode.get_influence_cache_signature()` (empty by default) is now part of both the per-feature and the group influence cache key, and `PathFeatureNode` reports the baked polyline - point count, mm-rounded geometry and `width` (a path's `width` was missing from the key for the same reason)
- **Modifier nodes under a group's contributing child are applied**: a group's contributing children were generated without their own modifier-child stacks, so a `FlattenModifier` (or any LOCAL/GROUP modifier) placed under a child feature silently did nothing while the same node set to `World` worked. The builder now runs the child's stack on its output before it blends into the group, and a modifier edit propagates up so the next rebuild picks it up
- **Group children stay connected to the group after auto-migration**: a feature saved as `Independent` under a `TerrainGroupNode` is migrated to `Contribute` when the group enters the tree, but the group subscribed to its children *before* that migration, so the child was consumed by the group and connected to nobody. Editing it - for example dragging a `RoadNode`/`RiverNode`'s `Path3D` child curve, or changing any exported parameter - never dirtied the composer, which replayed its cached composed heightmap until a manual full rebuild. The group now migrates first and subscribes afterwards, tracks every nearest-ancestor feature child (contributing or not) and drops the subscriptions of children that leave
- **Group structure changes rescan the composition plan**: flipping a child's `composition_scope` at runtime, or adding/moving a child in or out of a group, changed what the group consumes without re-running the plan scan. The composer now detects that its plan no longer matches the tree and rescans before rebuilding, so a promoted child cannot keep blending twice (and a demoted one can no longer disappear)
- **`ScatterNode` instance clamps can be edited again**: `min_instances` / `max_instances` were applied by a helper that wrote the properties from another function, so GDScript re-entered both setters and the recursion guard silently discarded the writes. Neither bound could leave its declaration default (0 / 2500), from the inspector or from a scene file, so a scatter whose clamps drive placement looked like it was not scattering at all. Each setter now stores its own bound and asks the other setter to follow, with the guard limiting the cross-bound edit to a single parameter-change commit
- **A scatter scene without a `MeshInstance3D` still shows its instances**: MultiMesh mode built no `MultiMesh` for such a scene (a CSG-based prop, for example) and reported nothing, so the scatter silently stayed empty. `_build_scatter_multimesh()` now reports whether it produced a `MultiMesh`, and the manager falls back to individual instances with a warning instead
- **A `ScatterNode` under a consumed feature stays in the composition plan**: the plan scan of a group's contributing child stopped at the child itself, so a plain contributing feature's descendants were dropped instead of staying top-level entries the way the previous flat scan kept them (a `ScatterNode` under a `MountainNode` inside a group disappeared). The scan now continues into a contributing child that is not a group

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
