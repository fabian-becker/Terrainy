@tool
@abstract
class_name TerrainFeatureNode
extends Node3D

const GpuHeightmapModifier = preload("res://addons/terrainy/helpers/gpu_heightmap_modifier.gd")
const EvaluationContext = preload("res://addons/terrainy/nodes/evaluation_context.gd")

## Base class for all terrain feature nodes that can be positioned and blended

signal parameters_changed

# Constants
const GIZMO_MANIPULATION_TIMEOUT_SEC = 5.0
const MIN_INFLUENCE_SIZE = 0.01

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

const GPU_PARAM_VERSION: int = 1

enum FeatureType {
	UNKNOWN = 0,
	PRIMITIVE_HILL = 100,
	PRIMITIVE_MOUNTAIN = 101,
	PRIMITIVE_CRATER = 102,
	PRIMITIVE_VOLCANO = 103,
	PRIMITIVE_ISLAND = 104,
	WATER = 150,
	SHAPE = 200,
	HEIGHTMAP = 210,
	GRADIENT_LINEAR = 300,
	GRADIENT_RADIAL = 301,
	GRADIENT_CONE = 302,
	GRADIENT_HEMISPHERE = 303,
	LANDSCAPE_CANYON = 400,
	LANDSCAPE_MOUNTAIN_RANGE = 401,
	LANDSCAPE_DUNE_SEA = 402,
	NOISE_PERLIN = 500,
	NOISE_VORONOI = 501,
	HOLE = 600,
	SCATTER = 700,
	MASK_TEXTURE = 800
}

## Shape of the influence area
@export var influence_shape: InfluenceShape = InfluenceShape.CIRCLE:
	set(value):
		influence_shape = value
		_commit_parameter_change()

## The size of this terrain feature's area of influence (full width/depth for all shapes)
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
@export_enum("Add", "Subtract", "Max", "Min", "Multiply", "Average") var blend_mode: int = 0:
	set(value):
		blend_mode = value
		_commit_parameter_change()

## Weight/strength of this feature (0.0 = invisible, 1.0 = full strength)
@export_range(0.0, 2.0) var strength: float = 1.0:
	set(value):
		strength = value
		_commit_parameter_change()

@export_group("Mask Texture")

## Optional texture used to mask this feature's influence. White = full influence, black = no influence.
@export var mask_texture: Texture2D:
	set(value):
		_disconnect_mask_texture()
		mask_texture = value
		_connect_mask_texture()
		_invalidate_mask_cache()
		_commit_parameter_change()

## Invert the mask texture (black = full influence, white = no influence)
@export var mask_invert: bool = false:
	set(value):
		mask_invert = value
		_commit_parameter_change()

## Channel to read from the mask texture for grayscale conversion
@export_enum("Luminance", "Red", "Green", "Blue", "Alpha") var mask_channel: int = 0:
	set(value):
		mask_channel = value
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

# Internal cache for heightmap generation
var _heightmap_dirty: bool = true
var _cached_heightmap: Image = null
var _cached_resolution: Vector2i = Vector2i.ZERO
var _cached_bounds: Rect2 = Rect2()

# Cache for mask texture data
var _cached_mask_data: PackedFloat32Array = PackedFloat32Array()
var _cached_mask_size: Vector2i = Vector2i.ZERO
var _mask_data_dirty: bool = true

# GPU modifier processor (shared across all features)
static var _gpu_modifier_processor: GpuHeightmapModifier = null
static var _feature_reference_count: int = 0

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_disconnect_mask_texture()
		_feature_reference_count -= 1
		if _feature_reference_count <= 0 and _gpu_modifier_processor:
			# Clean up GPU resources when last feature is destroyed
			if _gpu_modifier_processor.has_method("cleanup"):
				_gpu_modifier_processor.cleanup()
			_gpu_modifier_processor = null
			_feature_reference_count = 0
	elif what == NOTIFICATION_TRANSFORM_CHANGED:
		# Notify parent TerrainComposer when position/rotation/scale changes
		_commit_parameter_change()

