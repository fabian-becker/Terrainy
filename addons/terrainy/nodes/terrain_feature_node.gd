@tool
class_name TerrainFeatureNode
extends Node3D

## Base class for all terrain feature nodes that can be positioned and blended

signal parameters_changed

enum InfluenceShape {
	CIRCLE,
	RECTANGLE,
	ELLIPSE
}

enum SmoothingMode {
	NONE,
	LIGHT,
	MEDIUM,
	HEAVY
}

enum BlendMode {
	ADD,
	SUBTRACT,
	MAX,
	MIN,
	MULTIPLY,
	AVERAGE
}

## Shape of the influence area
@export var influence_shape: InfluenceShape = InfluenceShape.CIRCLE:
	set(value):
		influence_shape = value
		_commit_parameter_change()

## The size of this terrain feature's area of influence (radius for circle, width/depth for others)
@export var influence_size: Vector2 = Vector2(50.0, 50.0):
	set(value):
		influence_size = value
		_commit_parameter_change()

## Falloff distance for blending at edges (0.0 = hard edge, 1.0 = smooth across full radius)
@export_range(0.0, 1.0) var edge_falloff: float = 0.3:
	set(value):
		edge_falloff = value
		_commit_parameter_change()

## Blend mode with other terrain features
@export_enum("Add", "Max", "Min", "Multiply", "Average") var blend_mode: int = 0:
	set(value):
		blend_mode = value
		_commit_parameter_change()

## Weight/strength of this feature (0.0 = invisible, 1.0 = full strength)
@export_range(0.0, 2.0) var strength: float = 1.0:
	set(value):
		strength = value
		_commit_parameter_change()

@export_group("Modifiers")

## Smoothing level to apply to the terrain feature
@export var smoothing: SmoothingMode = SmoothingMode.NONE:
	set(value):
		smoothing = value
		_smoothing_cache.clear()
		_commit_parameter_change()

## Smoothing radius (in world units) - larger values = more smoothing
@export_range(0.5, 10.0) var smoothing_radius: float = 2.0:
	set(value):
		smoothing_radius = value
		_smoothing_cache.clear()
		_commit_parameter_change()

## Enable terracing effect (creates stepped layers)
@export var enable_terracing: bool = false:
	set(value):
		enable_terracing = value
		_commit_parameter_change()

## Number of terrace levels
@export_range(2, 20) var terrace_levels: int = 5:
	set(value):
		terrace_levels = value
		_commit_parameter_change()

## Smoothness of terrace transitions (0.0 = hard steps, 1.0 = smooth)
@export_range(0.0, 1.0) var terrace_smoothness: float = 0.2:
	set(value):
		terrace_smoothness = value
		_commit_parameter_change()

## Clamp minimum height
@export var enable_min_clamp: bool = false:
	set(value):
		enable_min_clamp = value
		_commit_parameter_change()

@export var min_height: float = 0.0:
	set(value):
		min_height = value
		_commit_parameter_change()

## Clamp maximum height
@export var enable_max_clamp: bool = false:
	set(value):
		enable_max_clamp = value
		_commit_parameter_change()

@export var max_height: float = 100.0:
	set(value):
		max_height = value
		_commit_parameter_change()

# Cache for smoothed height values
var _smoothing_cache: Dictionary = {}

## Generate height value at a given world position
## Override this in derived classes
func get_height_at(world_pos: Vector3) -> float:
	return 0.0

## Thread-safe version: Generate height from pre-computed local AND world position
## This avoids calling to_local() which requires main thread
## Override this in derived classes for thread-safe parallel processing
func get_height_at_safe(world_pos: Vector3, local_pos: Vector3) -> float:
	# Default: just call regular version (derived classes should override)
	return get_height_at(world_pos)

## Get the influence weight at a given world position (0.0 to 1.0)
## Based on distance from center and falloff settings
func get_influence_weight(world_pos: Vector3) -> float:
	if not is_inside_tree():
		return 0.0
	
	var local_pos = to_local(world_pos)
	var local_pos_2d = Vector2(local_pos.x, local_pos.z)
	
	var distance: float
	var max_distance: float
	
	match influence_shape:
		InfluenceShape.CIRCLE:
			# Use X component as radius for circular shape
			distance = local_pos_2d.length()
			max_distance = influence_size.x
		
		InfluenceShape.RECTANGLE:
			# Check if inside rectangle bounds
			var half_size = influence_size * 0.5
			if abs(local_pos_2d.x) > half_size.x or abs(local_pos_2d.y) > half_size.y:
				return 0.0
			
			# Distance to nearest edge
			var dist_x = half_size.x - abs(local_pos_2d.x)
			var dist_y = half_size.y - abs(local_pos_2d.y)
			distance = min(dist_x, dist_y)
			max_distance = min(half_size.x, half_size.y)
		
		InfluenceShape.ELLIPSE:
			# Ellipse distance formula
			var normalized = Vector2(
				local_pos_2d.x / influence_size.x,
				local_pos_2d.y / influence_size.y
			)
			distance = normalized.length()
			max_distance = 1.0
			
			if distance >= max_distance:
				return 0.0
	
	if influence_shape == InfluenceShape.CIRCLE or influence_shape == InfluenceShape.ELLIPSE:
		if distance >= max_distance:
			return 0.0
	
	if edge_falloff <= 0.0:
		return 1.0
	
	# Calculate falloff
	var falloff_distance: float
	if influence_shape == InfluenceShape.RECTANGLE:
		# For rectangle, distance is already the distance to edge
		falloff_distance = max_distance * edge_falloff
		if distance > falloff_distance:
			return 1.0
		var t = distance / falloff_distance
		return smoothstep(0.0, 1.0, t)
	else:
		# For circle and ellipse
		var falloff_start = max_distance * (1.0 - edge_falloff)
		if distance < falloff_start:
			return 1.0
		var t = (distance - falloff_start) / (max_distance - falloff_start)
		return 1.0 - smoothstep(0.0, 1.0, t)

