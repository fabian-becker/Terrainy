# Terrainy 2.0 — Design & Architecture (Draft v1)

Status: **implemented through M6** (2026-10-04) in `addons/terrainy`; user docs split into
[`docs/terrainy2/`](terrainy2/README.md). This document stays as the design record.

Implementation notes (deviations / clarifications decided while building):
- `terrain_resolution` counts **cells** (0.7 semantics): the vertex grid is resolution + 1, so
  256 / 256 m gives exactly 1 m cells and 2 × 2 chunks of 128 cells.
- Godot 4 brush hooks are `_forward_3d_gui_input` / `_forward_3d_draw_over_viewport`.
- MAX / MIN / AVERAGE blends lerp by the weight (continuous at the domain edge); ADD / SUBTRACT /
  MULTIPLY / REPLACE keep the 0.7 formulas. Terrace uses absolute step heights (chunk-local).
- Stroke updates of HEIGHT_ABSOLUTE layers stay stroke-local (paint is pixel-pinned), better
  than the "whole coverage bounds" worst case planned in §6.1.
- The GPU blend kernel runs on the synchronous path (local RenderingDevices are main-thread
  only; the threaded path composes on the CPU in a worker, which never blocks the frame).
  GPU field evaluation covers Region fields without relief (noise stays on the CPU, as in 0.7).
- Weight planes: R8 claim plane per palette layer (contributions + texture paint) plus an RG8
  add / suppress modulation plane per layer for ADD / SUPPRESS contributions.
Supersedes: Terrainy 0.x. The 2.0 sources replaced 0.x in `addons/terrainy`; 0.x scenes need
the migration described in `docs/terrainy2/coexistence.md`.

Decisions locked with the maintainer:

