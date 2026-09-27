# Terrainy test suite

A small, **dependency-free** headless test suite for the addon. It does not need GUT or any
other plugin: `run_tests.gd` is a `SceneTree` main loop, the framework provides the assertions,
and every case is a plain script with `test_*()` methods.

## Running

```bash
# from the project root
godot --headless --path . --script res://addons/terrainy/tests/run_tests.gd

# options go after a bare `--`
godot --headless --path . --script res://addons/terrainy/tests/run_tests.gd -- --verbose
godot --headless --path . --script res://addons/terrainy/tests/run_tests.gd -- --filter=modifier
godot --headless --path . --script res://addons/terrainy/tests/run_tests.gd -- --filter=scatter --verbose
```

- `--verbose` prints one line per check instead of only the failures.
- `--filter=<substring>` runs only the tests whose `"<case>::<test>"` label contains the
  substring; repeatable.
- The process exits with code `0` when every test passes and `1` otherwise, so a plain
  `godot --headless …` invocation is enough for CI (see
  [`.github/workflows/run_tests.yml`](../../../../.github/workflows/run_tests.yml)).

**GPU coverage:** the parity cases in `cases/test_gpu_parity.gd` need a `RenderingDevice` and
skip themselves under `--headless` with the message
*"no RenderingDevice (headless/dummy renderer)"*. Run the suite **without** `--headless`
(e.g. `godot --path . --script res://addons/terrainy/tests/run_tests.gd`) on a machine with a
GPU to exercise the compute kernels. Such a run reports
`3 ObjectDB instances were leaked at exit`, which is expected: the shared Terrainy
`RenderingDevice` (`helpers/gpu_device.gd`) is deliberately held for the lifetime of the
process. The parity cases also assert that the GPU path was really taken, so a silent CPU
fallback fails the suite instead of passing it.

## Layout

```
tests/
  run_tests.gd            # entry point: case list, --verbose/--filter parsing, exit code
  framework/
    test_runner.gd        # assertions, case execution, reporting
    test_case.gd          # base class for cases (spawning, image fixtures, skips)
  cases/
    test_heightmap_builder.gd   # compose() results, caching/invalidation, GPU fallback
    test_modifier_pipeline.gd   # CPU smoothing/terracing/clamping + CPU/GPU parity
    test_material_builder.gd    # texture array packing, layer caps, blend modes
    test_scatter_manager.gd     # placement, instancing, instance replacement, scope
    test_deterministic_seeds.gd # seed determinism for noise-based feature nodes
    test_height_queries.gd      # get_height_at_world_position / is_hole_at_world_position
    test_terrain_mesh_generator.gd # surface arrays vs ArrayMesh, analytic tangents, border normals
    test_chunk_mesh_jobs.gd     # parallel chunk jobs (TerrainChunkPipeline), worker-thread contract
    test_collision_shapes.gd    # collision shape selection, quality presets/budget decimation, reuse
    test_navigation.gd          # navigation source geometry + the composer's bake hook
    test_diagnostics.gd         # warning thresholds and the per-rebuild report
    test_gpu_parity.gd          # GPU vs CPU heightmap comparison (skipped when headless)
```

**Threading contract:** renderer resources may only be created on the main thread. Chunk jobs run
on `WorkerThreadPool` tasks and must return raw surface arrays
(`TerrainMeshGenerator.generate_surface_arrays()`); the `ArrayMesh` is built afterwards on the
main thread with `TerrainMeshGenerator.mesh_from_arrays()`. `test_chunk_mesh_jobs.gd` asserts that
a job result contains an `"arrays"` array and **no** `"mesh"` key, and
`test_repeated_parallel_rebuilds_stay_consistent` keeps the mesh/RID path hot across repeated
rebuilds so that a regression reintroducing worker-side RID creation fails the suite instead of
crashing the process at shutdown.

**Collision contract:** the same rule applies to physics shapes, only stricter —
`ArrayMesh.create_trimesh_shape()` called from a worker thread **deadlocks the process** (not even a
crash, the `WorkerThreadPool` join never returns), so it must stay on the main thread. The chunk's
triangle soup is therefore built on the worker too (`TerrainCollisionBuilder.build_faces()`, run by
`TerrainChunkPipeline.run_collision_job()`), and `TerrainComposer` turns it into the
`ConcavePolygonShape3D` on the main thread. `test_collision_shapes.gd` pins the behaviour that
matters: chunks without holes keep the cheap `HeightMapShape3D` (whatever the budget), a budget of 0
reproduces the visual triangles exactly, a decimating budget stays inside the visual bounds and on
the decimated grid, the shape *instance* is reused across rebuilds, and the collision setters only
queue a refresh (a batch of property assignments costs one rebuild, not one per property).
`test_chunk_mesh_jobs.gd` asserts the soup is part of the job result contract.

