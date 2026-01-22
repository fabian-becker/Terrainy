# Changelog

All notable changes to the Terrainy plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[0.3.0]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.3.0
[0.2.0]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.2.0
[0.1.0]: https://github.com/LuckyTeapot/terrainy/releases/tag/v0.1.0
