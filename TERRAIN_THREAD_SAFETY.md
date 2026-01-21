# Terrain Feature Thread-Safety Status

This document summarizes **thread-safety of each terrain feature** in the current codebase. "Thread-safe" here means the height evaluation can run off the main thread **without calling scene-tree APIs** (like `to_local()`), assuming you pass precomputed `local_pos` via `get_height_at_safe()`.

> **Important:** Influence map generation currently calls `TerrainFeatureNode.get_influence_weight()`, which uses `to_local()` and is **main-thread only** for *all* features. This table is about feature height evaluation only.

## Legend
- **✅ Thread-safe**: `get_height_at_safe()` exists and uses only math + data; no scene-tree calls.
- **⚠️ Main-thread only**: `get_height_at()` uses `to_local()` and there is **no** safe override.
- **ℹ️ Conditional**: safe only if you avoid calling `get_height_at()` and use the safe path.

---

## Basic Features
| Feature | Thread-safety | Notes |
|---|---|---|
| `ConstantNode` | ⚠️ Main-thread only | Uses `to_local()` in `get_height_at()`; no safe override. |
| `ShapeNode` | ⚠️ Main-thread only | Uses `to_local()` and custom rotation per point; no safe override. |
| `PerlinNoiseNode` | ✅ Thread-safe | `get_height_at()` uses only `FastNoiseLite.get_noise_2d()` with world coords. `get_height_at_safe()` delegates to it. |
| `VoronoiNode` | ⚠️ Main-thread only | Uses `to_local()` and mutates `noise.cellular_return_type` inside `get_height_at()`. No safe override. |

## Gradient Features
| Feature | Thread-safety | Notes |
|---|---|---|
| `LinearGradientNode` | ⚠️ Main-thread only | Uses `to_local()` in `get_height_at()`; no safe override. |
| `RadialGradientNode` | ⚠️ Main-thread only | Uses `to_local()` in `get_height_at()`; no safe override. |
| `ConeNode` | ⚠️ Main-thread only | Uses `to_local()` in `get_height_at()`; no safe override. |
| `HemisphereNode` | ⚠️ Main-thread only | Uses `to_local()` in `get_height_at()`; no safe override. |

## Primitive Features
| Feature | Thread-safety | Notes |
|---|---|---|
| `HillNode` | ✅ Thread-safe | Implements `get_height_at_safe(world_pos, local_pos)` and only uses math. |
| `CraterNode` | ✅ Thread-safe | Implements `get_height_at_safe()` with only math. |
| `IslandNode` | ✅ Thread-safe | Uses `get_height_at_safe()`; noise uses world coords. |
| `VolcanoNode` | ✅ Thread-safe | Uses `get_height_at_safe()` with only math. |
| `MountainNode` | ✅ Thread-safe (ℹ️) | `get_height_at_safe()` is safe. **Optimized `generate_heightmap()` reads `global_transform`**, so keep it on main thread unless you precompute and pass transform data. |

## Landscape Features
| Feature | Thread-safety | Notes |
|---|---|---|
| `MountainRangeNode` | ✅ Thread-safe | Uses `get_height_at_safe()` and noise in world coords. |
| `CanyonNode` | ✅ Thread-safe | Uses `get_height_at_safe()` with local pos + noise in world coords. |
| `DuneSeaNode` | ✅ Thread-safe | Uses `get_height_at_safe()` with math + noise. |

## Base Nodes (for reference)
| Base | Thread-safety | Notes |
|---|---|---|
| `TerrainFeatureNode` | ✅ (base only) | Base `get_height_at()` returns 0; **real safety depends on overrides**. `get_influence_weight()` is main-thread only. |
| `NoiseNode` | ✅ (bulk path) | `generate_heightmap()` uses `FastNoiseLite.get_image()`; no `to_local()`. |
| `GradientNode`, `PrimitiveNode`, `LandscapeNode` | ✅ (data only) | Contain parameters only; safety depends on derived `get_height_at()` implementations. |

---

## Summary
- **Safe today**: primitives (hill, crater, island, volcano, mountain), landscapes (mountain range, canyon, dune sea), `PerlinNoiseNode`.
- **Not safe**: constant, shape, voronoi, all gradient nodes.
- **Global limitation**: influence map generation is main-thread only due to `to_local()`.