func _ready() -> void:
	_feature_reference_count += 1
	set_notify_transform(true)

static func _get_gpu_modifier_processor() -> GpuHeightmapModifier:
	if not RenderingServer.get_rendering_device():
		return null
	if not _gpu_modifier_processor:
		_gpu_modifier_processor = GpuHeightmapModifier.new()
		if not _gpu_modifier_processor.is_available():
			push_warning("[TerrainFeatureNode] GPU modifiers unavailable")
	return _gpu_modifier_processor

## Prepare an immutable evaluation context for thread-safe evaluation.
## Override this in derived classes to capture additional parameters.
func prepare_evaluation_context() -> EvaluationContext:
	return EvaluationContext.from_feature(self)

## Generate height value at a given world position using pre-computed context.
## This avoids calling to_local() or accessing scene tree in worker threads.
## Override this in derived classes - REQUIRED for all terrain features.
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	push_error("[%s] get_height_at_safe() must be overridden by derived classes" % get_class())
	return 0.0

## Get influence weight using pre-computed context.
## This avoids calling to_local() or accessing scene tree in worker threads.
## Override _get_raw_influence_weight() in derived classes for custom weight computation.
func get_influence_weight_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var weight = _get_raw_influence_weight(world_pos, context)
	if weight <= 0.0:
		return 0.0

	var mask_value = _sample_mask_texture(world_pos, context)
	return weight * mask_value

## Computes the raw influence weight before mask texture is applied.
## Override in derived classes (e.g. HoleNode, MaskTextureNode) to customize base weight computation.
func _get_raw_influence_weight(world_pos: Vector3, context: EvaluationContext) -> float:
	return context.get_influence_weight(world_pos)

## Whether this feature contributes to the terrain heightmap composition.
## Override in non-height features (for example scatter/object placement nodes).
func affects_heightmap() -> bool:
	return true

## GPU parameter pack for compute kernels (versioned layout)
func get_gpu_param_pack() -> Dictionary:
	return _build_gpu_param_pack(FeatureType.UNKNOWN, PackedFloat32Array(), PackedInt32Array())

func _build_gpu_param_pack(feature_type: int, extra_floats: PackedFloat32Array, extra_ints: PackedInt32Array) -> Dictionary:
	var floats = _get_gpu_base_floats()
	if not extra_floats.is_empty():
		floats.append_array(extra_floats)
	var ints = _get_gpu_base_ints()
	if not extra_ints.is_empty():
		ints.append_array(extra_ints)
	return {
		"version": GPU_PARAM_VERSION,
		"type": feature_type,
		"floats": floats,
		"ints": ints
	}

func _get_gpu_base_floats() -> PackedFloat32Array:
	var inv = global_transform.affine_inverse()
	var floats := PackedFloat32Array()
	floats.append_array([
		global_position.x,
		global_position.y,
		global_position.z,
		influence_size.x,
		influence_size.y,
		edge_falloff,
		strength,
		inv.basis.x.x, inv.basis.x.y, inv.basis.x.z,
		inv.basis.y.x, inv.basis.y.y, inv.basis.y.z,
		inv.basis.z.x, inv.basis.z.y, inv.basis.z.z,
		inv.origin.x, inv.origin.y, inv.origin.z
	])
	return floats

func _get_gpu_base_ints() -> PackedInt32Array:
	var ints := PackedInt32Array()
	ints.append(influence_shape)
	ints.append(blend_mode)
	return ints

