# Performance benchmarks

Measurement tooling for the Terrainy addon. These scripts are **not part of the addon and not
part of the test suite** — nothing in `addons/` references them, they are never exported with
the plugin, and CI does not run them.

They live outside `addons/` because they exist to answer "where does the time go", which is a
different question from "is the behaviour correct". The correctness suite stays in
`addons/terrainy/tests/`.

## Running

Every script is a `SceneTree` main loop, so it runs headless without a scene file:

```bash
godot --headless --path . --script res://tests/perf/benchmark.gd
godot --headless --path . --script res://tests/perf/benchmark.gd -- --quick   # 3 runs instead of 5
```

A full sweep over the 1025x1025 grid takes several minutes. On a large grid, run it as a
background process rather than holding the terminal.

## Headless caveat

`--headless` provides **no RenderingDevice** (`RenderingServer.get_rendering_device() == null`),
so every GPU path is skipped and composition falls back to CPU. The numbers are the **CPU worst
case**, not what the editor does with a GPU. Any GPU-vs-CPU claim has to be measured in the
editor.

## Scripts

| Script | Answers |
|---|---|
| `benchmark.gd` | Main harness: cost per pipeline stage across 257/513/1025 grids, plus a top-N ranking. Start here. |
| `benchmark_probes.gd` | Isolates specific per-pixel costs: one `get_influence_weight()`, one image copy, and what clipping the influence pass to the feature bounds would buy. |
| `benchmark_clip_equiv.gd` | Proves the clipped influence pass equals the full-grid pass (12 cases: shapes, rotations, borders, outside, oversized) and measures the speedup. |
| `benchmark_hole3d_equiv.gd` | Same equivalence proof for the 3D hole path, which needs a conservative region because a tilted hole extends along Y. |
| `benchmark_smoothing.gd` | Smoothing pass: per-pixel polar-offset recomputation vs hoisted. |
| `benchmark_smoothing_equiv.gd` | Proves hoisted == original for the smoothing math, and isolates the f32-vs-f64 weight storage question. |
| `benchmark_smoothing_shipped_equiv.gd` | Runs the equivalence check against the **real** `ModifierPipeline`, not a copy of the loop. |
| `benchmark_bounds_cache_equiv.gd` | Proves the cached influence bounds match a fresh scan, survive invalidation correctly, and are dropped on a feature move. |
| `benchmark_holed.gd` | Splits the holed-mesh cost: how much is boundary-vertex key building vs the per-cell work. |
| `benchmark_keys.gd` | Microbenchmark for the String vs packed-int boundary-vertex key. |

## Method

Two rules, both learned the hard way:

**Measure, then prove the fix.** Each suspected hotspot gets a probe that runs the candidate
change next to the real code. The probe produces the speedup *and* the argument for it; reading
code alone misranks hotspots badly.

**Prove equivalence before claiming an optimization.** An optimization that changes output is a
bug. Compare against a verbatim copy of the previous implementation (not a remembered result),
use **exact float equality**, and cover the stress cases: rotations, border-touching and
fully-outside features, oversized features, every shape enum, and any code path that overrides
the function being changed. Report `n=differing, maxdiff`.

When a change is *not* bit-exact, say so and quantify the drift instead of rounding it away.

## Gotchas that cost real time here

- `Time.get_ticks_msec()` is too coarse for inner loops — a real pass can measure 0 ms. Use
  `Time.get_ticks_usec()`.
- `PackedFloat32Array` rounds stored values to 32-bit. Hoisting weights into one while the
  original used a local float (double) changes the output. Use an untyped `Array` to keep
  float64.
- `var x := something_untyped.property` is a parse error ("Cannot infer the type"); write the
  explicit type.
- GDScript's `%` formatting has no `%e` — use `%.9f` for tiny magnitudes.
- Check enum member names against the source before using them.
