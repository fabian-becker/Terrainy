# Terrainy 2 test suite

Port of the dependency-free 0.x test harness. The framework (`framework/`) is unchanged: cases
extend `test_case.gd`, and the runner, error logger and harness verifier are self-contained
(they have no dependency on the addon's runtime code).

```bash
godot --headless --path . --script res://addons/terrainy/tests/run_tests.gd
godot --headless --path . --script res://addons/terrainy/tests/run_tests.gd -- --filter=paint --verbose
godot --headless --path . --script res://addons/terrainy/tests/verify_harness.gd
```

## Cases

| Case | Covers |
|---|---|
| test_eval_core | grid / maps / falloff LUT vs 0.7 analytic falloff / corridor raster fast path / blend math |
| test_field_composition | domain × profile × relief × blend matrix, determinism, signature caching, dirty chunks |
| test_corridor_domain | routes, cross-sections, Curve elevation origin, road equivalence |
| test_hierarchy_composition | sibling order, Local / Group / Global spaces, groups, Independent + isolate, space in signature |
| test_masks | every mask resource |
| test_modifiers | smooth / terrace / clamp / remap / flatten |
| test_heightmap_node | normalized + meters sources, EXR round trip, diagnostics, save/load persistence |
| test_paint_layers | kinds, ordering, opacity, determinism, revisions, dirty rects, undo, resample, `.tpaint` bundle |
| test_texture_paint | stage-6 weight planes, paint wins over contributions, erase |
| test_chunks_collision, test_holes, test_navigation, test_scatter, test_material, test_bake | output stage |
| test_api | TerrainyAPI registry, queries, region sampling, settle, signals |
| test_async_pipeline | performance contract: worker compose, budgeted apply, edits during rebuilds |
| test_editor_tools | brush raycast / strokes / layer resolution, gallery, configuration snapshots |
| test_demo | demo scene builds and uses every node |
| test_namespace | no 0.x class name collisions, no 0.x preloads, no water |
| test_gpu_parity | CPU ↔ GPU kernels (blend, field, paint_apply, paint_control, whole pipeline) |

## GPU parity (tested contract, not gated in CI)

CI has no `RenderingDevice`, so the GPU parity cases skip there; CI gates the CPU paths. Run
them locally / nightly on a machine with a GPU — the script fails when a GPU case skipped:

```bash
GODOT=/path/to/godot addons/terrainy/tests/run_gpu_parity.sh
```

## Tools

- `tools/check_scripts.gd` — compiles every terrainy script and lists failures.
- `demo/build_demo.gd` — regenerates `demo/terrainy_demo.tscn`.
