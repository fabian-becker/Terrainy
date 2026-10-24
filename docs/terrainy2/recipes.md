# Configuration recipes

Terrainy 2 ships no shape presets: every look is a `TerrainFieldNode` configuration. These
recipes are starting points (the demo scene uses most of them). Save your own versions with
*Save Terrainy Configuration* (scene-tree context menu) or the gallery dock; they land in
`res://terrainy_configs/` as small `.tscn` files and are inserted as editable copies.

Profile curves run from the domain edge (x = 0) to the center (x = 1).

| Look | Domain | Profile | Relief | Blend / origin |
|---|---|---|---|---|
| Rolling noise | Global | flat, `profile_height` 0 | 2 sources: weight 5 @ 0.012, weight 1.2 @ 0.05 | Add |
| Raise / sink an area | Region | flat | – | Add, signed `profile_height` |
| Hill | Region circle | (0,0) → (1,1) smooth | weight 2 | Add |
| Mountain | Region circle 100–140 m | (0,0) → (0.55,0.45) → (1,1), steep middle | weight 8–12 @ 0.03, `follow_profile` | Add; Local terrace child for strata |
| Volcano | Region circle | (0,0) → (0.75,1) → (1,0.6) (crater dip at the center) | weight 3, follow | Add |
| Crater | Region circle | (0,0) → (0.8,0.3) → (0.85,-1) → (1,-1) | – | Add |
| Mesa / plateau | Region rectangle | flat | weight 1 | Replace, Local origin at the plateau height; flatten child for the top |
| Island | Region ellipse 200 m | (0,-0.2) → (0.3,0.2) → (1,1) | weight 6, follow | Add over a negative Global base |
| Basin / lake bed | Region ellipse | (0,0) → (1,1) | – | Global space, MIN blend, World origin |
| Dunes | Region ellipse | flat, height 0 | weight 4 @ 0.04, `scale` (6, 1), `rotation` = wind | Add |
| Canyon | Corridor, width 40 | (0,0) → (0.3,1) → (1,1) | weight 3 | Subtract `profile_height` 25 |
| River | Corridor, width 15–20 | (0,0) → (1,1) | – | Min blend, Curve origin, `profile_height` −3; gravel contribution |
| Road | Corridor, width 6–8 | flat | – | Replace, Curve origin, `profile_height` 0 |
| Dike / ridge | Corridor | (0,0) → (1,1) | weight 1 | Max blend, Curve origin, positive height |
| Trench | Corridor narrow | (0,1) → (0.2,0) → (1,0) | – | Subtract |
| Rectangular cut | Region rectangle | (0,0) → (0.1,1) → (1,1) slot | – | Subtract |
| Terraced fields | any | – | – | `TerrainTerraceModifier` step 2–4 m, smoothness 0.3, slope mask < 25° |

## Masks as configuration

- *Trees on grass, not on the road*: give the scatter node a `TerrainMaskPath` with
  `path_node` = the road's `Path3D`, `invert = true`, width a bit larger than the road.
- *Flatten only the valleys*: `TerrainFlattenModifier` + `TerrainMaskElevation` (max height).
- *Flatten slopes steeper than 35°*: flatten + `TerrainMaskSlope` (35–90°).
- *Riverbank texture*: a `TerrainySurfaceContribution` on the river field (the claim follows the
  field weight exactly), or a `TerrainMaskPath` on a texture paint layer.
- *Hand-painted biome*: a MASK paint layer referenced by `TerrainMaskPaint` on a relief field.

## Hierarchy patterns

- **Nested sculpting**: Local-space children of a field shape only that field (a Local terrace
  under a mountain terraces only the mountain).
- **Landform group**: put several fields in a `TerrainFieldGroup` to blend them as one unit
  (e.g. a REPLACE group stamps a whole settlement plateau onto the terrain).
- **World constraints**: Global-space modifiers run after everything (a Global clamp keeps the
  whole terrain above sea floor regardless of what fields did).