| Decision | Choice |
|---|---|
| Hardcoded features (mountain, canyon, volcano…) | Replaced by **one generic `TerrainFieldNode`**; shapes become pure configuration — no named shape nodes, **no shipped shape presets** |
| Painting | **Stack of named paint layers** (delta / absolute / smooth / texture) |
| Texture painting | **Yes** (drives the surface-contribution control pipeline) |
| Runtime painting API | **No** in 2.0 — painting is editor-only; runtime stamping is a 3.x candidate |
| Developer API | **Static `TerrainyAPI` class** (explicit terrain reference per call); no third-party node extension system in 2.0 |
| Compatibility | **Parallel addon folder `addons/terrainy`**, no shared code path, no migration promised |
| GPU | Keep CPU/GPU composition + feature eval as in 0.7, **extend GPU to paint strokes** in 2.0 |
| Corridor vs. separate node | **Unified**: `TerrainFieldNode` with `domain_kind {Region, Corridor, Global}` — one node, domain as property |
| Mask family | **All data-resource types in v1**: Region, Texture, Path (Curve3D), Slope, Elevation |
| Flatten | **`TerrainFlattenModifier` stays a node** (max terrain control without modelling) |
| External heightmaps | **Standalone `TerrainHeightmapNode`** (terrain base or blend layer) |
| Painted hole masks | **No** — painted masks never act as hole sources |
| Shipped shape presets | **None** — generic nodes only; shape knowledge lives in configuration recipes; users save their own snapshots |
| Scene hierarchy | **First-class composition tree**: siblings interfere; `space` combobox {Local, Group, Global} (§5.9) |
| Paint persistence | **Single bundle file per scene** (`.tpaint`), atomic save/load |
| Texture-paint encoding | **Per-layer weight planes** (one R8 weight plane per texture layer) |
| User config snapshots | **Small `.tscn` saved into the project** (saved `TerrainFieldNode` configs) |
| Terrain sizing | **Scale invariant**: quality is `cell_size` (**meters per cell**, the authority), `terrain_size` is the world size and `terrain_resolution` is derived (`size / cell_size`); defaults **256 m / 1 m cells**, `chunk_size` **128** cells. Resizing keeps the cell size (`preserve_cell_size`, default on) so a bigger terrain adds chunks instead of coarsening; off keeps the 0.x fixed cell count. Data layers resample on prompt (bilinear default) |
| Collision & navigation | Collision **always maintained** (0.7 behaviour, incl. exported builds); navigation **auto-rebakes debounced per chunk**; holes punch navmesh only via opt-in `punches_navigation` flag |
| Performance contract | **Engine never freezes on generation**: debounced + budgeted incremental application; full recompose runs as async tasks streamed into the apply budget (0.7 machinery). No wall-clock floors — budget is the requirement. Tested reference scale **1024² / 4 km²**; multi-terrain streaming = roadmap (design stays streaming-compatible) |
| Compose scaling | Stage 3 is full-grid O(samples) (9.1 s for a full 1024-cell recompose, 1.2 s for one field edit); **dirty-rect compose** (replay cached unit maps only inside the changed units' influence bounds + modifier halos) is the next step for multi-km grids at 1 m cells (§4.1) |
| GPU parity gating | CI gates CPU paths; GPU parity suite runs nightly/local where a `RenderingDevice` exists — still a tested contract, never silent |
| Falloff default | Fresh `domain_falloff` Curve mimics the 0.7 analytic falloff shape |
| Material authoring | **Auto-material default** (texture layers + weight planes blend, zero-config) plus `custom_material` override hook — custom shaders consume exported weight planes via a documented names/sampler contract (api.md) |
| Scatter | Mask-family-driven placement (masks + slope/elevation filters, density, seed) as **MultiMeshInstance3D per chunk** |
| Docs lifecycle | Design doc stays the RFC until M6, then splits into user docs in a **separate folder `docs/terrainy2/`** (README 2.0, api.md, paint.md, recipes.md) |

All previously open items are resolved: paint persistence (single `.tpaint` bundle per scene), texture control encoding (per-layer weight planes), user config snapshot format (small `.tscn` in the project).

---

## 1. Goals

1. **Keep the spatial editor identity**: composer root node, feature children placed and moved in the 3D viewport, live preview, isolate preview, gizmo handles.
2. **Replace bespoke landform code with configuration**: less node *types*, more node *configuration*. Terrain shapes emerge from profiles + noise + falloffs. No shipped shape presets (decided) — shape knowledge is documented as **configuration recipes**, and users save their own configuration snapshots.
3. **Make manual edits a first-class citizen**: brush painting on a paint-layer stack, surviving re-composition of procedural content by construction.
4. **Keep the mature composition core** (and its guarantees): deterministic output, input-driven dirty tracking, compose-signature caching, chunked meshing with LOD/apply-budget/threads, CPU↔GPU parity as tested contract.
5. **Rich, stable integration API for other systems** (own water systems, props, AI, gameplay): height/hole/surface queries, region sampling, field metadata, rebuild state — surfaced through a static `TerrainyAPI`.
6. **Remove water rendering entirely**: no water node, no water shader, no water carving feature. Project water is the user's system; the terrain is data they can query.

Non-goals for 2.0: third-party custom generator nodes, runtime brush stamping, scene-graph DAG editor, water interop beyond query API. (All revisitable for 3.x.)

## 2. Current-state diagnosis (what this rework fixes)

- `primitives/` + `landscapes/` are ~8 hardcoded analytic generators with one-off parameter sets (`peak_type`, `ridge_meander`, `foothill_strength`…). Each new shape costs a new class + params + gizmo + GPU kernel + tests. Their *result* is expressible as profile ∘ noise composition.
- `TerrainComposer` is a 1.7k-line orchestration monolith (chunks, collisions, navigation, textures, scatter, bake, diagnostics all hang off it).
- `plugin.gd` hardcodes 30+ `add_custom_type` preloads — no path for the gallery UX, and renaming/adding a node edits three places.
- `WaterNode` fuses generator (carve below water level) with renderer (its own mesh + shader), coupling the addon to a rendering feature and leaking water API queries (`get_water_level_at_world_position`) through the composer.
- There is **no persistent manual editing** path: the nearest building blocks are `FlattenModifier` + shape/texture masks (region effects), but they are declarative scene state, not brushable, persistent edits.

What stays from 0.x (proven, tested, carried over as copies — *no shared code path*):

- `EvaluationContext` snapshot pattern (thread-safe, immutable), influence shapes, rasterization optimizations (`rasterize_influence`, corridor rasterization).
- Composition plan + signature caching + input-driven invalidation.
- Heightmap builder, GPU kernels (feature evaluator, compositor, modifiers), chunk pipeline (LOD, apply budget, threading), collision builder, navigation builder, material builder (texture layers + surface contributions), bake exporter, diagnostics, headless test harness + CI.

## 3. Architecture overview

```
Editor tooling (addons/terrainy/editor/)
  ├─ plugin_terrainy.gd        Toolbar, gallery, brush tool host, undo, selection tracking
  ├─ brush/                     Brush tool: input, cursor overlay, options bar
  ├─ panel/                     Paint layers dock, add-node gallery dock
  └─ gizmos/                    Field domain + profile gizmos (port of gizmo_handle system)

Integration API (addons/terrainy/api/)
  └─ terrainy_api.gd            static class, per-terrain call methods, signals hub
                                (terrain registry: TerrainGenerator registers on enter tree)

Composition core (addons/terrainy/gen/)   deterministic, editor-independent, testable
  ├─ terrain_generator.gd       root node: own scene, exports, rebuild orchestration, signals
  ├─ composition_plan(.gd+.gd)  tree scan → ordered plan entries (port, renamed internals)
  ├─ field_node.gd              THE height contributor (domain: region / corridor / global)
  ├─ heightmap_field_node.gd    external heightmap import (terrain base or blend layer)
  ├─ paint/                     paint layer nodes, stroke model, dirty tracking
  ├─ modifiers/                 smooth / terrace / clamp / remap / flatten (scene-order children)
  ├─ masks/                     mask data resources referenced by modifiers & brushes
  ├─ evaluation_context.gd      immutable per-build snapshot (port)
  └─ build/                     heightmap builder, GPU evaluator/compositor/, control maps
  ├─ chunk pipeline (mesh LOD, apply budget, threads), collision builder, navigation builder
  ├─ material builder (texture layers, surface contributions, texture-paint control input)
  └─ bake exporter (bake to scene: static meshes, collision, nav)

addons/terrainy/tests/        headless suite (port of harness + 2.0 cases), run_tests entry in CI
addons/terrainy/demo/         demo scene + textures (water deleted)
```

Class-name policy: **`terrainy` must never collide with 0.x global class names** (both folder layouts can coexist in one project). Colliding 0.x names get neutral new names in 2.0 (`ScatterNode` → `TerrainScatterNode`, modifier nodes → `TerrainSmoothModifier`…, `TerrainGroupNode` → `TerrainFieldGroup`, `HoleNode` → `TerrainHoleNode`). Masks stop being node types entirely — they become **data resources** referenced by modifiers/brushes (see §5.6).

## 4. Composition pipeline (2.0)

Order of stages, mirroring 0.7's proven semantics and adding paint:

```
1  Plan scan          scene tree → ordered plan entries (fields w/ domain,
                      scatter, groups w/ scope, modifiers, masks) + structure signature
2  Feature eval       per-plan-entry maps on CPU or GPU kernels
                      (noise-based sources always CPU, as in 0.7)
3  Compose            full-grid ordered blend (Add/Subtract/Max/Min/Mult/Avg/Replace)
4  Global-space pass  fields & modifiers with space = Global, in scene order
                      (Local/Group entries already applied per-unit earlier)
5  Paint layers       ordered layer application (below)
6  Control maps       feature contributions + texture-paint layers → material control data
7  Chunks             rebuild only dirty regions: mesh(+LOD), collision, navigation
```

Invariants carried over: rebuilds are debounced; a rebuild that cannot reuse the cached signature recomposes from scratch deterministically (`noise_seed`-driven); only chunks inside the *reported world XZ influence bounds* of edited inputs are rebuilt; `is_rebuilding()` reflects queue state; `chunk_apply_budget_ms` governs frame application; headless/synchronous modes for bakes and tests. Hardened in 2.0: **generation never blocks the game/editor frame** — a full recompose may take arbitrarily long over many frames, as long as per-frame work stays inside the apply budget (this is the performance contract, replacing any wall-clock floor).

Stage-7 output policy:
- **Collision is maintained always** (0.7 behaviour — also in exported builds): per-chunk trimesh shapes with `collision_quality`/`collision_triangle_budget`; a height change inside an AABB re-bakes only the intersecting chunks, honouring the apply budget. Paint strokes on HEIGHT data trigger collision exactly like config edits.
- **Navigation re-bakes automatically, debounced** (default-on): per-chunk `NavigationRegion3D`, so a dirty rect re-bakes only the touched chunks; the existing `navigation_mesh_baked` signal and manual `bake_navigation()` (§8) stay available for games that bake on their own schedule.
- **Holes × navigation is opt-in**: `TerrainHoleNode` carries a `punches_navigation` flag (default off); when set, the hole mask removes traversable cells from the navmesh of intersecting chunks. Mesh cutting + collision cut happen regardless — a hole is always a hole visually and physically.

### 4.1 Compose cost at scale (measured)

Stage 3 blends the whole grid, so its cost is O(samples). Measured headless (CPU, no
`RenderingDevice`, `tests/perf/benchmark.gd --quick --full`, mono 4.7.2):

| grid | full rebuild | of which compose | one field edit | cached rebuild | paint stroke |
|---|---|---|---|---|---|
| 256 cells / 256 m | 0.73 s | 0.67 s | 0.31 s | 2 ms | 98 ms |
| 512 cells / 512 m | 2.4 s | 2.0 s | 0.47 s | 2 ms | 30 ms |
| 1024 cells / 2048 m | 9.1 s | 7.7 s | 1.2 s | 2 ms | 9 ms |

Chunk output is already incremental (stage 7 rebuilds only dirty chunks) and the compose
signature short-circuits no-op rebuilds, so the remaining scale cost is the *replay* of cached unit
maps over the full grid on every real edit — at 4096 cells (16.8 M samples) a slider tick costs
~19 s even though only one field changed. The next optimization is **dirty-rect compose**: keep the
previous composite, diff the plan unit signatures, and re-blend each cached unit map only inside
`unit.rect ∩ dirty`, where `dirty` is the union of the changed units' influence bounds grown by
every modifier's halo (a smoothing modifier's radius, a mask's footprint). Global-space modifiers,
paint layers and hole masks stay full-grid. Requirements: per-unit bounds in the plan, halo-aware
dirty growth, and a clip argument on `HMap` blend; correctness is "byte-identical to a full
recompose", which the harness can assert by comparing both maps.

Paint adds one new invariant: **paint composition is last-in-height-order**. Procedural recomposition (e.g. moving a mountain) never destroys or displaces a paint stroke; the stroke stays anchored in world XZ and re-composes against the new surface. (Trade-off accepted and documented: painting a ledge next to a mountain *after* the mountain moved yields a relative delta against the new terrain, which is what a sculpt-style tool implies.)

## 5. Node model

### 5.1 `TerrainGenerator` (root)

Ports `TerrainComposer`'s orchestration but stays lean by delegating everything structural to `gen/build` and `output/` helpers, and everything API-facing to `TerrainyAPI`. Exports (superset of 0.7, minus water):

- Terrain: `terrain_size` (meters per side, default **256 m**), `cell_size` (**meters per cell**, default **1 m** — derives `terrain_resolution = terrain_size / cell_size`), `preserve_cell_size` (default on: resizing keeps `cell_size`), `terrain_resolution` (cells per side, derived; setting it directly sets `cell_size`), `chunk_size` (**128** cells — the stage-7 rebuild unit), `chunk_resolution` (per-chunk mesh LOD), `min_height`/`max_height`, `base_height`. Sizing policy: resolution changes re-evaluate configs deterministically; data layers (paint bundle, heightmap source) resample on explicit prompt — bilinear default, nearest + cancel offered (§6.2)
- LOD: `enable_lod`, `lod_auto` (default on — distances derived from `cell_size`, camera FOV and viewport height), `lod_pixel_error` (**1.5** px a cell may shrink to before the next level takes over), `lod_levels` (**3**), `lod_distances` (explicit override, used with `lod_auto` off)
- Navigation: `navigation_enabled`, `navigation_mesh_template`, `navigation_triangle_budget`, `navigation_debounce_ms`. The per-chunk bake scales the template's `cell_size` to keep the tile under **1 M** rasterization cells (`navigation_builder.scaled_cell_size`), so navigation keeps working on large terrains instead of hitting Godot's 30 M voxel abort
- Pipeline: `use_gpu_composition`, `use_gpu_feature_evaluation`, `use_gpu_paint` (new), `use_multithreading`, `chunk_apply_budget_ms`, `collision_quality`/`collision_triangle_budget`, navigation options, `debug_logging`
- Texturing: `texture_layers: Array[TerrainTextureLayer]`, `texture_array_size`
- Painting: `paint_layer_grid: int` (paint grid px across XZ, default 1024), `auto_update`

Signals: `terrain_region_updated(aabb)` (replaces bare `terrain_updated`, fires per applied dirty region), `terrain_resized`, `texture_layers_changed`, `paint_layers_changed`, `navigation_mesh_baked`, plus `terrain_build_failed(message)` for diagnostics consumers.

### 5.2 `TerrainFieldNode` — the one height contributor

Replaces every primitive/landscape/noise/corridor node. Model: a **domain** (where it acts) × a **profile** (base cross-section) × a **relief stack** (noise on top) × blend. Domain kinds:

- `Region` — circle/ellipse/rect footprint with rotation + falloff curve (the 0.7 landform model)
- `Corridor` — a `Path3D` child supplies the route; width + falloff; the cross-section profile is extruded along the curve (roads, rivers, canals, dikes, trenches, canyon corridors)
- `Global` — acts on the whole terrain (baselines, noise fields, large biome shapes)

```gdscript
height(wx, wz) = profile(t) * profile_height              # t = normalized domain coordinate
               + Σ_i  weight_i * noise_i(...)
                 + profile_offset (applied per elevation_origin)
then × domain falloff × strength × mask, blended by blend_mode
```

Exports:

| Group | Export | Notes |
|---|---|---|
| Domain | `domain_kind: {Region, Corridor, Global}` | Corridor: `domain_curve: Path3D` child + `domain_width`; Region: shape/size/rotation; Global: full map |
| | `domain_falloff: Curve` | 1D curve from edge (0) to full weight; generalizes 0.7's single baked falloff style. Default content mimics the 0.7 analytic falloff (decided — visual continuity for ported configs). Gizmos: width/depth/rotation/height handles as today, plus a falloff handle |
| Profile | `profile: Curve` | Cross-section, x = edge (0) → center (1), y = 0..1 multiplier; editor draws it live. Replaces peak_type/dune/canyon curves. For corridors x = across-width |
| | `profile_height: float` | Amplitude (gizmo height handle) |
| | `profile_offset: float` + `elevation_origin: {Local, Curve, World}` | `Local` = add offset (field sits at node y) — generalizes 0.7 elevation offsets; `Curve` = follow the corridor curve's own elevation (rivers/roads); `World` = pin to absolute elevation (basin carving) |
| Relief | `relief_layers: Array[TerrainReliefSource]` | Resource list; each = `{noise: FastNoiseLite, weight: float, offset: float, blend: Add/Mul, scale: Vector2 (anisotropic frequency), rotation: float, follow_profile: bool}`. `follow_profile` warps noise along the profile; `scale`/`rotation` fix the 0.7 limitation that FastNoiseLite is always isotropic and axis-aligned (needed for dune ridges, elongated basins) |
| Blend | `blend_mode`, `strength` | Same 7 modes + semantics as 0.7 |
| Space | `space: {Local, Group, Global}` | What the field reads/evaluates against (§5.9); default `Group` |
| Mask | `mask: TerrainMaskResource` | Data resource, not a node |
| Surface | `surface_contributions: Array[TerrainSurfaceContribution]` | Ported unchanged |

`noise_seed` lives on each `TerrainReliefSource` (the generator owns determinism by stamping all sources).

**No shipped shape presets** (decided): the core ships only generic nodes; shape knowledge (profile curves, relief stacks, domain setups for hill/dune/canyon-like looks) lives in **configuration recipes** in the docs, and the demo scenes double as recipe examples. Users can save their *own* configuration snapshots from the context menu (evolution of 0.7 `TerrainPreset`; format is open question 4 in §13). Corridor rasterization (0.7's rasterized fast path, ~80× faster than per-sample evaluation) ports unchanged — a corridor is just a different domain sampler.

### 5.3 `TerrainHeightmapNode` — external heightmaps as first-class terrain

Standalone node (decided), for real-world data or DCC-authored heightmaps that should drive or blend into the terrain. It reuses the field model (domain/falloff/blend/strength/mask/modifier children all available; `Corridor` domain and the relief stack are hidden — the heightmap data *replaces* the generators).

- Source: EXR/float image, 16-bit PNG, or `Texture2D`; elevation read from R (or luminance)
- Mapping: `elevation_min/elevation_max` (meters), `source_region: Rect2` (crop), placement via domain `Region` footprint or full-map `Global`
- Interpolation (bilinear/nearest) toggle; missing-source diagnostics; participates in signature caching via file hash + mapping signature

### 5.4 Utility nodes

- `TerrainScatterNode` (renamed from `ScatterNode`): placement driven by the **same mask family + slope/elevation filters**, density + `noise_seed` — deterministic and mask-aligned by construction ("trees on grass, not on the painted road" = the same `TerrainMaskPath` that masked the road). Output: **`MultiMeshInstance3D` per chunk**, honouring dirty regions/holes; placement signature caching ported.
- `TerrainHoleNode` (renamed from `HoleNode`): kept (unique 3D influence semantics; hole mask feeds mesh cutting + collision, plus opt-in `punches_navigation` navmesh removal — §4 stage-7 policy). Painted masks are explicitly **not** hole sources — holes remain a procedural node only (decided).
- `TerrainFieldGroup` (renamed from `TerrainGroupNode`): **pure container** (no height of its own): compositional scope (`Contribute`/`Independent`), nested groups, bounds union — ported. Fields themselves also accept children (nested sculpting, §5.9).

### 5.5 Modifiers

Scene-order children under a field/heightmap/group, exactly 0.7's model, renamed to avoid collisions:

`TerrainSmoothModifier`, `TerrainTerraceModifier`, `TerrainClampModifier`, `TerrainRemapModifier`, `TerrainFlattenModifier` — flatten **stays a node** (decided; goal: maximal terrain control without modelling). Target height comes from a picked gizmo handle, an absolute elevation, or the owner unit's local level; it pulls existing terrain toward the target with falloff + strength + mask. Combined with slope/elevation masks this makes "flatten only the valleys" or "flatten slopes steeper than 35°" pure configuration.

`evaluation_space` semantics ported as the shared `space` combobox (§5.9): `Local` (evaluate the owner unit's own map), `Group` (the nearest group's composite), `Global` (whole-terrain post-compose pass — 0.7's `World` space, renamed for the shared vocabulary).

### 5.6 Masks become data

A mask **family of data resources** (all types in v1, decided), referenced by field `mask`, modifier `mask`, brush `limit_mask`:

| Resource | Content |
|---|---|
| `TerrainMaskRegion` | shape + falloff + transform (edited in the viewport with shape gizmos) |
| `TerrainMaskTexture` | texture red channel + transform |
| `TerrainMaskPath` | route + width + falloff: a `Curve3D` (pick any scene `Path3D`'s curve or a standalone curve asset), sampled as distance-to-route with the same rasterized fast path as the `Corridor` domain — the same curve can drive a river FieldNode *and*, e.g., the texture mask for its banks, staying aligned by construction |
| `TerrainMaskSlope` | min/max slope degrees, sampled from the current heightmap state |
| `TerrainMaskElevation` | height range with soft edges |

A **paintable mask** is an unsigned 8-bit paint layer of kind `Mask`, referenceable wherever a mask resource goes (painted with the Mask brush). Painted masks never act as hole sources (§5.4). This removes two node types' worth of plumbing (`ShapeMaskNode`, `TextureMaskNode`); the shape-mask editor dialog stays as the resource editor.

### 5.7 The suite at a glance

| Node | Role |
|---|---|
| `TerrainGenerator` | Root: orchestration, pipeline, output (ports `TerrainComposer`) |
| `TerrainFieldNode` | Height contributor: domain region/corridor/global × profile × relief × blend |
| `TerrainHeightmapNode` | External heightmap as terrain base or blend layer |
| `TerrainScatterNode` | Prop scatter |
| `TerrainHoleNode` | Holes / mesh cutting |
| `TerrainPaintLayer` | Paint stack entries (5 kinds, §6) |
| 5 × modifier nodes | Smooth / Terrace / Clamp / Remap / Flatten |

**7 structurally distinct node types + 5 modifiers ≈ 11** (0.7 ships 35). Verb → node mapping:

| Verb | Configuration recipe |
|---|---|
| create noise | Field, `Global` domain, flat profile + relief stack |
| raise / sink an area | Field, `Region` domain, flat profile + signed `profile_height` |
| flatten an area (procedural) | `TerrainFlattenModifier` (masked, any space) or Field, `Region` domain, flat profile, `Replace` blend |
| flatten/tweak by hand | paint stack — HEIGHT_DELTA / HEIGHT_ABSOLUTE / SMOOTH layers |
| trench | Field, `Corridor` domain, steep concave cross-section; a rectangular cut = `Region` field with slot profile |
| canyon / river / road / dike / canal / ridge | Field, `Corridor` domain: width + cross-section profile + `elevation_origin` |
| mask along a path (roads, river banks, trail limits) | `TerrainMaskPath` (curve + width + falloff) — usable as field mask, modifier mask, brush `limit_mask`, or TEXTURE paint-layer mask |
| dunes | Field profile + anisotropic relief (`scale`/`rotation`) |
| island / plateau / mesa / volcano / crater / basin | Field, `Region` domain: `profile` Curve + relief stack — configured per look |
| holes | `TerrainHoleNode` only |
| texture patch | Surface contributions or TEXTURE paint layer |

### 5.8 Removed in 2.0

- All water paths (`WaterNode`, `WaterSettings`, water evaluation context, `water_shader.gdshader`, bake-exporter water passes, composer water query, plugin water registration). Water interop is documented (§9).
- Standalone mask nodes (`ShapeMaskNode`-style), absorbed into mask resources; the shape-mask editor dialog stays as the resource editor.
- Every hardcoded landform node (mountain, canyon, volcano, island, dune sea, …) — replaced by pure field configuration; no shipped shape presets.

### 5.9 Hierarchy-aware composition (spaces)

The scene tree **is** the composition structure — no hidden feature list:

- **Siblings interfere**: children of any node (generator, field, heightmap, group) blend in tree order at that level; reordering children reorders the composition.
- **`space` combobox** — `{Global, Local, Group}` on every composable node (`TerrainFieldNode`, `TerrainHeightmapNode`, modifiers; holes/scatter keep their own scope semantics):

| space | Reads / evaluates against | Typical use |
|---|---|---|
| `Local` | the **direct parent unit's** own output, at this point of the parent's child order | nested sculpting: children of a mountain field shape *only* that mountain — parent/child keep their own space |
| `Group` | the nearest ancestor `TerrainFieldGroup`'s accumulated composite (root = the generator's running composite) | default; siblings interfere within their group level |
| `Global` | the **whole-terrain composite** | dedicated post-compose pass in scene order (0.7's World space, generalized to fields — e.g. a `Global` lake field carving against final elevation) |

- `TerrainFieldGroup` stays a pure container: bundles sibling units into one composition unit with `Contribute`/`Independent` scope (`Independent` = excluded from the outer composite, e.g. preview/reference only) + bounds union.
- Paint layers are exempt: paint is always the last-in-height-order stage (§4) and never re-enters the space hierarchy.
- Caching: a node's `space` joins its composition signature; `Global`-space entries form the plan's post-compose section (stage 4) so dirty-region rebuilds stay chunk-local.

## 6. Paint system

### 6.1 Data model

`TerrainPaintLayer` = child node under the generator (like modifiers: scene order = application order; drag to reorder).

```gdscript
enum PaintKind { HEIGHT_DELTA, HEIGHT_ABSOLUTE, SMOOTH, TEXTURE, MASK }
enum StrokeOp { RAISE, LOWER, FLATTEN, SMOOTH, STAMP_NOISE, SET_VALUE, TEXTURE, MASK }

@export var kind: PaintKind
@export var opacity: float = 1.0          # layer blend strength
@export var mask: TerrainMaskResource      # optional, same mask system as modifiers
@export var invert_mask: bool = false
@export var data: Image (stored in the scene's paint bundle, §6.2)
@export var texture_layer_id for TEXTURE kind (which texture layer's weight plane this layer drives)
```

- **Grid decoupling**: each layer stores its own grid of `paint_layer_grid` px across the generator's `terrain_size` XZ, independent from `terrain_resolution`. Changing `terrain_resolution` never rescales paint layers; changing `terrain_size` does (with an explicit resample prompt).
- **HEIGHT_DELTA** (FORMAT_RF): signed per-pixel height delta added to the composed map. Composition is chunk-local (delta layers participate in dirty-region math directly).
- **HEIGHT_ABSOLUTE** (FORMAT_RF + coverage in alpha): where coverage > 0, output height is pinned to the stored value, replacing procedural content under it. Any change to an absolute layer marks its whole region — chunks intersecting *the layer's coverage bounds* rebuild (worst-case full map). Use sparingly; documented.
- **SMOOTH**: per-pixel strength 0..1; composites as a localized gaussian blend toward local surroundings (kernel over stroke region).
- **TEXTURE**: **per-layer weight planes** (decided) — each texture layer owns its own R8 weight plane (0..1); strokes write into the assigned plane with the brush falloff, giving smooth N-layer blending per pixel. Stage 6 combines procedural surface contributions and TEXTURE paint layers into the same planes; paint applies in layer order and wins over contributions where painted (documented override). Contribution-owned layer entries are appended to the generator's palette automatically when first painted.
- **MASK**: unsigned coverage image (R8), referenced as a `TerrainMaskResource` by modifiers/brushes.

### 6.2 Persistence

- **Single bundle file per scene** (decided): every generator's paint layers of a scene live in one `res://<scenename>_terrainy.tpaint` — a custom `TerrainPaintBundle` resource with one section per generator listing its layers (`layer_uid`, `name`, `kind`, params, `revision`, data images). The `.tscn` stores only the bundle reference.
- Atomic save/load: no orphan layer files; moving, copying or deleting a scene carries its terrain edits along. Multiple editors stay consistent through the shared file.
- Trade-off (documented): any stroke commit rewrites the whole bundle on disk. Saves happen on **stroke commit, debounced** — never per stamp. Bundle size = Σ layer images on the paint grid; demo scenes keep few layers.
- Layers record a `revision` counter; it joins the compose signature like feature revisions do today.

### 6.3 Brush tool (editor)

An `EditorPlugin` scene tool (spatial input forwarding, `_forward_spatial_gui_input(vcam, event)` / `_forward_spatial_draw_over_viewport(control)` — verified available in Godot 4.x, and the project targets 4.7):

- Toolbar: brush toggles appear next to *Rebuild/Bake* buttons; picking a brush switches the editor into brush mode (standard Godot tool pattern).
- Target selection: active paint layer (from the layers panel; creates the layer if none).
- Brush set v1 (**height + texture ops shipped on day one**): `Raise/Lower` (direction = Ctrl), `Flatten` (target height = terrain height under first click; Shift = absolute world height input), `Smooth`, `Stamp Noise` (relief source stamp, seeded), `Texture` (pick palette layer), `Set Mask`.
- Stroke model: sample cursor → emit `BrushStamp {op, pos, radius, falloff: Curve, strength}` list per input frame; stamps feed both the CPU path and the GPU kernel queue.
- Cursor overlay: projected ring + falloff gradient + strength preview in the viewport; brush radius adjustable with `[`/`]` shortcut and gizmo handle.
- Undo: one `EditorUndoRedoManager` action per stroke commit (stores the affected-layer raster rect before/after — rectangular diff, cheap for stroke-sized regions).
- No runtime API in 2.0. Stamps/strokes are internal; a public stamp surface is the first 3.x candidate.

### 6.4 Composition & dirty tracking

- Paint stage input: composed map from stages 1–4, ordered layer list.
- Brush strokes mark the affected rect (in layer-grid px) → generator invalidates only the intersecting chunks → stages 5–7 run locally where possible (delta/smooth/texture/mask kinds), or over the layer's dirty AABB (absolute).
- GPU path: active stamps are applied by a compute kernel (`paint_apply.glsl`) onto the layer texture; results are read back into the CPU image for persistence and chunk composition. CPU path mirrors the same stamp math for parity tests and the Compatibility renderer.

## 7. GPU scope in 2.0

| Kernel set | Change |
|---|---|
| `feature_evaluator`, `heightmap_compositor`, `heightmap_modifiers`, `influence_generator` | Ported (renamed, no behaviour change); noise-family sources stay CPU with kernel unavailability documented |
| `paint_apply` (new) | Applies stamp lists to paint layer textures (delta/absolute/smooth/texture writes) |
| `paint_control` (new, small) | Rasterizes TEXTURE-layer strokes into per-layer weight planes |

Parity rules inherited from 0.7: CPU evaluation is the source of truth; every GPU op has a CPU twin and a parity test (extend `test_gpu_parity.gd` with stamp/case fixtures); any GPU-disabled path silently uses CPU (never breaks a build). Enforcement (decided): **CI gates CPU paths only**; the GPU parity suite runs on dev machines / as a nightly local script where a `RenderingDevice` exists — it stays a tested contract without paid GPU runners.

## 8. TerrainyAPI (static, per-terrain explicit)

```gdscript
# static class; TerrainGenerator registers itself on _ready and notifies on _exit_tree
TerrainyAPI.register(terrain: TerrainGenerator) / unregister(...)

# queries — terrain argument explicit (multiple generators supported)
TerrainyAPI.get_height_at(terrain, world_pos: Vector3) -> float         # bilinear, base_height incl.
TerrainyAPI.get_normal_at(terrain, world_pos: Vector3, eps: float=1.0) -> Vector3
TerrainyAPI.get_hole_at(terrain, world_pos: Vector3) -> bool
TerrainyAPI.get_paint_at(terrain, layer: TerrainPaintLayer, world_pos: Vector3) -> float
TerrainyAPI.get_texture_blend_at(terrain, world_pos: Vector3) -> Dictionary # layer_id -> weight
TerrainyAPI.get_fields_at(terrain, world_pos: Vector3) -> Array[TerrainFieldNode]
TerrainyAPI.sample_region(terrain, rect: Rect2, resolution: Vector2i) -> Heightfield2D  # async task, get_heightmap_at
TerrainyAPI.get_painted_region_aabb(terrain, layers: Array[TerrainPaintLayer]) -> AABB
TerrainyAPI.is_rebuilding(terrain) -> bool
TerrainyAPI.wait_for_settle(terrain) -> Error                            # awaitable coroutine
TerrainyAPI.get_diagnostics(terrain) -> Dictionary

# signals (hub — instance-carried, statically accessible)
TerrainyAPI.signals.region_changed(terrain, aabb: AABB)
TerrainyAPI.signals.terrain_removed(terrain)
TerrainyAPI.signals.terrain_added(terrain)
```

Notes:

- 0.x's `get_features_at_world_position`, `get_height_at_world_position`, `is_hole_at_world_position` carry over renamed; `get_water_level_at_world_position` is gone (§9).
- Runtime *editing* stays declarative in 2.0 (change field configuration in code → rebuild); brush stamping is not exposed. This keeps the 2.0 surface small, honest, and testable.

## 9. Water interop guidance (for the docs)

```gdscript
# The game's own water system owns water rendering. Terrainy 2.0 supplies data:
var ground: float = TerrainyAPI.get_height_at(terrain, world_position)
var submerged: bool = world_position.y < water_level and ground < water_level
# Basins/river beds: corridor/field configs carve below a level; the water plane
# at that level reads get_height_at() for shore snapping and debris placement.
```

## 10. Project layout & compatibility rules

- New addon: `addons/terrainy/` with its own `plugin.cfg` ("Terrainy 2"), `plugin_terrainy.gd`, demo, tests, CI test script. 0.x stays intact and untouched.
- No `res://addons/terrainy/…` preloads in terrainy (verbatim "no shared code path"); subsystems are copied and adapted, proven logic kept.
- Every global class name is checked against the 0.x namespace (`class_name` grep) before landing — the §5 renames enforce it.
- Both plugins enabled simultaneously is supported but discouraged (two toolbars); docs recommend disabling 0.x on new scenes.

## 11. Testing & CI

- Port the headless harness unchanged (it is plugin-agnostic by design) under `addons/terrainy/tests/`.
- Repurpose 0.x case families to the new model:
  - `test_field_composition` (domain × profile × relief × blend matrix, replaces primitive/landscape cases)
  - `test_corridor_domain` (profile configurations, elevation origins; corridor rasterization parity)
  - `test_paint_layers` (kinds, ordering, determinism, revision signature, dirty rects, resample on size change, `.tpaint` bundle round-trip)
  - `test_paint_gpu_parity` (stamp lists: CPU vs GPU, all ops, Compatibility fallback)
  - `test_api` (static registry, query semantics, region sampling, wait_for_settle)
  - `test_hierarchy_composition` (sibling order, nested Local spaces, Group scoping, Global post-compose pass, space in signature)
  - ported: masks/modifiers/groups, chunks, collision, bake, navigation, scatter, world queries
- CI: run terrainy suite alongside the 0.x suite until 2.0 ships.

## 12. Milestones

| M | Scope | Acceptance |
|---|---|---|
| **M0** Scaffold | `addons/terrainy` plugin skeleton, `TerrainGenerator` minimal compose (one field, one chunk set), test harness copy, demo scene shell | suite green in CI; spatial flow: add generator → add field → move it → live preview |
| **M1** Model | `TerrainFieldNode` (Region + Global domains: profile + relief + falloff curve, space combobox) + masks-as-data + all 5 modifiers + groups + nested-field composition | configuration-driven field parity vs 0.x primitive cases where comparable; sibling order + Local/Group/Global space matrix verified; signature caching works |
| **M2** Output | Chunk pipeline, collision, navigation, material builder + texture layers + surface contributions, bake, `TerrainyAPI` static class | API queries verified by tests; bake round-trip stable |
| **M3** Corridor domain + heightmap + scatter + holes | `Corridor` domain (+ `Curve` elevation origin), corridor rasterization port, `TerrainHeightmapNode`, ScatterNode port, HoleNode port | corridor rasterization speed parity; road/river configuration equivalence; heightmap round-trip test |
| **M4** Paint core | Layer stack + composition stage + dirty rects + persistence + brush tool v1 (height ops) + undo | deterministic recomposition; stroke → only affected chunks rebuild; undo round-trip |
| **M5** Paint GPU + texture | texture painting via per-layer weight planes into the control pipeline, GPU stamp kernels + parity | parity green; Compatibility renderer falls back gracefully |
| **M6** Polish | Configuration-recipes chapter (profile/relief/domain recipes for common looks), node gallery dock, water interop doc, diagnostics polish, docs split into `docs/terrainy2/` (README 2.0, api.md incl. custom-material weight-plane contract, paint.md, recipes.md, 0.x coexistence guide) | docs + demo cover every shipped node |

## 13. Risks & open questions

| Risk | Mitigation |
|---|---|
| Whole-bundle rewrite churn on stroke commits | debounced save on commit; document bundle size math; demo scenes keep few layers |
| Absolute layers cost chunk locality | documented cost; coverage-bounds dirtying; discourage heavy use |
| GPU stroke readback stalls | read back stroke region only, on stroke commit (not every frame); budgeted apply reuse |
| Brush UX depth (radius/pressure/smoothing ramps) | v1 scoped ops; UX polish track in M6 with user testing |
| Two long-lived addons diverge (docs/tests drift) | each addon ships its own full docs + tests; README 2.0 cross-references 0.x explicitly as legacy |

No open questions. Every item from earlier rounds is resolved and recorded in §1's locked-decisions table (paint persistence, texture encoding, config snapshots, sizing defaults, collision/navigation policy, performance contract, GPU parity gating, falloff default).