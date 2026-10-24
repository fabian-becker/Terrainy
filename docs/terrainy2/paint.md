# Paint layers

Manual edits are a stack of `TerrainPaintLayer` nodes, direct children of the
`TerrainGenerator`. Scene order = application order (drag them in the scene dock or use
*Up / Down* in the *Terrainy Paint* dock).

**Paint is always the last stage in height order.** Moving a mountain never destroys or
displaces a stroke: strokes stay anchored in world XZ and re-compose against the new surface.
(A delta painted next to a mountain is relative; after the mountain moves the same delta sits on
the new terrain — what a sculpt tool implies.)

## Kinds

| Kind | Data | Effect |
|---|---|---|
| HEIGHT_DELTA | float (RF) | adds signed meters × opacity × mask |
| HEIGHT_ABSOLUTE | value + coverage (RGF) | pins the height where coverage > 0, replacing procedural content |
| SMOOTH | R8 strength | blends toward a local blur (`smooth_radius`) |
| TEXTURE | R8 weight plane of `texture_layer_index` | wins over surface contributions where painted |
| MASK | R8 coverage | referenced by `TerrainMaskPaint` (fields, modifiers, scatter, other layers); never a hole source |

Every layer has `opacity`, an optional `mask` (+ `invert_mask`) and its own grid of
`TerrainGenerator.paint_layer_grid` pixels across `terrain_size`, independent from
`terrain_resolution`. Changing `terrain_resolution` never touches paint; changing
`terrain_size` or `paint_layer_grid` prompts to resample (bilinear default, nearest, or cancel
to restore the previous size) so strokes keep their world position.

## Brush (editor only)

Toggle *Brush* in the 3D toolbar (visible when a generator or anything below it is selected)
and pick an op in the *Terrainy Paint* dock:

| Op | Default target layer | Notes |
|---|---|---|
| Raise / Lower | active delta/absolute layer, else creates *Sculpt* | `Height per stamp` × strength meters |
| Flatten | same | target = terrain height under the first click; Shift or *Absolute flatten* = typed world height |
| Smooth | active smooth layer, else a height layer | |
| Noise | height layer | seeded, world-anchored noise stamp |
| Texture | TEXTURE layer for the selected palette index (created on demand) | *Erase* toggle (or Ctrl) removes that texture's weight |
| Mask | active MASK layer, else creates *Mask* | |

Ctrl = erase / invert, `[` / `]` = radius. For the Texture op the dock also has a persistent
*Erase* checkbox, so texture removal stays on across strokes; with it off, Ctrl erases the
selected texture for a single stroke. Erasing drives the weight plane back to 0, which removes
that texture from the blend and lets the underlying palette layers show through again. The
cursor overlay shows the radius ring, the inner falloff ring and the op (orange and marked
`(erase)` while erasing). The brush falloff is an editable `Curve`.

Each stroke is **one undo action** storing the stroke's rect before/after. Strokes only
recompose the touched region: delta / absolute / smooth layers re-run the paint stage over the
stroke rect (plus a smoothing margin) and rebuild only intersecting chunks; texture strokes
update only that rect of the weight planes. Mask strokes recompose (masks can gate anything).

## Persistence

All paint of a scene lives in **one bundle file**: `res://<scene>_terrainy.tpaint`
(`TerrainGenerator.paint_bundle_path`, set automatically on the first save; each generator has
its own `paint_section`). The `.tscn` stores only the reference.

- Saved on scene save and debounced after a stroke commit — never per stamp.
- Atomic: written to `<path>.tmp` and renamed, so no orphan files and no half-written bundle.
- Moving / copying a scene: move its `.tpaint` with it (or point `paint_bundle_path` at it).
- Size = Σ layer images (1024² R8 ≈ 1 MB, RF ≈ 4 MB, zstd compressed). Keep few layers.
- `.tpaint` is a regular resource (`TerrainPaintBundle`) and is exported with the project.

## Cost notes

- HEIGHT_ABSOLUTE pins replace procedural content; use sparingly.
- Painting with `use_gpu_paint` runs the `paint_apply` / `paint_control` kernels and reads back
  only the stroke rect; the CPU twin produces identical results (parity-tested).
