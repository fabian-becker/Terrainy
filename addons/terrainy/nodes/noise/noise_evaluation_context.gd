@tool
class_name NoiseEvaluationContext
extends EvaluationContext

## Specialized context for noise-based terrain features.
## Captures noise parameters for thread-safe evaluation.

## Noise generator (FastNoiseLite is thread-safe for reading)
var noise: FastNoiseLite

## Amplitude of the noise effect
var amplitude: float

## Optional frequency override (if 0, uses noise's built-in frequency)
var frequency_override: float = 0.0

## Create a NoiseEvaluationContext from a terrain feature node with noise properties.
## This captures both base transform data and noise-specific parameters.
static func from_noise_feature(feature: TerrainFeatureNode, noise_resource: FastNoiseLite, amp: float = 1.0, freq_override: float = 0.0) -> NoiseEvaluationContext:
	var ctx = NoiseEvaluationContext.new()
	
	# Copy base context properties
	ctx.world_position = feature.global_position
	ctx.inverse_transform = feature.global_transform.affine_inverse()
	ctx.influence_shape = feature.influence_shape
	ctx.influence_size = feature.influence_size
	ctx.influence_radius = max(feature.influence_size.x, feature.influence_size.y)
	ctx.influence_radius_sq = ctx.influence_radius * ctx.influence_radius
	ctx.edge_falloff = feature.edge_falloff
	ctx.strength = feature.strength
	ctx.blend_mode = feature.blend_mode
	
	var half_size = Vector3(ctx.influence_radius, 1000.0, ctx.influence_radius)
	ctx.aabb = AABB(ctx.world_position - half_size, half_size * 2.0)
	
	# Add noise-specific properties
	ctx.noise = noise_resource
	ctx.amplitude = amp
	ctx.frequency_override = freq_override
	
	return ctx

## Get noise value at a world position (thread-safe).
## Uses world coordinates for noise sampling.
func get_noise_value(world_pos: Vector3) -> float:
	if not noise:
		return 0.0
	
	var sample_x = world_pos.x
	var sample_z = world_pos.z
	
	# Apply frequency override if set
	if frequency_override > 0.0:
		var freq_scale = frequency_override / noise.frequency
		sample_x *= freq_scale
		sample_z *= freq_scale
	
	return noise.get_noise_2d(sample_x, sample_z)

## Get normalized noise value at a world position (0.0 to 1.0).
func get_noise_normalized(world_pos: Vector3) -> float:
	return (get_noise_value(world_pos) + 1.0) * 0.5
