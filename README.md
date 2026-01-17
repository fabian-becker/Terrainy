# Terrainy

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

## Author

LuckyTeapot
