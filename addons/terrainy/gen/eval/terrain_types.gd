@tool
class_name TerrainTypes
extends RefCounted

## Canonical enums shared by the node layer and the worker-safe evaluation layer.
##
## These used to be declared twice — once on the node (the inspector-facing original) and once on
## the snapshot/composer that mirrors it — coupled only by ordinal, with nothing checking that the
## two stayed in step. A reordered member on one side would have silently reinterpreted saved
## scenes, snapshot payloads and the GPU buffer contract.
##
## There is now one declaration per enum, here in the lower layer, and every use site names it:
##
##     @export var blend_mode: TerrainTypes.BlendMode = TerrainTypes.BlendMode.ADD
##
## Nodes cannot alias these (`const BlendMode = TerrainTypes.BlendMode`) because GDScript will not
## resolve `SomeClass.AliasedConst.MEMBER` from another script — only a real, locally declared
## enum is reachable as `SomeClass.EnumName.MEMBER`. A source-scanning test in
## `tests/cases/test_eval_core.gd` pins that each of these is still declared exactly once.

## Domain of a [TerrainFieldNode]: where it acts.
enum DomainKind { REGION, CORRIDOR, GLOBAL }

## Region footprint shape.
enum RegionShape { CIRCLE, ELLIPSE, RECTANGLE }

## What a field's `profile_offset` is relative to.
enum ElevationOrigin { LOCAL, CURVE, WORLD }

## How a unit's height blends into its target.
enum BlendMode { ADD, SUBTRACT, MAX, MIN, MULTIPLY, AVERAGE, REPLACE }

## What a composable node reads / evaluates against (see the design doc §5.9).
enum Space { LOCAL, GROUP, GLOBAL }

## How a [TerrainFieldGroup] takes part in the surrounding composition.
enum Scope {
	## The group's composite blends into the enclosing composite.
	CONTRIBUTE,
	## Excluded from the outer composite (preview / reference only; still composed when it is
	## the generator's preview_isolate_node).
	INDEPENDENT,
}

## True when a blend mode treats the field height as an additive delta in meters over the
## composite datum (ADD, SUBTRACT). Target modes (MAX, MIN, AVERAGE, REPLACE) use the height as
## an absolute level instead. Mirrors `Composer.blend_value()`; the editor gizmos use it to
## decide whether the profile sits on `base_height` or on the node's own elevation.
static func is_delta_blend(mode: int) -> bool:
	return mode == BlendMode.ADD or mode == BlendMode.SUBTRACT

## True when a blend mode's height is an elevation in meters. MULTIPLY is the exception: its
## profile is a relative factor, so there is no altitude to draw a profile against.
static func has_elevation(mode: int) -> bool:
	return mode != BlendMode.MULTIPLY