## Get the final blended height contribution at a position
func get_blended_height_at(world_pos: Vector3) -> float:
	var height = get_height_at(world_pos)
	
	# Apply modifiers
	height = _apply_modifiers(world_pos, height)
	
	var weight = get_influence_weight(world_pos)
	return height * weight * strength

## Apply all enabled modifiers to the height value
func _apply_modifiers(world_pos: Vector3, base_height: float) -> float:
	var height = base_height
	
	# Apply smoothing
	if smoothing != SmoothingMode.NONE:
		height = _apply_smoothing(world_pos, height)
	
	# Apply terracing
	if enable_terracing:
		height = _apply_terracing(height)
	
	# Apply height clamping
	if enable_min_clamp:
		height = max(height, min_height)
	if enable_max_clamp:
		height = min(height, max_height)
	
	return height

## Apply smoothing to the height value
func _apply_smoothing(world_pos: Vector3, center_height: float) -> float:
	# Cache key based on position (rounded to improve cache hits)
	var grid_size = smoothing_radius * 0.5
	var cache_key = Vector3i(
		int(world_pos.x / grid_size),
		0,
		int(world_pos.z / grid_size)
	)
	
	if _smoothing_cache.has(cache_key):
		return _smoothing_cache[cache_key]
	
	var sample_count: int
	var sample_radius: float
	
	match smoothing:
		SmoothingMode.LIGHT:
			sample_count = 4
			sample_radius = smoothing_radius * 0.5
		SmoothingMode.MEDIUM:
			sample_count = 8
			sample_radius = smoothing_radius
		SmoothingMode.HEAVY:
			sample_count = 12
			sample_radius = smoothing_radius * 1.5
		_:
			return center_height
	
	# Gather samples in a circle around the position
	var total_height = center_height
	var total_weight = 1.0
	
	for i in range(sample_count):
		var angle = (i / float(sample_count)) * TAU
		var offset = Vector3(
			cos(angle) * sample_radius,
			0,
			sin(angle) * sample_radius
		)
		var sample_pos = world_pos + offset
		
		# Get raw height without smoothing to avoid infinite recursion
		var sample_height = get_height_at(sample_pos)
		
		# Weight samples by distance (closer = more weight)
		var weight = 1.0 - (offset.length() / (sample_radius * 1.5))
		weight = max(0.0, weight)
		
		total_height += sample_height * weight
		total_weight += weight
	
	var smoothed_height = total_height / total_weight
	_smoothing_cache[cache_key] = smoothed_height
	
	return smoothed_height

## Apply terracing effect to create stepped layers
func _apply_terracing(height: float) -> float:
	if terrace_levels <= 1:
		return height
	
	# Normalize height to 0-1 range for easier calculation
	# Assuming typical height range - adjust if needed
	var normalized_height = height / 100.0
	
	# Calculate which terrace level this falls into
	var level = floor(normalized_height * terrace_levels)
	var level_height = level / float(terrace_levels)
	
	if terrace_smoothness > 0.0:
		# Smooth transition between levels
		var next_level_height = (level + 1.0) / float(terrace_levels)
		var t = (normalized_height * terrace_levels) - level
		t = smoothstep(0.0, 1.0, t / terrace_smoothness)
		level_height = lerp(level_height, next_level_height, t)
	
	return level_height * 100.0

## Get axis-aligned bounding box of influence area
func get_influence_aabb() -> AABB:
	var half_size: Vector2
	if influence_shape == InfluenceShape.CIRCLE:
		half_size = Vector2(influence_size.x, influence_size.x)
	else:
		half_size = influence_size * 0.5
	
	return AABB(
		global_position + Vector3(-half_size.x, -100, -half_size.y),
		Vector3(half_size.x * 2.0, 200, half_size.y * 2.0)
	)

## Helper to check if gizmo is currently manipulating this node
func _is_gizmo_manipulating() -> bool:
	var is_manipulating = get_meta("_gizmo_manipulating", false)
	
	# Safety: if gizmo manipulation flag has been set for more than 5 seconds, clear it
	# This prevents stuck metadata from blocking updates
	if is_manipulating:
		var last_gizmo_time = get_meta("_gizmo_manipulation_time", 0.0)
		var current_time = Time.get_ticks_msec() / 1000.0
		if current_time - last_gizmo_time > 5.0:
			set_meta("_gizmo_manipulating", false)
			return false
	
	return is_manipulating

## Helper to emit parameters_changed signal only when not manipulating via gizmo
func _commit_parameter_change() -> void:
	if not _is_gizmo_manipulating():
		parameters_changed.emit()
		if Engine.is_editor_hint():
			print("[%s] parameters_changed emitted" % name)
