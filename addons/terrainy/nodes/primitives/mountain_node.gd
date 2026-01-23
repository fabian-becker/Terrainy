@tool
class_name MountainNode
extends PrimitiveNode

const PrimitiveNode = preload("res://addons/terrainy/nodes/primitives/primitive_node.gd")
const PrimitiveEvaluationContext = preload("res://addons/terrainy/nodes/primitives/primitive_evaluation_context.gd")

## A mountain terrain feature with various peak types and noise detail

@export_enum("Sharp", "Rounded", "Plateau") var peak_type: int = 0:
	set(value):
		peak_type = value
		parameters_changed.emit()

@export var noise: FastNoiseLite:
	set(value):
		noise = value
		if noise and not noise.changed.is_connected(_on_noise_changed):
			noise.changed.connect(_on_noise_changed)
		parameters_changed.emit()

@export var noise_strength: float = 0.15:
	set(value):
		noise_strength = clamp(value, 0.0, 1.0)
		parameters_changed.emit()

func _ready() -> void:
	if not noise:
		self.noise = FastNoiseLite.new()
		noise.seed = randi()
		noise.frequency = 0.02
		noise.noise_type = FastNoiseLite.TYPE_PERLIN

func _on_noise_changed() -> void:
	parameters_changed.emit()

func prepare_evaluation_context() -> PrimitiveEvaluationContext:
	var ctx = PrimitiveEvaluationContext.from_primitive_feature(self, height, peak_type)
	ctx.mountain_peak_type = peak_type
	ctx.noise = noise
	ctx.noise_strength = noise_strength
	return ctx

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

## Optimized heightmap generation (avoids per-pixel to_local)
func generate_heightmap(resolution: Vector2i, terrain_bounds: Rect2) -> Image:
	var start_time = Time.get_ticks_msec()

	var step_x := terrain_bounds.size.x / float(resolution.x - 1)
	var step_z := terrain_bounds.size.y / float(resolution.y - 1)
	var origin_x := terrain_bounds.position.x
	var origin_z := terrain_bounds.position.y

	var total_pixels := resolution.x * resolution.y
	var height_data := PackedFloat32Array()
	height_data.resize(total_pixels)

	var inv_transform := global_transform.affine_inverse()
	var basis := inv_transform.basis
	var inv_origin := inv_transform.origin

	var radius := influence_size.x
	var radius_sq := radius * radius

	var idx := 0
	for y in resolution.y:
		var world_z := origin_z + (y * step_z)
		for x in resolution.x:
			var world_x := origin_x + (x * step_x)

			# Inline local position transform (world y assumed 0)
			var local_x := basis.x.x * world_x + basis.x.z * world_z + inv_origin.x
			var local_z := basis.z.x * world_x + basis.z.z * world_z + inv_origin.z

			var dist_sq := (local_x * local_x) + (local_z * local_z)
			if dist_sq >= radius_sq:
				height_data[idx] = 0.0
				idx += 1
				continue

			var normalized_distance := sqrt(dist_sq) / radius
			var height_multiplier := 0.0
			match peak_type:
				0: # Sharp
					height_multiplier = pow(1.0 - normalized_distance, 1.5)
				1: # Rounded
					height_multiplier = cos(normalized_distance * PI * 0.5)
					height_multiplier = height_multiplier * height_multiplier
				2: # Plateau
					if normalized_distance < 0.3:
						height_multiplier = 1.0
					else:
						var slope_t = (normalized_distance - 0.3) / 0.7
						height_multiplier = 1.0 - smoothstep(0.0, 1.0, slope_t)

			var base_height = height * height_multiplier
			if noise and noise_strength > 0.0:
				var noise_value = noise.get_noise_3d(world_x, 0.0, world_z)
				base_height += noise_value * height * noise_strength * height_multiplier

			height_data[idx] = base_height
			idx += 1

	var heightmap := Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, height_data.to_byte_array())

	# Apply modifiers (GPU if available, CPU fallback)
	if _has_any_modifiers():
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
				heightmap = modified
			else:
				_apply_modifiers_cpu(heightmap, terrain_bounds)
		else:
			_apply_modifiers_cpu(heightmap, terrain_bounds)

	_heightmap_dirty = false

	var elapsed = Time.get_ticks_msec() - start_time
	if Engine.is_editor_hint():
		print("[%s] Generated %dx%d heightmap (optimized) in %d ms" % [name, resolution.x, resolution.y, elapsed])

	return heightmap

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as PrimitiveEvaluationContext
	var local_pos = ctx.to_local(world_pos)
	var distance_2d = Vector2(local_pos.x, local_pos.z).length()
	
	var radius = ctx.influence_radius
	
	if distance_2d >= radius:
		return 0.0
	
	var normalized_distance = distance_2d / radius
	var height_multiplier = 0.0
	
	match ctx.mountain_peak_type:
		0: # Sharp
			height_multiplier = pow(1.0 - normalized_distance, 1.5)
		1: # Rounded
			height_multiplier = cos(normalized_distance * PI * 0.5)
			height_multiplier = height_multiplier * height_multiplier
		2: # Plateau
			if normalized_distance < 0.3:
				height_multiplier = 1.0
			else:
				var slope_t = (normalized_distance - 0.3) / 0.7
				height_multiplier = 1.0 - smoothstep(0.0, 1.0, slope_t)
	
	var base_height = ctx.height * height_multiplier
	
	# Add noise detail
	var noise_detail = ctx.get_noise_detail(world_pos)
	if noise_detail != 0.0:
		base_height += noise_detail * ctx.height * height_multiplier
	
	return base_height
