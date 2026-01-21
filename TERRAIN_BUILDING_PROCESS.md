# Terrainy Terrain Generation: Build Pipeline

This document explains how the Terrainy plugin builds terrain at runtime/editor time, based on the current implementation in this workspace.

## 1) Entry Point: `TerrainComposer`
The `TerrainComposer` node is the orchestrator. It scans child nodes for `TerrainFeatureNode` instances, composes a final heightmap, generates a mesh, and updates materials/collision.

**Key file:** `addons/terrainy/nodes/terrain_composer.gd`

**High-level flow (triggered on change or `rebuild_terrain()`):**
1. **Scan features**: `_scan_features()` walks the node tree, collects `TerrainFeatureNode` children, and connects to their `parameters_changed` signals.
2. **Compute bounds & resolution**: Uses `terrain_size` and `resolution` to define the world bounds and heightmap resolution (`resolution + 1` samples per axis).
3. **Compose heightmap**: Delegates to `TerrainHeightmapBuilder.compose(...)`.
4. **Generate mesh**: Runs `TerrainMeshGenerator.generate_from_heightmap(...)` on a background thread.
5. **Apply material**: Uses `TerrainMaterialBuilder.update_material(...)`.
6. **Build collision**: Generates a `HeightMapShape3D` from the same heightmap.

## 2) Feature Nodes: `TerrainFeatureNode` and Derivatives
Each feature produces a heightmap layer. Base logic is in `TerrainFeatureNode`:

**Key file:** `addons/terrainy/nodes/terrain_feature_node.gd`

### Height Generation
- `generate_heightmap(resolution, terrain_bounds)` iterates over the heightmap grid and calls `get_height_at(world_pos)` per pixel.
- Derived nodes override `get_height_at` to define the actual terrain shape (e.g., noise, primitives, gradients).

**Example:** Perlin noise feature
- File: `addons/terrainy/nodes/basic/noise_terrain_node.gd`
- `get_height_at` uses `FastNoiseLite` to generate a height, then scales by `amplitude`.

### Modifiers (per-feature)
Modifiers can be applied to a feature’s heightmap after the raw values are generated:
- Smoothing (light/medium/heavy)
- Terracing (levels + smoothness)
- Min/Max clamping

These modifiers are applied **GPU-first** via `GpuHeightmapModifier` and fall back to CPU when needed.

**Key file:** `addons/terrainy/helpers/gpu_heightmap_modifier.gd`

## 3) Heightmap Composition: `TerrainHeightmapBuilder`
This helper composes all feature heightmaps into a single final heightmap.

**Key file:** `addons/terrainy/helpers/terrain_heightmap_builder.gd`

### Steps
1. **Heightmap caching**: Feature heightmaps are cached per feature. Dirty features regenerate.
2. **Influence maps**: Each feature gets an influence map (weight per pixel) based on its influence shape, size, and falloff.
3. **Blend**: All feature heightmaps are blended into a final heightmap using the feature’s blend mode and strength.

### GPU vs CPU
- If GPU composition is enabled and supported, `GpuHeightmapBlender` is used.
- If unavailable, a CPU path blends pixel-by-pixel in GDScript.

**GPU files:**
- `addons/terrainy/helpers/gpu_heightmap_blender.gd`
- Shaders: `addons/terrainy/shaders/heightmap_compositor.glsl`, `addons/terrainy/shaders/influence_generator.glsl`

## 4) Mesh Generation: `TerrainMeshGenerator`
Once the final heightmap is ready, the mesh is generated from the heightmap in a background thread.

**Key file:** `addons/terrainy/helpers/terrain_mesh_generator.gd`

### Process
- Reads the heightmap’s float values.
- Builds vertices, normals, UVs, and indices for a grid mesh.
- Centers the mesh around $(0,0)$ in XZ using `terrain_size`.

## 5) Materials: `TerrainMaterialBuilder`
After the mesh is set, the material is updated.

**Key file:** `addons/terrainy/helpers/terrain_material_builder.gd`

### Texture Layers
- `TerrainTextureLayer` resources define height/slope blending and PBR inputs.
- Layers are packed into arrays and sent to the shader (`terrain_material.gdshader`).
- If a custom material is provided, it is used instead.

## 6) Collision Generation
Collision is built from the final heightmap using `HeightMapShape3D`:
- Each heightmap pixel becomes a height sample.
- The collision shape is scaled to match `terrain_size`.

**Key file:** `addons/terrainy/nodes/terrain_composer.gd` (method `_update_collision`)

## 7) Rebuild Triggers
Terrain rebuilds occur when:
- A feature node’s parameters change.
- The `TerrainComposer` settings change (size, resolution, base height, GPU toggle, etc.).
- Children are added/removed in the editor.

Changes are debounced in the editor to avoid excessive rebuilds.

## Pipeline Summary
1. Collect `TerrainFeatureNode` children.
2. Generate/refresh per-feature heightmaps (with modifiers).
3. Generate influence maps per feature.
4. Blend all layers into a final heightmap (GPU if possible).
5. Generate mesh from final heightmap (threaded).
6. Apply material and texture layers.
7. Build collision from the heightmap.

## Where to Look Next
- Feature implementations: `addons/terrainy/nodes/**`
- Shaders: `addons/terrainy/shaders/**`
- Texture layer resource: `addons/terrainy/resources/terrain_texture_layer.gd`