## Generate a heightmap for this feature
## This is the new primary method for terrain generation
func generate_heightmap(resolution: Vector2i, terrain_bounds: Rect2) -> Image:
	# Check cache validity
	if not _heightmap_dirty and \
	   _cached_heightmap != null and \
	   _cached_resolution == resolution and \
	   _cached_bounds == terrain_bounds:
		return _cached_heightmap
	
	var start_time = Time.get_ticks_msec()
	
	# Calculate step size
	var step_x := terrain_bounds.size.x / float(resolution.x - 1)
	var step_y := terrain_bounds.size.y / float(resolution.y - 1)
	var origin_x := terrain_bounds.position.x
	var origin_z := terrain_bounds.position.y
	
	# Pre-allocate height data array
	var total_pixels := resolution.x * resolution.y
	var height_data := PackedFloat32Array()
	height_data.resize(total_pixels)
	
	# Prepare context for this feature
	var context = prepare_evaluation_context()
	
	# Generate RAW heightmap using context (thread-safe)
	var idx := 0
	for y in resolution.y:
		var world_z := origin_z + (y * step_y)
		for x in resolution.x:
			var world_x := origin_x + (x * step_x)
			var world_pos := Vector3(world_x, 0, world_z)
			
			# Get raw height using context (no modifiers yet)
			height_data[idx] = get_height_at_safe(world_pos, context)
			idx += 1
	
	# Create heightmap image from packed array
	var heightmap := Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, height_data.to_byte_array())
	
	# Apply modifiers (GPU if available, CPU fallback)
	if _has_any_modifiers():
		var processor = _get_gpu_modifier_processor()
		if processor and processor.is_available():
			# Apply modifiers on GPU
			var modified = processor.apply_modifiers(
				heightmap,
				int(smoothing),
				smoothing_radius,
				enable_terracing,
				terrace_levels,
				terrace_smoothness,
				enable_min_clamp,
				min_height,
				enable_max_clamp,
				max_height
			)
			if modified:
				heightmap = modified
			else:
				# GPU failed, fall back to CPU
				_apply_modifiers_cpu(heightmap, terrain_bounds)
		else:
			# No GPU, use CPU
			_apply_modifiers_cpu(heightmap, terrain_bounds)
	
	# Update cache
	_cached_heightmap = heightmap
	_cached_resolution = resolution
	_cached_bounds = terrain_bounds
	_heightmap_dirty = false
	
	var elapsed = Time.get_ticks_msec() - start_time
	if Engine.is_editor_hint():
		print("[%s] Generated %dx%d heightmap in %d ms" % [name, resolution.x, resolution.y, elapsed])
	
	return heightmap

## Generate a heightmap using a pre-computed context (thread-safe).
## This version can be called from worker threads without scene tree access.
func generate_heightmap_with_context(resolution: Vector2i, terrain_bounds: Rect2, context: EvaluationContext) -> Image:
	# Cache is only valid on main thread, so skip caching for context-based generation
	var start_time = Time.get_ticks_msec()
	
	# Calculate step size
	var step_x := terrain_bounds.size.x / float(resolution.x - 1)
	var step_y := terrain_bounds.size.y / float(resolution.y - 1)
	var origin_x := terrain_bounds.position.x
	var origin_z := terrain_bounds.position.y
	
	# Pre-allocate height data array
	var total_pixels := resolution.x * resolution.y
	var height_data := PackedFloat32Array()
	height_data.resize(total_pixels)
	
	# Generate RAW heightmap using thread-safe context
	var idx := 0
	for y in resolution.y:
		var world_z := origin_z + (y * step_y)
		for x in resolution.x:
			var world_x := origin_x + (x * step_x)
			var world_pos := Vector3(world_x, 0, world_z)
			
			# Use thread-safe method with context
			height_data[idx] = get_height_at_safe(world_pos, context)
			idx += 1
	
	# Create heightmap image from packed array
	var heightmap := Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, height_data.to_byte_array())
	
	# Apply modifiers (CPU-only for thread safety)
	if _has_any_modifiers():
		_apply_modifiers_cpu(heightmap, terrain_bounds, context)
	
	if Engine.is_editor_hint():
		var elapsed = Time.get_ticks_msec() - start_time
		print("[%s] Generated %dx%d heightmap (context) in %d ms" % [name, resolution.x, resolution.y, elapsed])
	
	return heightmap

