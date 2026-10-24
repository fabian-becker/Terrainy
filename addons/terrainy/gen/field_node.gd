@tool
@icon("res://addons/terrainy/icons/field.svg")
class_name TerrainFieldNode
extends TerrainComposableNode

## THE height contributor of Terrainy 2: a domain (where it acts) x a profile (cross-section)
## x a relief stack (noise on top) x a blend.
##
## Every 0.x landform (mountain, canyon, volcano, island, dunes, roads, rivers...) is a
## configuration of this node; see docs/terrainy2/recipes.md. Children compose in tree order:
## a Local-space child field or modifier shapes only this field's own output.

const FieldSnapshot = preload("res://addons/terrainy/gen/eval/field_snapshot.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")
const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const Signature = preload("res://addons/terrainy/gen/eval/signature.gd")

@export_group("Domain")
## Region: a footprint around the node. Corridor: a Path3D child supplies the route.
## Global: the whole terrain.
@export var domain_kind: TerrainTypes.DomainKind = TerrainTypes.DomainKind.REGION:
	set(value):
		domain_kind = value
		notify_property_list_changed()
		_commit()

@export var region_shape: TerrainTypes.RegionShape = TerrainTypes.RegionShape.CIRCLE:
	set(value):
		region_shape = value
		_commit()

## Full footprint size in meters (X, Z) of a Region domain. Node rotation/scale apply.
@export var region_size: Vector2 = Vector2(64, 64):
	set(value):
		region_size = value.max(Vector2(0.1, 0.1))
		_commit()

## Path3D supplying the corridor route. Empty = first Path3D child.
@export var domain_path: NodePath:
	set(value):
		domain_path = value
		_rebind_path()
		_commit()

## Full corridor width in meters.
@export var domain_width: float = 12.0:
	set(value):
		domain_width = maxf(value, 0.1)
		_commit()

## Weight from the domain edge (x = 0) to full weight. The fresh curve reproduces the 0.7
## analytic falloff. Null = hard edge.
@export var domain_falloff: Curve = CurveLut.default_falloff():
	set(value):
		_track_resource(domain_falloff, value)
		domain_falloff = value
		_domain_falloff_cleared = value == null
		_commit()

## Persists an explicit null (hard edge): Godot does not serialize a null Object property
## because it equals the typed default, so the cleared state is stored separately.
@export_storage var _domain_falloff_cleared: bool = false:
	set(value):
		_domain_falloff_cleared = value
		if value and domain_falloff != null:
			domain_falloff = null

@export_group("Profile")
## Cross-section: x = edge (0) -> center (1), y = multiplier. Null = flat (1.0).
## For corridors x runs across the width.
@export var profile: Curve:
	set(value):
		_track_resource(profile, value)
		profile = value
		_commit()

## Amplitude in meters (gizmo height handle). Negative values carve.
@export var profile_height: float = 10.0:
	set(value):
		profile_height = value
		_commit()

@export var profile_offset: float = 0.0:
	set(value):
		profile_offset = value
		_commit()

## Local: the field sits at the node's height (+ offset). Curve: follow the corridor curve's
## own elevation (roads/rivers). World: pin to the absolute elevation profile_offset.
@export var elevation_origin: TerrainTypes.ElevationOrigin = TerrainTypes.ElevationOrigin.LOCAL:
	set(value):
		elevation_origin = value
		_commit()

@export_group("Relief")
@export var relief_layers: Array[TerrainReliefSource] = []:
	set(value):
		for r in relief_layers:
			_track_resource(r, null)
		relief_layers = value
		for r in relief_layers:
			_track_resource(null, r)
		_commit()

@export_group("Blend")
@export var blend_mode: TerrainTypes.BlendMode = TerrainTypes.BlendMode.ADD:
	set(value):
		blend_mode = value
		_commit()

@export_range(0.0, 2.0, 0.001) var strength: float = 1.0:
	set(value):
		strength = value
		_commit()

@export_group("Mask")
@export var mask: TerrainMaskResource:
	set(value):
		_track_resource(mask, value)
		mask = value
		_commit()

