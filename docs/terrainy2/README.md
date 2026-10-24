# Terrainy 2

Configuration-driven spatial terrain editor for Godot 4.7. Terrainy 2 is a **parallel addon**
(`addons/terrainy`) next to Terrainy 0.x (`addons/terrainy`): no shared code, no colliding
class names, no migration promised. See [coexistence.md](coexistence.md).

- One generic height node (`TerrainFieldNode`) instead of 30+ hardcoded landform nodes.
  Mountains, canyons, rivers, roads, dunes, islands... are configurations: [recipes.md](recipes.md).
- The scene tree **is** the composition: siblings blend in tree order, `space` (Local / Group /
  Global) decides what a node reads.
- A stack of **paint layers** (height delta / absolute / smooth / texture / mask) that survives
  procedural recomposition: [paint.md](paint.md).
- A static integration API, `TerrainyAPI`, for water, props, AI and gameplay: [api.md](api.md).
- No water rendering: water is your system, the terrain is data you can query
  ([api.md#water-interop](api.md#water-interop)).

## Quick start

1. Enable **Terrainy 2** in *Project Settings → Plugins* (disable Terrainy 0.x for new scenes;
   both at once works but shows two toolbars).
2. Add a `TerrainGenerator` (gallery dock *Terrainy Nodes* → *Generator*, or *Add Node*).
   Defaults: 256 m × 256 m, 256 cells (1 m cells), 128-cell chunks.
3. Select the generator and add a *Field (Region)*. Move it in the viewport; drag the gizmo
   handles (width, depth, height, falloff). The terrain updates live.
4. Give the field a `profile` curve (edge → center) and a relief layer for noise.
5. Add `texture_layers` to the generator (height/slope blended auto material).
6. Toggle *Brush* in the 3D toolbar, pick an op in the *Terrainy Paint* dock and paint.
7. Save the scene: paint goes into `res://<scene>_terrainy.tpaint` next to it.

Open `addons/terrainy/demo/terrainy_demo.tscn` for a scene that uses every node.

## Terrain scale

Quality is expressed in **meters**, not in cell counts, so a larger world costs more chunks instead
of losing detail:

| Property | Meaning |
|---|---|
| `terrain_size` | meters per side |
| `cell_size` | meters per cell — the quality knob; `terrain_resolution` is derived from it |
| `preserve_cell_size` | **on** (default): resizing the terrain keeps `cell_size`, so 4096 m at 1 m cells means 4096 cells; **off**: the 0.x fixed cell count, where resizing coarsens everything |
| `chunk_size` | cells per chunk (the stage-7 rebuild unit); with a fixed cell size a chunk also keeps its world size |
| `lod_auto`, `lod_pixel_error`, `lod_levels` | LOD switch distances derived from `cell_size`, the camera FOV and the viewport height (level n starts where one cell covers `lod_pixel_error` pixels); the fixed `lod_distances` only apply with `lod_auto` off |
| `navigation_mesh_template` | the per-chunk bake coarsens `cell_size` automatically when a chunk would need more than 1 M rasterization cells, so navigation keeps working on large terrains (Godot aborts a bake above 30 M voxels) |

So a 4 km terrain wants `cell_size = 2` → 2048 cells, 256 m chunks at `chunk_size = 128`, LOD0
wherever the player is. Cost scales the right way: mesh, LOD and navigation work per chunk stay
identical, the chunk *count* grows (16 × 16 chunks), and a full recompose composes the whole grid
once (edits stay incremental). `MAX_RESOLUTION` (4096 cells) is the detail ceiling per terrain;
raise `cell_size` beyond 1 m for anything larger than 4 km.

## Node suite

| Node | Role |
|---|---|
| `TerrainGenerator` | Root: pipeline, chunks, collision, navigation, material, paint persistence |
| `TerrainFieldNode` | Height contributor: domain (Region / Corridor / Global) × profile × relief × blend |
| `TerrainHeightmapNode` | External heightmap (EXR, 16-bit PNG, texture) as base or blend layer |
| `TerrainFieldGroup` | Pure container: composes its children into one unit (Contribute / Independent) |
| `TerrainSmoothModifier`, `TerrainTerraceModifier`, `TerrainClampModifier`, `TerrainRemapModifier`, `TerrainFlattenModifier` | Scene-order modifiers |
| `TerrainHoleNode` | Holes (mesh + collision; navigation opt-in via `punches_navigation`) |
| `TerrainScatterNode` | Mask-driven placement, one `MultiMeshInstance3D` per chunk |
| `TerrainPaintLayer` | Paint stack entry (direct child of the generator) |

Data resources: `TerrainReliefSource` (noise on top of a profile), the mask family
(`TerrainMaskRegion`, `TerrainMaskTexture`, `TerrainMaskPath`, `TerrainMaskSlope`,
`TerrainMaskElevation`, `TerrainMaskPaint`), `TerrainyTextureLayer`,
`TerrainySurfaceContribution`.

## The field model

```
height = elevation_base + profile_offset + shape
shape  = profile(e) * profile_height, then for each relief source
         Add: shape += n        Multiply: shape *= 1 + n
         n = noise(local xz rotated/scaled) * weight + offset   (* profile(e) if follow_profile)
weight = domain_falloff(e) * strength * mask
```

`e` is the normalized domain coordinate: 0 at the domain edge, 1 at its center (Region) or
center line (Corridor); Global is 1 everywhere. A fresh `domain_falloff` reproduces the 0.7
analytic falloff; set it to null for a hard edge. `elevation_origin`: **Local** (the field sits
at the node's height), **Curve** (corridors follow their route's height), **World**
(`profile_offset` is an absolute elevation).

Blend modes (`blend_mode`, scaled by `weight`): Add, Subtract, Multiply (`t * (1 + h·w)`),
Replace (lerp toward the field), Max / Min / Average (lerped by the weight, continuous at the
domain edge).

## Composition spaces

| `space` | Reads / acts on |
|---|---|
| Local | the direct parent unit's own map (a child of a mountain shapes only that mountain) |
| Group (default) | the nearest `TerrainFieldGroup`'s composite (the terrain composite at the root) |
| Global | the whole-terrain composite, in a post-compose pass in scene order |

Plain `Node3D`s are transparent folders. Disabled or hidden nodes drop out with their subtree.
`preview_isolate_node` (or *Isolate selected* in the gallery / scene-tree context menu) previews
one subtree with everything else flat; `Independent` groups are only composed while isolated.

## Pipeline & performance contract

```
1 plan scan → 2 field eval → 3 compose → 4 Global pass → 5 paint → 6 control maps → 7 chunks
```

Stages 2–6 run as one worker task; everything else expensive per chunk runs on the
`WorkerThreadPool` too — composition slices, mesh arrays (positions/normals/tangents/uvs/indices),
collision soup, per-chunk height bounds, navigation geometry and the dirty-detection hashes. The
main thread only builds the plan, assembles jobs and commits finished units, and every stage
charges the same per-frame budget (`chunk_apply_budget_ms`), so generation never blocks the editor
or game for longer than one budget unit. Field evaluations are cached by signature (an edit
re-evaluates only the edited field); only chunks whose heights or holes actually changed are
rebuilt, and each applied chunk fires `terrain_region_updated(aabb)`. `rebuild_now()` builds
synchronously and ignores the budget (bakes, tools, tests).

Measured on a 16-core machine at 256/512/1024/2048 cells per side, the longest single main-thread
frame is **4.5 / 9.2 / 10.2 / 10.1 ms** — every size inside a 16 ms frame. The tables, the
before/after and every caveat are in [../benchmarks/RESULTS.md](../../benchmarks/RESULTS.md); what
changed and which export does what is in
[../benchmarks/OPTIMIZATION.md](../../benchmarks/OPTIMIZATION.md).

- **One budget per frame**: `chunk_apply_budget_ms` (default 8) is spent by one accountant, and
  `tail_budget_ms` (default 2) reserves room for the `all_applied` tail (material refresh). A tail
  that finds the frame already spent drains at the start of the next frame.
- **Workers**: `max_worker_threads` defaults to `0` = auto (`OS.get_processor_count() - 1`).
- **Collision** is always maintained (also in exported builds): `HeightMapShape3D` per chunk,
  trimesh for holed chunks honouring `collision_quality` / `collision_triangle_budget`.
  `collision_range` (metres, `0` = everywhere) disables the shape outside a radius around the LOD
  camera without dropping the CPU data, so re-entry is a shape assignment, not a rebuild.
- **Navigation** geometry is built on the workers and committed per chunk; the bake is debounced
  (`navigation_debounce_ms`), tile-aligned via `border_size` + `filter_baking_aabb`;
  `bake_navigation()` for your own schedule.
- **LOD**: `chunk_resolution` (mesh cells per chunk at LOD 0) and the derived distances (`lod_auto`,
  `lod_pixel_error`, `lod_levels`) or explicit `lod_distances`; collision always uses every cell.
  `lod_hysteresis` (default 0.15) stops level flapping at a band boundary. Normals are sampled from
  the full-resolution heightmap including the neighbour's border sample, so chunk borders and LOD
  borders do not show a shading seam, and `seam_skirts` adds a skirt wall (mesh surface 1) only on
  an edge whose neighbour samples it at a different level.
- **Streaming**: `view_distance` (metres, `0` = every chunk resident, the previous behaviour)
  releases a chunk's mesh, collision shape, navigation mesh and scatter instances beyond that
  radius and rebuilds them from the current composition on re-entry; `chunk.streamed_in` reports
  residency.
- **GPU**: `use_gpu_feature_evaluation` (Region fields without relief), `use_gpu_composition`
  (blend kernel on the synchronous path), `use_gpu_paint` (stamp + control kernels). Every
  kernel has a CPU twin; without a `RenderingDevice` the CPU path is used silently.
- **Diagnostics**: `debug_diagnostics` (default off) gates only the slow-phase `push_warning`;
  counters and the report string are always available through `get_diagnostics()`.

## Materials

The auto material blends `texture_layers` by world height and slope and applies the stage-6
weight planes (texture paint + surface contributions). `custom_material` replaces it; a
`ShaderMaterial` still receives the weight-plane uniforms ([api.md](api.md#custom-materials)).

## Bake

*Bake to Scene* (toolbar) / `bake_to_scene(path)` writes static chunk meshes, collision,
navigation regions and scatter MultiMeshes into a scene with no Terrainy dependency.

## Tests

```bash
godot --headless --path . --script res://addons/terrainy/tests/run_tests.gd
godot --headless --path . --script res://addons/terrainy/tests/verify_harness.gd
GODOT=godot addons/terrainy/tests/run_gpu_parity.sh   # needs a GPU, see tests/README.md
```
