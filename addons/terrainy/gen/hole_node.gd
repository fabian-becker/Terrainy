@tool
@icon("res://addons/terrainy/icons/hole.svg")
class_name TerrainHoleNode
extends TerrainComposableNode

## Punches a hole into the terrain: the hole mask cuts the mesh and the collision of every
## intersecting chunk. A sample is a hole when the terrain surface point lies inside the hole
## volume, so tilted / rotated holes work in 3D (cave mouths in slopes).
##
## Navigation is opt-in: with [member punches_navigation] the hole also removes the cells from
## the navmesh of intersecting chunks. Painted masks are never hole sources.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")

enum HoleShape { CYLINDER, BOX, SPHERE }

@export var hole_shape: HoleShape = HoleShape.CYLINDER:
	set(value):
		hole_shape = value
		_commit()

## Hole extent in local meters (X = width, Y = depth, Z = length). A cylinder uses X/Z as its
## footprint ellipse and Y as its depth.
@export var size: Vector3 = Vector3(8, 200, 8):
	set(value):
		size = value.max(Vector3(0.01, 0.01, 0.01))
		_commit()

## Also remove the hole's cells from the navigation mesh (default off).
@export var punches_navigation: bool = false:
	set(value):
		punches_navigation = value
		_commit()

func get_unit_kind() -> int:
	return 3  # CompositionPlan.UnitKind.HOLE

func make_snapshot(_context: Dictionary) -> Dictionary:
	return {
		"inv_xform": global_transform.affine_inverse(),
		"shape": hole_shape,
		"half": size * 0.5,
		"bounds": get_influence_bounds(),
		"punches_navigation": punches_navigation,
		"signature": "%s|%d|%s|%d" % [var_to_str(global_transform), hole_shape, var_to_str(size), int(punches_navigation)],
	}

## Conservative world XZ bounds (any rotation of the volume fits a square of this half extent).
func get_influence_bounds() -> Rect2:
	var basis := global_transform.basis
	var half := size * 0.5
	var ex := absf(basis.x.x) * half.x + absf(basis.y.x) * half.y + absf(basis.z.x) * half.z
	var ez := absf(basis.x.z) * half.x + absf(basis.y.z) * half.y + absf(basis.z.z) * half.z
	var c := global_position
	return Rect2(c.x - ex, c.z - ez, ex * 2.0, ez * 2.0)

## Whether a world point lies inside the hole volume of a snapshot.
static func snapshot_contains(snap: Dictionary, world: Vector3) -> bool:
	var inv: Transform3D = snap["inv_xform"]
	var half: Vector3 = snap["half"]
	var l := inv * world
	match int(snap["shape"]):
		HoleShape.BOX:
			return absf(l.x) <= half.x and absf(l.y) <= half.y and absf(l.z) <= half.z
		HoleShape.SPHERE:
			var d := Vector3(l.x / half.x, l.y / half.y, l.z / half.z)
			return d.length_squared() <= 1.0
		_:
			if absf(l.y) > half.y:
				return false
			var dx := l.x / half.x
			var dz := l.z / half.z
			return dx * dx + dz * dz <= 1.0
