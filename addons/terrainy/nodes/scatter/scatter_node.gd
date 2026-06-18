## Places PackedScene instances on top of the generated terrain.
## This node does not affect terrain height; instances are spawned post-build.
@tool
class_name ScatterNode
extends TerrainFeatureNode

const MIN_DENSITY := 0.0
const MIN_OVERLAP_SIZE := 0.01

@export_group("Scatter")

## Individual Instances: spawns full Node3D scenes (supports scripts, animation, complex hierarchies).
## MultiMesh (GPU): renders thousands of identical meshes in a single draw call. Only the first
## MeshInstance3D mesh is used; per-instance scripts/animation and nested material overrides are lost.
@export_enum("Individual Instances", "MultiMesh (GPU)") var render_mode: int = 0:
	set(value):
		render_mode = value
		_commit_parameter_change()

@export var scene: PackedScene:
	set(value):
		scene = value
		_commit_parameter_change()

## Deterministic random seed for placement.
@export var seed: int = 1:
	set(value):
		seed = value
		_commit_parameter_change()

## Placement density in instances per square meter.
@export_range(0.0, 1.0, 0.0001) var density: float = 0.0025:
	set(value):
		density = max(MIN_DENSITY, value)
		_commit_parameter_change()

## Safety clamps for generated instance count.
## Changing one bound auto-syncs the other (min cannot exceed max and vice versa)
## without triggering duplicate rebuild requests.
@export_range(0, 200000, 1) var min_instances: int = 0:
	set(value):
		var clamped: int = max(0, value)
		var new_min: int = clamped
		var new_max: int = max_instances
		if new_max > 0 and new_min > new_max:
			new_max = new_min
		_apply_instance_clamp(new_min, new_max)

@export_range(0, 200000, 1) var max_instances: int = 2500:
	set(value):
		var clamped: int = max(0, value)
		var new_max: int = clamped
		var new_min: int = min_instances
		if new_max > 0 and new_min > new_max:
			new_min = new_max
		_apply_instance_clamp(new_min, new_max)

## Guard flag preventing recursive entry from the cascade in either setter.
var _syncing_instance_clamp: bool = false

## Apply a coherent (min, max) pair, mutating the fields directly to avoid
## triggering the cross-setter cascade. Emits at most one parameter change.
func _apply_instance_clamp(new_min: int, new_max: int) -> void:
	if _syncing_instance_clamp:
		return
	if new_min == min_instances and new_max == max_instances:
		return
	_syncing_instance_clamp = true
	min_instances = new_min
	max_instances = new_max
	_syncing_instance_clamp = false
	_commit_parameter_change()

@export var allow_overlap: bool = true:
	set(value):
		allow_overlap = value
		_commit_parameter_change()

## Approximate overlap AABB size for one instance before random scaling.
@export var overlap_aabb_size: Vector3 = Vector3.ONE:
	set(value):
		overlap_aabb_size = Vector3(
			max(MIN_OVERLAP_SIZE, abs(value.x)),
			max(MIN_OVERLAP_SIZE, abs(value.y)),
			max(MIN_OVERLAP_SIZE, abs(value.z))
		)
		_commit_parameter_change()

@export var align_to_normal: bool = true:
	set(value):
		align_to_normal = value
		_commit_parameter_change()

@export_group("Rotation Variation (Degrees)")
@export var min_rotation_degrees: Vector3 = Vector3(0.0, 0.0, 0.0):
	set(value):
		min_rotation_degrees = value
		_commit_parameter_change()

@export var max_rotation_degrees: Vector3 = Vector3(0.0, 360.0, 0.0):
	set(value):
		max_rotation_degrees = value
		_commit_parameter_change()

@export_group("Scale Variation")
@export var min_scale: Vector3 = Vector3.ONE:
	set(value):
		min_scale = Vector3(
			max(0.001, value.x),
			max(0.001, value.y),
			max(0.001, value.z)
		)
		_commit_parameter_change()

@export var max_scale: Vector3 = Vector3.ONE:
	set(value):
		max_scale = Vector3(
			max(0.001, value.x),
			max(0.001, value.y),
			max(0.001, value.z)
		)
		_commit_parameter_change()

func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint() and name.is_empty():
		name = "Scatter"

## Hide heightmap-only properties from the inspector.
## Scatter nodes do not contribute to the heightmap composition, so the inherited
## blending, modifier, clamp, and self-mask properties are not meaningful here.
## Masks, when needed, come from a parent MaskTextureNode (see ScatterManager).
func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = []
	var hide := [
		"edge_falloff",
		"blend_mode",
		"strength",
		"smoothing",
		"smoothing_radius",
		"enable_terracing",
		"terrace_levels",
		"terrace_smoothness",
		"enable_min_clamp",
		"min_height",
		"enable_max_clamp",
		"max_height",
		"mask_texture",
		"mask_channel",
		"mask_invert"
	]
	for prop_name in hide:
		props.append({
			"name": prop_name,
			"type": TYPE_NIL,
			"usage": PROPERTY_USAGE_NO_EDITOR,
			"hint": PROPERTY_HINT_NONE
		})
	return props

## Validate scatter-specific configuration.
func _validate_subclass() -> bool:
	var is_valid := true
	if scene == null:
		push_warning("[%s] No scene assigned - scatter will produce no instances" % name)
	if density <= 0.0:
		push_warning("[%s] Density is zero - no instances will be placed" % name)
	if max_instances > 0 and min_instances > max_instances:
		push_warning("[%s] min_instances (%d) is greater than max_instances (%d)" % [name, min_instances, max_instances])
		is_valid = false
	return is_valid

func get_height_at_safe(_world_pos: Vector3, _context: EvaluationContext) -> float:
	return 0.0

func affects_heightmap() -> bool:
	return false

func get_gpu_param_pack() -> Dictionary:
	return _build_gpu_param_pack(FeatureType.SCATTER, PackedFloat32Array(), PackedInt32Array())

func get_rotation_radians(rng: RandomNumberGenerator) -> Vector3:
	var min_rot = min_rotation_degrees
	var max_rot = max_rotation_degrees
	return Vector3(
		deg_to_rad(rng.randf_range(min(min_rot.x, max_rot.x), max(min_rot.x, max_rot.x))),
		deg_to_rad(rng.randf_range(min(min_rot.y, max_rot.y), max(min_rot.y, max_rot.y))),
		deg_to_rad(rng.randf_range(min(min_rot.z, max_rot.z), max(min_rot.z, max_rot.z)))
	)

func get_random_scale(rng: RandomNumberGenerator) -> Vector3:
	return Vector3(
		rng.randf_range(min(min_scale.x, max_scale.x), max(min_scale.x, max_scale.x)),
		rng.randf_range(min(min_scale.y, max_scale.y), max(min_scale.y, max_scale.y)),
		rng.randf_range(min(min_scale.z, max_scale.z), max(min_scale.z, max_scale.z))
	)

func get_overlap_half_extents(random_scale: Vector3) -> Vector3:
	return Vector3(
		overlap_aabb_size.x * abs(random_scale.x) * 0.5,
		overlap_aabb_size.y * abs(random_scale.y) * 0.5,
		overlap_aabb_size.z * abs(random_scale.z) * 0.5
	)