**Navigation contract:** a navigation bake can only run on the main thread, so the composer never
bakes inside a rebuild: it queues a bake (`_navigation_dirty`) and `_process()` starts it once the
chunk jobs have landed. `bake_from_source_geometry_data()` calls its callback synchronously, so a
bake must never be triggered from a setter or any other code that runs while a rebuild is in
flight. `TerrainNavigationBuilder` only produces CPU data
(`NavigationMeshSourceGeometryData3D.add_faces()`), like the mesh and collision builders.
`test_navigation.gd` covers both halves: the source geometry spans the terrain in composer space
(not world space), follows the holes and the triangle budget, and the composer bakes exactly once
per request into a fresh `NavigationMesh` that carries the template settings.

**Diagnostics contract:** every timing threshold and every "slow …" warning goes through
`TerrainDiagnostics` (`helpers/terrain_diagnostics.gd`), which also owns the optional one-line
per-rebuild report. `test_diagnostics.gd` pins the thresholds, the warn-and-count behaviour, the
`-1` opt-out, the accumulation per phase and the report format, so a new call site that pushes its
own warning with a hardcoded threshold fails the suite.

## Writing a case

```gdscript
extends "res://addons/terrainy/tests/framework/test_case.gd"

var _composer: TerrainComposer = null

func before_all() -> void:
	_composer = TerrainComposer.new()
	spawn(_composer)          # adds it to the tree (runs _ready()) and tracks it for cleanup

func after_all() -> void:
	pass                      # optional; spawned nodes are freed automatically

func test_something() -> void:
	t.check_eq(actual, expected, "message shown on failure")
```

`test_case.gd` offers:

| Helper | Purpose |
| --- | --- |
| `spawn(node)` | Add a node to the tree, tracked and `queue_free()`d in `after_all()` |
| `make_flat_image(size, value)` / `make_ramp_image(size, height)` | `FORMAT_RF` heightmap fixtures |
| `make_grey_texture_image(size, value)` | `FORMAT_RGB8` texture/mask fixture |
| `build_contexts(features)` | `feature -> prepare_evaluation_context()` dictionary |
| `settle(composer, budget_ms := 30000)` | Pump the composer until `is_rebuilding()` is false (chunk jobs, collision refreshes and queued results), returns `false` on timeout |
| `has_rendering_device()` / `gpu_skip_reason()` | Guard GPU-only tests |

Assertions provided by the runner: `check`, `check_eq`, `check_not_eq`, `check_almost_eq`,
`check_in_range`, `check_images_match` (returns a difference report), `image_difference`,
`image_max`, `image_min`, `image_count_distinct`.

### Things that bite in a `--script` main loop

These are the reasons the framework looks the way it does — keep them in mind when adding cases:

- **Run tests from `_process()`, not `_initialize()`.** A script used as the main loop is
  initialised before the scene tree is entered, so nodes added there never reach the tree and
  never get `_ready()`.
- **Release nodes with `queue_free()`.** Calling `free()` from `_process()` raises
  *"Object is locked and can't be freed"* and aborts the calling function (which would swallow
  the report). The runner keeps the tree alive for `SETTLE_FRAMES` frames after the last test
  so the deletion queue is flushed before quitting.
- **Prefer `use_multithreading = false` on `TerrainComposer` fixtures.** With threading on, the
  composer starts a chunk-mesh worker thread in `_ready()`; if the fixture is freed while that
  thread is still busy, `_exit_tree()` waits up to 5 seconds (headless teardown then also
  reports a leaked RenderingServer RID). Building the chunk meshes synchronously keeps the
  suite fast and its exit clean.
- **`auto_update = false` only guards property setters.** `_ready()` still scans and rebuilds
  once, so fixtures should expect one initial build.
- **Internal children need `get_children(true)`.** Scatter instances are internal children of
  their container; `get_children()` returns nothing for them.
- **Annotate inferred types explicitly**: `var diff: Dictionary = t.image_difference(a, b)`.
  `:=` on an untyped method return is a parse error, and a single parse error makes the whole
  case fail at runtime with *"Nonexistent function 'new' in base 'GDScript'"*.
- **`TerrainComposer.global_position` requires the node to be inside the tree.**
