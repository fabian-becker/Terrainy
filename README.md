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

## Configuration

The `TerrainComposer` node provides several options:
- **Terrain Size**: Overall dimensions of the terrain mesh
- **Resolution**: Detail level (16-512)
- **Auto Update**: Enable/disable automatic rebuilding
- **Performance**: Threading, chunking, and parallel processing options

## Version

0.1.0

## License

MIT License - see [LICENSE](LICENSE) for details

## Author

LuckyTeapot