@export_group("Surface")
@export var surface_contributions: Array[TerrainySurfaceContribution] = []:
	set(value):
		for c in surface_contributions:
			_track_resource(c, null)
		surface_contributions = value
		for c in surface_contributions:
			_track_resource(null, c)
		_commit()

var _bound_path: Path3D = null
var _last_path_xform: Transform3D = Transform3D.IDENTITY

## Defaults that are objects use non-constant initializers instead of _init(): Godot then
## always serializes the property, so an explicit null (hard edge) survives save / load.
func _init() -> void:
	super._init()
	_track_resource(null, domain_falloff)

func _ready() -> void:
	_rebind_path()
	set_process(Engine.is_editor_hint())

func _process(_delta: float) -> void:
	# Path3D nodes do not notify their parent when moved; poll cheaply in the editor.
	if domain_kind != TerrainTypes.DomainKind.CORRIDOR:
		return
	var path := get_domain_path_node()
	if path != _bound_path:
		_rebind_path()
		_commit()
	elif path and path.is_inside_tree() and not path.global_transform.is_equal_approx(_last_path_xform):
		_last_path_xform = path.global_transform
		_commit()

func _notification(what: int) -> void:
	super._notification(what)
	if what == NOTIFICATION_CHILD_ORDER_CHANGED and is_inside_tree():
		_rebind_path()

func _validate_property(property: Dictionary) -> void:
	var pname: String = property["name"]
	var region_only := ["region_shape", "region_size"]
	var corridor_only := ["domain_path", "domain_width"]
	if pname in region_only and domain_kind != TerrainTypes.DomainKind.REGION:
		property["usage"] = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE
	if pname in corridor_only and domain_kind != TerrainTypes.DomainKind.CORRIDOR:
		property["usage"] = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE

func get_unit_kind() -> int:
	return 0  # CompositionPlan.UnitKind.FIELD

## The Path3D driving a Corridor domain (explicit path or first Path3D child).
func get_domain_path_node() -> Path3D:
	if not domain_path.is_empty() and is_inside_tree():
		var node := get_node_or_null(domain_path)
		if node is Path3D:
			return node
	for child in get_children():
		if child is Path3D:
			return child
	return null

func _rebind_path() -> void:
	var path := get_domain_path_node() if is_inside_tree() or get_child_count() > 0 else null
	if _bound_path == path:
		return
	if _bound_path and is_instance_valid(_bound_path) and _bound_path.curve_changed.is_connected(_commit):
		_bound_path.curve_changed.disconnect(_commit)
	_bound_path = path
	if _bound_path:
		_bound_path.curve_changed.connect(_commit)
		if _bound_path.is_inside_tree():
			_last_path_xform = _bound_path.global_transform

## Worker-safe snapshot. [param context] keys: `grid`, `generator_xform`, `noise_seed`.
func make_snapshot(context: Dictionary) -> RefCounted:
	var snap := FieldSnapshot.new()
	_fill_snapshot(snap, context)
	return snap

func _fill_snapshot(snap, context: Dictionary) -> void:
	var gen_xform: Transform3D = context.get("generator_xform", Transform3D.IDENTITY)
	var grid = context.get("grid")
	snap.domain_kind = domain_kind
	snap.xform = world_transform()
	snap.inv_xform = world_transform().affine_inverse()
	snap.shape = region_shape
	snap.half = Raster.shape_half_extents(region_shape, region_size)
	snap.has_falloff = domain_falloff != null
	snap.falloff_lut = CurveLut.bake(domain_falloff, 1.0) if domain_falloff else PackedFloat32Array()
	snap.profile_lut = CurveLut.bake(profile, 1.0)
	snap.profile_height = profile_height
	snap.profile_offset = profile_offset
	snap.elevation_origin = elevation_origin
	snap.node_rel_y = world_transform().origin.y - gen_xform.origin.y
	snap.generator_y = gen_xform.origin.y
	snap.strength = strength
	match domain_kind:
		TerrainTypes.DomainKind.GLOBAL:
			snap.bounds = grid.world_rect() if grid else Rect2()
		TerrainTypes.DomainKind.CORRIDOR:
			snap.half_width = domain_width * 0.5
			var path := get_domain_path_node()
			if path and path.curve:
				var step: float = grid.cell if grid else 1.0
				snap.polyline = Raster.polyline_from_curve(path.curve, (path.global_transform if path.is_inside_tree() else path.transform), step, gen_xform.origin.y)
			snap.bounds = Raster.polyline_bounds(snap.polyline, snap.half_width)
		_:
			snap.bounds = Raster.shape_bounds(world_transform(), snap.half)
	var seed_base: int = context.get("noise_seed", 0)
	for r in relief_layers:
		if r == null or not r.enabled or r.noise == null:
			continue
		var noise := r.noise.duplicate() as FastNoiseLite
		noise.seed = r.effective_seed(seed_base)
		snap.relief.append({
			"noise": noise, "weight": r.weight, "offset": r.offset, "blend": int(r.blend),
			"scale": r.scale, "cos": cos(r.rotation), "sin": sin(r.rotation), "follow": r.follow_profile,
		})
	snap.signature = _own_signature(snap, seed_base)