## Generate a heightmap using a pre-computed context without applying modifiers.
## Intended for worker threads where modifiers will be applied later on main thread.
func generate_heightmap_with_context_raw(resolution: Vector2i, terrain_bounds: Rect2, context: EvaluationContext) -> Image:
	var start_time = Time.get_ticks_msec()
	var step_x := terrain_bounds.size.x / float(resolution.x - 1)
	var step_y := terrain_bounds.size.y / float(resolution.y - 1)
	var origin_x := terrain_bounds.position.x
	var origin_z := terrain_bounds.position.y

	var total_pixels := resolution.x * resolution.y
	var height_data := PackedFloat32Array()
	height_data.resize(total_pixels)

	var idx := 0
	for y in resolution.y:
		var world_z := origin_z + (y * step_y)
		for x in resolution.x:
			var world_x := origin_x + (x * step_x)
			var world_pos := Vector3(world_x, 0, world_z)
			height_data[idx] = get_height_at_safe(world_pos, context)
			idx += 1

	var heightmap := Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, height_data.to_byte_array())

	if Engine.is_editor_hint():
		var elapsed = Time.get_ticks_msec() - start_time
		print("[%s] Generated %dx%d heightmap (context raw) in %d ms" % [name, resolution.x, resolution.y, elapsed])

	return heightmap

## Apply modifiers to an existing heightmap (GPU if available, CPU fallback)
func apply_modifiers_to_heightmap(heightmap: Image, terrain_bounds: Rect2, context: EvaluationContext = null) -> Image:
	if not _has_any_modifiers():
		return heightmap

	var processor = _get_gpu_modifier_processor()
	if processor and processor.is_available():
		var modified = processor.apply_modifiers(
			heightmap,
			int(smoothing),
			smoothing_radius,
			enable_terracing,
			terrace_levels,
			terrace_smoothness,
			enable_min_clamp,
			min_height,
			enable_max_clamp,
			max_height
		)
		if modified:
			return modified

	_apply_modifiers_cpu(heightmap, terrain_bounds, context)
	return heightmap

## Check if any modifiers are enabled
func _has_any_modifiers() -> bool:
	return smoothing != SmoothingMode.NONE or \
		   enable_terracing or \
		   enable_min_clamp or \
		   enable_max_clamp

## Apply modifiers on CPU (fallback)
func _apply_modifiers_cpu(heightmap: Image, terrain_bounds: Rect2, context_override: EvaluationContext = null) -> void:
	var resolution := Vector2i(heightmap.get_width(), heightmap.get_height())
	var step_x := terrain_bounds.size.x / float(resolution.x - 1)
	var step_y := terrain_bounds.size.y / float(resolution.y - 1)
	var origin_x := terrain_bounds.position.x
	var origin_z := terrain_bounds.position.y
	
	# Prepare context once for all pixels (use provided context when thread-safe)
	var context = context_override if context_override != null else prepare_evaluation_context()
	
	# Read all heights at once
	var height_data := heightmap.get_data().to_float32_array()
	
	var idx := 0
	for y in resolution.y:
		var world_z := origin_z + (y * step_y)
		for x in resolution.x:
			var world_x := origin_x + (x * step_x)
			var world_pos := Vector3(world_x, 0, world_z)
			
			height_data[idx] = _apply_modifiers(world_pos, height_data[idx], context)
			idx += 1
	
	# Create new image from modified data
	var modified := Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, height_data.to_byte_array())
	heightmap.copy_from(modified)

## Mark heightmap as dirty (needs regeneration)
func mark_dirty() -> void:
	_heightmap_dirty = true
	_cached_heightmap = null

## Check if heightmap needs regeneration
func is_dirty() -> bool:
	return _heightmap_dirty

## Get the final blended height contribution at a position (for editor/gizmos)
func get_blended_height_at(world_pos: Vector3) -> float:
	var context = prepare_evaluation_context()
	var height = get_height_at_safe(world_pos, context)
	
	# Apply modifiers
	height = _apply_modifiers(world_pos, height, context)
	
	var weight = get_influence_weight_safe(world_pos, context)
	return height * weight * strength

