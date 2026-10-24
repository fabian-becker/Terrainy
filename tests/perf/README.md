# Performance benchmarks

Measurement tooling for Terrainy 2. These scripts are **not part of the addon and not part of the
test suite**: nothing in `addons/` references them, they are never exported with the plugin, and
CI does not run them.

They live outside `addons/` for the same reason they did in 0.x: they answer "where does the time
go", which is a different question from "is the behaviour correct". The correctness suite stays in
`addons/terrainy/tests/`.

## Running

Both scripts are `SceneTree` main loops, so they run headless without a scene file:

```bash
godot --headless --path . --script res://tests/perf/benchmark.gd
godot --headless --path . --script res://tests/perf/benchmark.gd -- --quick   # 3 rounds instead of 5
godot --headless --path . --script res://tests/perf/benchmark.gd -- --full    # + the reference scale

godot --headless --path . --script res://tests/perf/benchmark_frame_budget.gd
godot --headless --path . --script res://tests/perf/benchmark_frame_budget.gd -- --cells=1024 --budget=8
```

Exit code is always 0: these are measurement tools, not gates.

## The contract they measure

The design's performance contract is **not** "a rebuild finishes in N seconds". It is:

> generation never blocks the game/editor frame — a full recompose may take arbitrarily long over
> many frames, as long as per-frame work stays inside `chunk_apply_budget_ms`.

So there are two independent things to measure, and the two scripts are split along exactly that
line:

| Script | Answers |
|---|---|
| `benchmark.gd` | Total cost, attributed per pipeline stage (plan scan → field eval → compose → Global pass → paint → control maps → chunks), across grid sizes, plus cache behaviour. |
| `benchmark_frame_budget.gd` | The contract side: given a queued full recompose, how long is the **worst main-thread frame** while finished chunks are applied under the budget? |

`benchmark.gd` reads phase attribution from the generator's own `TerrainDiagnostics`, so the
reported stages are the ones the rebuild actually ran, not a guess from outside. `benchmark_frame_budget.gd`
drives the generator's main-thread step by hand (`set_process(false)` + a manual `_process()` call,
the same thing the headless test harness does) and pads each frame out to 16 ms, so the rebuild
sees realistic frame spacing instead of a spin loop that would both starve the compose worker and
report a cadence no game has.

## Reference scale

The contract names **1024² / 4 km²**. Read literally that is a 1024-cell grid over a 4 km² square,
i.e. 2048 m × 2048 m (2 m cells), which is what `--full` adds. If the intent was a different
framing (e.g. 4 km per side), change `SCALES` in `benchmark.gd` — it is one entry.

## Headless caveat

`--headless` provides **no RenderingDevice** (`RenderingServer.get_rendering_device() == null`),
so every GPU path is unavailable. Both scripts force the `use_gpu_*` flags off rather than leaving
them to fall back silently, so the numbers are honestly labelled **CPU worst case**: they are not
what the editor does with a GPU, and any GPU-vs-CPU claim has to be measured in the editor.

## Ambient warnings are expected

A rebuild slower than `Diagnostics.REBUILD_WARN_MS` (2 s) prints a `Rebuild #N in …` warning with
its phase breakdown. The larger scales reach that threshold on CPU, so expect those warnings to
interleave with the report — they are the diagnostics thresholds firing on real measurements, not
benchmark failures. They are also useful: they carry the same phase breakdown the tool reports.

## What it already told us

Measured on a CPU-only headless run (Godot 4.7.2, Windows, this project's dev machine), 3 rounds:

| Scale | Full recompose | Cached rebuild | One-field edit | Paint stroke (24 m) |
|---|---|---|---|---|
| 256 cells / 256 m | 629 ms compose, 31 ms chunk workers | 1.8 ms | 232 ms | 79 ms |
| 512 cells / 512 m | 1947 ms compose, 127 ms chunk workers | 1.9 ms | 414 ms | 32 ms |

- **Compose dominates** and scales roughly with sample count (4× samples → ~3.1× time); chunk
  meshing is a small share and runs on workers.
- **Caching works as designed**: a settled rebuild reuses the compose signature (1.8 ms), and a
  one-field edit re-evaluates 1 unit and replays the other 2.
- **The frame contract holds**: at 512 cells with an 8 ms budget, 105 frames, worst frame 8.15 ms
  (budget plus one finished result), median 0.01 ms, 16/16 chunks applied.
- The paint-stroke numbers at the two scales are not comparable as-is: the harness moves the stamp
  each round, so a stroke lands near a different part of the terrain and the recompose rect
  differs. Treat 79 ms / 32 ms as "tens of ms", not as a scaling curve.

## Not covered

- Scatter placement and `MultiMesh` building (needs a prop scene; separate cost).
- Navigation baking (deliberately off in the fixtures — it is debounced and per-chunk).
- Every GPU path (needs a real RenderingDevice).
- Exported-build behaviour and load cost of a large `.tpaint` bundle.

## Reference numbers

Headless CPU (no `RenderingDevice`), mono 4.7.2, `--quick --full`. These are the numbers to compare
against after a pipeline change; they are not a gate.

| grid | full rebuild | compose | one field edit | cached rebuild | paint stroke |
|---|---|---|---|---|---|
| 256 cells / 256 m | 0.73 s | 0.67 s | 0.31 s | 2 ms | 98 ms |
| 512 cells / 512 m | 2.4 s | 2.0 s | 0.47 s | 2 ms | 30 ms |
| 1024 cells / 2048 m | 9.1 s | 7.7 s | 1.2 s | 2 ms | 9 ms |