func _own_signature(snap, seed_base: int) -> String:
	var parts := PackedStringArray([
		get_script().resource_path, var_to_str(snap.xform), str(domain_kind), str(region_shape),
		var_to_str(region_size), var_to_str(domain_width), Signature.of_value(snap.polyline),
		Signature.of_value(snap.falloff_lut), Signature.of_value(snap.profile_lut),
		var_to_str(profile_height), var_to_str(profile_offset), str(elevation_origin),
		var_to_str(snap.generator_y), var_to_str(strength), str(seed_base),
	])
	for r in relief_layers:
		parts.append(Signature.of_object(r) if r else "null")
	return "|".join(parts)

func get_influence_bounds() -> Rect2:
	if not is_inside_tree():
		return Rect2()
	var generator := get_generator()
	match domain_kind:
		TerrainTypes.DomainKind.GLOBAL:
			return generator.get_terrain_world_rect() if generator else Rect2()
		TerrainTypes.DomainKind.CORRIDOR:
			var path := get_domain_path_node()
			if path == null or path.curve == null:
				return Rect2()
			return Raster.polyline_bounds(Raster.polyline_from_curve(path.curve, path.global_transform, 2.0), domain_width * 0.5)
		_:
			return Raster.shape_bounds(global_transform, Raster.shape_half_extents(region_shape, region_size))

## Profile value (0..1 multiplier) at normalized domain coordinate e (edge 0 -> center 1).
func sample_profile(e: float) -> float:
	return profile.sample(lerpf(profile.min_domain, profile.max_domain, e)) if profile else 1.0

## World Y of this field's profile datum, i.e. where `profile * profile_height` starts.
##
## Additive blends (ADD/SUBTRACT) add on top of the composite's `base_height`, so their datum
## moves with it; target blends (MAX/MIN/AVERAGE/REPLACE) set an absolute level and ignore it.
## `Curve` corridors use the route's own elevation at [param along] (0 = start, 1 = end);
## region/global domains fall back to the node height. The editor gizmos draw the footprint and
## cross-section here instead of at node-local y = 0.
func elevation_anchor_world_y(along: float = 0.5) -> float:
	var base := 0.0
	if TerrainTypes.is_delta_blend(blend_mode):
		var generator := get_generator()
		if generator is TerrainGenerator:
			base = generator.base_height
	if elevation_origin == TerrainTypes.ElevationOrigin.WORLD:
		return base + profile_offset
	if elevation_origin == TerrainTypes.ElevationOrigin.CURVE and domain_kind == TerrainTypes.DomainKind.CORRIDOR:
		var path := get_domain_path_node()
		if path != null and path.curve != null and path.curve.point_count >= 2:
			var path_xf: Transform3D = path.global_transform if path.is_inside_tree() else path.transform
			var length := path.curve.get_baked_length()
			var p := path.curve.sample_baked(length * clampf(along, 0.0, 1.0))
			return (path_xf * p).y + base + profile_offset
	return world_transform().origin.y + base + profile_offset
