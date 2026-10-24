# Migrating from Terrainy 0.x to 2.0

Terrainy 2.0 replaces 0.x in `addons/terrainy`: the plugin entry point, scene node types and
API names changed, and 0.x sources are no longer shipped. The two versions cannot be enabled
side by side.

If an existing project must stay on 0.x, pin the previous release (or copy the 0.x addon to a
different directory) before upgrading.

- **No automatic migration**: rebuild a 0.x scene with the recipes in `recipes.md`. 0.x scene
  nodes do not resolve against 2.0 classes.
- **No shared code**: 2.0 preloads nothing from 0.x, and class names were renamed so a project
  that mixes both addon folders cannot resolve the wrong type.
- **No water**: `WaterNode` and `get_water_level_at_world_position()` were removed. Use your
  own water and `TerrainyAPI.get_height_at()`.

## Class name changes

| 0.x | 2.0 |
|---|---|
| `TerrainComposer` | `TerrainGenerator` |
| `ScatterNode` | `TerrainScatterNode` |
| `HoleNode` | `TerrainHoleNode` |
| `TerrainGroupNode` | `TerrainFieldGroup` |
| modifiers | `Terrain*Modifier` |
| `TerrainTextureLayer` | `TerrainyTextureLayer` |
| `TerrainSurfaceContribution` | `TerrainySurfaceContribution` |

Mask nodes became mask resources.

## Node mapping

| 0.x | 2.0 |
|---|---|
| Hill / Mountain / Crater / Volcano / Island | `TerrainFieldNode` Region + profile curve (+ relief) |
| Perlin / Voronoi noise node | Global field + relief source |
| Canyon / MountainRange / DuneSea | Field with Corridor / anisotropic relief |
| Road / River / PathFeatureNode | Corridor field (+ Curve elevation origin) |
| ShapeNode / ShapeMaskNode / MaskTextureNode | `TerrainMaskRegion` / `TerrainMaskTexture` |
| HeightmapNode | `TerrainHeightmapNode` |
| WaterNode | removed — your own water + `TerrainyAPI.get_height_at()` |
| `get_water_level_at_world_position` | removed |
| `get_height_at_world_position` / `is_hole_at_world_position` / `get_features_at_world_position` | `TerrainyAPI.get_height_at` / `get_hole_at` / `get_fields_at` |
| modifier `evaluation_space` World | `space = Global` |
| TerrainPreset | your own configuration snapshots (`.tscn`) |
