@tool
class_name MountainRangeNode
extends LandscapeNode

const LandscapeNode = preload("res://addons/terrainy/nodes/landscapes/landscape_node.gd")
const LandscapeEvaluationContext = preload("res://addons/terrainy/nodes/landscapes/landscape_evaluation_context.gd")

## A mountain range terrain feature with smooth, natural-looking peaks.
##
## Models a mountain range with three components:
## - A [b]crest line[/b] that wanders side-to-side ([member ridge_meander]).
## - [b]Distinct rounded summits[/b] separated by low saddles/cols.  The
##   cross-profile is a [i]Gaussian[/i] so the ridge top is always smooth —
##   no single-vertex spikes, regardless of parameter values.
## - [b]Foothills[/b] — subsidiary ridgelets flanking the main spine, elongated
##   parallel to the crest.
##
## [member ridge_sharpness] controls how narrow the crest is (higher = sharper
## ridge, but still smooth — never a cusp).  [member peak_prominence] controls
## how distinct summits are from cols (0 = gentle rolling ridge, 1 = sharp
## contrast between peaks and saddles).

@export var ridge_sharpness: float = 0.5:
	set(value):
		ridge_sharpness = clamp(value, 0.1, 2.0)
		_commit_parameter_change()

## How much the ridge crest wanders side-to-side along its length
## (0.0 = perfectly straight spine, 1.0 = strong meandering crest).
@export_range(0.0, 1.0, 0.01) var ridge_meander: float = 0.3:
	set(value):
		ridge_meander = clamp(value, 0.0, 1.0)
		_commit_parameter_change()

## How distinct individual peaks and saddles are along the ridge
## (0.0 = smooth rolling ridge, 1.0 = sharp contrast between summits and cols).
@export_range(0.0, 1.0, 0.01) var peak_prominence: float = 0.6:
	set(value):
		peak_prominence = clamp(value, 0.0, 1.0)
		_commit_parameter_change()

## Height of foothills / subsidiary ridges flanking the main crest, as a
## fraction of [member height] (0.0 = lone spine, 1.0 = broad foothill belt).
@export_range(0.0, 1.0, 0.01) var foothill_strength: float = 0.4:
	set(value):
		foothill_strength = clamp(value, 0.0, 1.0)
		_commit_parameter_change()

@export var peak_noise: FastNoiseLite:
	set(value):
		peak_noise = value
		if peak_noise and not peak_noise.changed.is_connected(_on_noise_changed):
			peak_noise.changed.connect(_on_noise_changed)
		_commit_parameter_change()

@export var detail_noise: FastNoiseLite:
	set(value):
		detail_noise = value
		if detail_noise and not detail_noise.changed.is_connected(_on_noise_changed):
			detail_noise.changed.connect(_on_noise_changed)
		_commit_parameter_change()

func _ready() -> void:
	if not peak_noise:
		peak_noise = FastNoiseLite.new()
		peak_noise.seed = randi()
		peak_noise.frequency = 0.005
		peak_noise.fractal_octaves = 3

	if not detail_noise:
		detail_noise = FastNoiseLite.new()
		detail_noise.seed = randi() + 1000
		detail_noise.frequency = 0.04
		detail_noise.fractal_octaves = 3

	if peak_noise and not peak_noise.changed.is_connected(_on_noise_changed):
		peak_noise.changed.connect(_on_noise_changed)
	if detail_noise and not detail_noise.changed.is_connected(_on_noise_changed):
		detail_noise.changed.connect(_on_noise_changed)

func prepare_evaluation_context() -> LandscapeEvaluationContext:
	var ctx = LandscapeEvaluationContext.from_landscape_feature(self, height, direction)
	ctx.primary_noise = peak_noise
	ctx.detail_noise = detail_noise
	ctx.ridge_sharpness = ridge_sharpness
	ctx.ridge_meander = ridge_meander
	ctx.peak_prominence = peak_prominence
	ctx.foothill_strength = foothill_strength
	return ctx

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