## Apply all enabled modifiers to the height value
func _apply_modifiers(world_pos: Vector3, base_height: float, context: EvaluationContext) -> float:
	var height = base_height
	
	# Apply smoothing
	if smoothing != SmoothingMode.NONE:
		height = _apply_smoothing(world_pos, height, context)
	
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
func _apply_smoothing(world_pos: Vector3, center_height: float, context: EvaluationContext) -> float:
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
		var sample_height = get_height_at_safe(sample_pos, context)
		
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
	match influence_shape:
		InfluenceShape.CIRCLE:
			var radius = max(influence_size.x, influence_size.y) * 0.5
			half_size = Vector2(radius, radius)
		InfluenceShape.ELLIPSE:
			half_size = influence_size * 0.5
		_:
			half_size = influence_size * 0.5
	
	return AABB(
		global_position + Vector3(-half_size.x, -100, -half_size.y),
		Vector3(half_size.x * 2.0, 200, half_size.y * 2.0)
	)

## Helper to check if gizmo is currently manipulating this node
func _is_gizmo_manipulating() -> bool:
	var is_manipulating = get_meta("_gizmo_manipulating", false)
	
	# Safety: if gizmo manipulation flag has been set for more than threshold, clear it
	# This prevents stuck metadata from blocking updates
	if is_manipulating:
		var last_gizmo_time = get_meta("_gizmo_manipulation_time", 0.0)
		var current_time = Time.get_ticks_msec() / 1000.0
		if current_time - last_gizmo_time > GIZMO_MANIPULATION_TIMEOUT_SEC:
			set_meta("_gizmo_manipulating", false)
			return false
	
	return is_manipulating

## Helper to emit parameters_changed signal only when not manipulating via gizmo
func _commit_parameter_change() -> void:
	_smoothing_cache.clear()
	_heightmap_dirty = true
	_cached_heightmap = null
	if not _is_gizmo_manipulating():
		parameters_changed.emit()

## Validate node configuration
func validate_configuration() -> bool:
	var is_valid = true
	
	if influence_size.x < MIN_INFLUENCE_SIZE or influence_size.y < MIN_INFLUENCE_SIZE:
		push_warning("[%s] Influence size too small, clamping to minimum" % name)
		influence_size = influence_size.max(Vector2(MIN_INFLUENCE_SIZE, MIN_INFLUENCE_SIZE))
		is_valid = false
	
	if strength <= 0.0:
		push_warning("[%s] Strength is zero or negative, feature will have no effect" % name)
	
	if "height" in self:
		var height_value = get("height")
		if abs(height_value) < 0.001:
			push_warning("[%s] Height is near zero, feature may not be visible" % name)
	
	return is_valid


## Returns true if this feature has a mask texture assigned.
func has_mask_texture() -> bool:
	return mask_texture != null

## Sample the mask texture at a world position using the context's inverse transform.
## Uses context-provided mask data when available (thread-safe), otherwise falls back
## to node state (main-thread only).
func _sample_mask_texture(world_pos: Vector3, context: EvaluationContext) -> float:
	var mask_data: PackedFloat32Array
	var mask_size: Vector2i
	var invert: bool
	
	# Thread-safe path: use baked mask data from context
	if not context.mask_data.is_empty() and context.mask_size.x > 0 and context.mask_size.y > 0:
		mask_data = context.mask_data
		mask_size = context.mask_size
		invert = context.mask_invert
	else:
		# Main-thread fallback: read from node state
		if mask_texture == null:
			return 1.0
		
		mask_data = _get_mask_data()
		if mask_data.is_empty():
			return 1.0
		mask_size = _cached_mask_size
		invert = mask_invert
	
	var local_pos = context.to_local(world_pos)
	var size = context.influence_size
	if size.x <= 0.0 or size.y <= 0.0:
		return 1.0
	
	var u = (local_pos.x / size.x) + 0.5
	var v = (local_pos.z / size.y) + 0.5
	u = clampf(u, 0.0, 1.0)
	v = clampf(v, 0.0, 1.0)
	
	var x = u * float(mask_size.x - 1)
	var y = v * float(mask_size.y - 1)
	var x0 = int(floor(x))
	var y0 = int(floor(y))
	var x1 = mini(x0 + 1, mask_size.x - 1)
	var y1 = mini(y0 + 1, mask_size.y - 1)
	var dx = x - float(x0)
	var dy = y - float(y0)
	
	var idx00 = y0 * mask_size.x + x0
	var idx10 = y0 * mask_size.x + x1
	var idx01 = y1 * mask_size.x + x0
	var idx11 = y1 * mask_size.x + x1
	
	var h00 = mask_data[idx00]
	var h10 = mask_data[idx10]
	var h01 = mask_data[idx01]
	var h11 = mask_data[idx11]
	
	var h0 = lerp(h00, h10, dx)
	var h1 = lerp(h01, h11, dx)
	var value = lerp(h0, h1, dy)
	
	if invert:
		value = 1.0 - value
	
	return value

