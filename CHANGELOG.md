# Changelog

All notable changes to the Terrainy plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.1.0