## Thread-safe version using pre-computed context
func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as LandscapeEvaluationContext
	var local_pos = ctx.to_local(world_pos)

	var normalized_distance = ctx.get_influence_normalized_distance(local_pos)
	if normalized_distance >= 1.0:
		return 0.0

	# Signed distance perpendicular to the ridge axis and distance along it
	var perp_dist = ctx.get_distance_perpendicular(local_pos)
	var along_ridge = ctx.get_distance_along(local_pos)

	var ridge_width = max(ctx.get_extent_along(ctx.perpendicular), 0.0001)
	var half_length = max(ctx.get_extent_along(ctx.direction), 0.0001)
	var crest_width = ridge_width * 0.5

	# --- Meander: wander the crest line laterally along its length ---
	var meander_offset = 0.0
	if ctx.ridge_meander > 0.0 and ctx.primary_noise:
		var meander_noise = ctx.get_primary_noise(Vector3(along_ridge * 0.15, 0.0, 7777.0))
		meander_offset = meander_noise * ridge_width * ctx.ridge_meander
	var lateral = abs(perp_dist - meander_offset)

	# --- Crest cross-profile: Gaussian ---
	# Always C∞-smooth: zero slope at the ridge center (rounded top), no cusp
	# at any parameter value.  ridge_sharpness controls the Gaussian width:
	# higher = narrower/sharper crest, but the top is never a needle.
	var crest_t = lateral / crest_width
	var crest_falloff = exp(-crest_t * crest_t * (1.0 + ctx.ridge_sharpness * 3.0))

	# --- Peak / saddle profile along the ridge ---
	# Peaks sit at noise MAXIMA — smooth domes with a single highest vertex —
	# not at zero-crossings (which produced a dense crocodile-teeth ridge).
	# peak_prominence blends between gentle rolling and contrasted summits.
	var n_peak = ctx.get_primary_noise(Vector3(along_ridge, 0.0, 0.0))
	var n_norm = clampf(n_peak * 0.5 + 0.5, 0.0, 1.0)
	var base_profile = n_norm
	var contrasted = pow(n_norm, 2.5)
	var peak_profile = lerpf(base_profile, contrasted, ctx.peak_prominence)
	# Slow overall summit-height variation so not every peak is identical
	var n_slow = ctx.get_primary_noise(Vector3(along_ridge * 0.4, 0.0, 333.0))
	var height_scale = 0.6 + 0.4 * (0.5 + 0.5 * n_slow)
	peak_profile = clampf(peak_profile * height_scale, 0.0, 1.0)
	# Small baseline keeps cols as elevated passes rather than sea-level gaps
	var crest_height = ctx.height * crest_falloff * (0.15 + peak_profile * 0.85)

	# --- Foothills: subsidiary ridgelets in the outer flanks ---
	var foothills = 0.0
	if ctx.foothill_strength > 0.0:
		var flank_t = clampf(lateral / ridge_width, 0.0, 1.0)
		var foothill_env = smoothstep(0.15, 0.4, flank_t) * (1.0 - smoothstep(0.8, 1.0, flank_t))
		if foothill_env > 0.0:
			# Anisotropic ridge-relative sampling: high frequency perpendicular,
			# low frequency along, so sub-ridges elongate parallel to the crest.
			# Ridge noise (1 - |n|)² gives ridgelets with valleys, not blobs.
			var fh_perp = perp_dist - meander_offset
			var fh_noise = ctx.get_detail_noise(Vector3(fh_perp * 0.8, 0.0, along_ridge * 0.15))
			var fh_ridge = 1.0 - abs(fh_noise)
			fh_ridge = fh_ridge * fh_ridge
			var fh_mod = 0.3 + fh_ridge * 1.0
			foothills = ctx.height * ctx.foothill_strength * foothill_env * fh_mod * (0.3 + peak_profile * 0.7)

	var result_height = crest_height + foothills

	# --- Surface detail (world-space roughness) ---
	var detail = ctx.get_detail_noise(world_pos)
	if detail != 0.0:
		result_height += result_height * detail * 0.08

	# --- Taper the ends of the range so it doesn't terminate in a cliff ---
	var along_t = abs(along_ridge) / half_length
	var end_fade = 1.0 - smoothstep(0.82, 1.0, along_t)
	result_height *= end_fade

	return result_height

func get_gpu_param_pack() -> Dictionary:
	var dir = direction.normalized()
	var peak_freq = peak_noise.frequency if peak_noise else 0.0
	var detail_freq = detail_noise.frequency if detail_noise else 0.0
	var peak_seed = peak_noise.seed if peak_noise else 0
	var detail_seed = detail_noise.seed if detail_noise else 0
	var extra_floats := PackedFloat32Array([
		height, dir.x, dir.y, ridge_sharpness,
		peak_freq, detail_freq,
		ridge_meander, peak_prominence, foothill_strength
	])
	var extra_ints := PackedInt32Array([peak_seed, detail_seed])
	return _build_gpu_param_pack(FeatureType.LANDSCAPE_MOUNTAIN_RANGE, extra_floats, extra_ints)