func _get_mask_data() -> PackedFloat32Array:
	## Must only be called from the main thread (or under a mutex guard).
	## This method mutates node state; worker threads must use context.mask_data instead.
	if not _mask_data_dirty and not _cached_mask_data.is_empty():
		return _cached_mask_data
	
	_cached_mask_data = PackedFloat32Array()
	_cached_mask_size = Vector2i.ZERO
	_mask_data_dirty = false
	
	if mask_texture == null:
		return _cached_mask_data
	
	var img = mask_texture.get_image()
	if img == null:
		var texture_path = mask_texture.resource_path
		var texture_class = mask_texture.get_class()
		
		# Try loading from resource_path as fallback
		if mask_texture is CompressedTexture2D or mask_texture is ImageTexture:
			if not texture_path.is_empty():
				var loaded_image = Image.load_from_file(texture_path)
				if loaded_image != null:
					img = loaded_image
				else:
					push_warning("[%s] Failed to load mask image from disk fallback '%s' (type %s)" % [name, texture_path, texture_class])
			else:
				push_warning("[%s] Mask texture has no resource_path and cannot be loaded from disk (type %s)" % [name, texture_class])
		else:
			push_warning("[%s] Mask texture '%s' (type %s) could not be read. Procedural textures (NoiseTexture, ViewportTexture, etc.) are not supported as masks." % [name, texture_path, texture_class])
		
		if img == null:
			return _cached_mask_data
	
	# Convert to RGBA8 for safe channel extraction
	if img.get_format() != Image.FORMAT_RGBA8:
		img = img.duplicate()
		img.convert(Image.FORMAT_RGBA8)
	
	var width = img.get_width()
	var height = img.get_height()
	var data = img.get_data()
	var count = width * height
	
	var grayscale = PackedFloat32Array()
	grayscale.resize(count)
	
	for i in range(count):
		var offset = i * 4
		var r = data[offset] / 255.0
		var g = data[offset + 1] / 255.0
		var b = data[offset + 2] / 255.0
		var a = data[offset + 3] / 255.0
		
		var value: float
		match mask_channel:
			1: value = r
			2: value = g
			3: value = b
			4: value = a
			_: value = (r * 0.299) + (g * 0.587) + (b * 0.114)
		
		grayscale[i] = clampf(value, 0.0, 1.0)
	
	_cached_mask_data = grayscale
	_cached_mask_size = Vector2i(width, height)
	return _cached_mask_data

func _connect_mask_texture() -> void:
	if mask_texture and not mask_texture.changed.is_connected(_on_mask_texture_changed):
		mask_texture.changed.connect(_on_mask_texture_changed)

func _disconnect_mask_texture() -> void:
	if mask_texture and mask_texture.changed.is_connected(_on_mask_texture_changed):
		mask_texture.changed.disconnect(_on_mask_texture_changed)

func _on_mask_texture_changed() -> void:
	_invalidate_mask_cache()
	_commit_parameter_change()

func _invalidate_mask_cache() -> void:
	_cached_mask_data = PackedFloat32Array()
	_cached_mask_size = Vector2i.ZERO
	_mask_data_dirty = true
