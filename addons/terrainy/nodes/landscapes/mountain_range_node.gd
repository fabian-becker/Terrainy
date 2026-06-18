@tool
class_name MountainRangeNode
extends LandscapeNode

const LandscapeNode = preload("res://addons/terrainy/nodes/landscapes/landscape_node.gd")
const LandscapeEvaluationContext = preload("res://addons/terrainy/nodes/landscapes/landscape_evaluation_context.gd")

## A mountain range terrain feature
##
## Unlike a single uniform ridge (a "mohawk"), a real mountain range has a
## crest that [b]wanders[/b] side-to-side, [b]distinct peaks[/b] separated by
## low saddles/cols, and [b]foothills[/b] flanking the main spine. This node
## models all three:
## - [member ridge_meander] bends the crest line along its length.
## - [member peak_prominence] sculpts a serrated ridge with summits and passes.
## - [member foothill_strength] adds subsidiary ridges in the outer flanks.
##
## TIP: Mountains can appear very spiky by default. Try using the Modifiers:
## - Set "Smoothing" to MEDIUM or HEAVY for more natural-looking peaks
## - Adjust "Smoothing Radius" to 2.0-4.0 for best results
## - Enable "Terracing" with 8-12 levels for a layered mountain effect

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
## (0.0 = smooth rolling ridge, 1.0 = sharp serrated ridge with cols between summits).
@export_range(0.0, 1.0, 0.01) var peak_prominence: float = 0.7:
	set(value):
		peak_prominence = clamp(value, 0.0, 1.0)
		_commit_parameter_change()

## Height of foothills / subsidiary ridges flanking the main crest, as a
## fraction of [member height] (0.0 = lone spine, 1.0 = broad foothill belt).
@export_range(0.0, 1.0, 0.01) var foothill_strength: float = 0.45:
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
		peak_noise.frequency = 0.008
		peak_noise.fractal_octaves = 2

	if not detail_noise:
		detail_noise = FastNoiseLite.new()
		detail_noise.seed = randi() + 1000
		detail_noise.frequency = 0.05
		detail_noise.fractal_octaves = 4

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

	# Ridge width = how far the influence shape reaches perpendicular to the
	# ridge direction. Length = how far it reaches along the ridge direction.
	# Both stay correct no matter which way `direction` is oriented.
	var ridge_width = max(ctx.get_extent_along(ctx.perpendicular), 0.0001)
	var half_length = max(ctx.get_extent_along(ctx.direction), 0.0001)
	# The sharp crest is narrower than the full range, leaving room for foothills
	var crest_width = ridge_width * 0.55

	# --- Meander: wander the crest line laterally along its length ---
	var meander_offset = 0.0
	if ctx.ridge_meander > 0.0 and ctx.primary_noise:
		# Low-frequency slice (phase-shifted in the noise's 2nd axis) for a slow wander
		var meander_noise = ctx.get_primary_noise(Vector3(along_ridge * 0.15, 0.0, 7777.0))
		meander_offset = meander_noise * ridge_width * ctx.ridge_meander
	var lateral = abs(perp_dist - meander_offset)

	# --- Main crest cross-profile (sharp pointed ridge) ---
	var crest_t = clampf(lateral / crest_width, 0.0, 1.0)
	var crest_falloff = 1.0 - pow(crest_t, ctx.ridge_sharpness)
	crest_falloff = max(0.0, crest_falloff)

	# --- Peak / saddle profile along the ridge ---
	# Two even (symmetric) profiles blended by peak_prominence, so summits stay
	# centered on the ridge instead of lopsided:
	#  - rolling: gentle waves with no real cols (prominence 0)
	#  - serrated: distinct summits and low cols (prominence 1)
	# Both are smooth (differentiable) functions - no |n| cusp - so peaks are
	# rounded multi-vertex humps instead of isolated single-vertex spikes.
	var n_peak = ctx.get_primary_noise(Vector3(along_ridge, 0.0, 0.0)) # -1..1
	var rolling = 1.0 - 0.4 * n_peak * n_peak
	var serrated = 1.0 - smoothstep(0.0, 1.0, abs(n_peak))
	var peak_profile = lerpf(rolling, serrated, ctx.peak_prominence)
	# Slow overall summit-height variation so not every peak is identical
	var n_slow = ctx.get_primary_noise(Vector3(along_ridge * 0.4, 0.0, 333.0))
	var height_scale = 0.55 + 0.45 * (0.5 + 0.5 * n_slow)
	peak_profile = clampf(peak_profile * height_scale, 0.0, 1.0)
	# A small baseline keeps cols as elevated passes rather than sea-level gaps
	var crest_height = ctx.height * crest_falloff * (0.2 + peak_profile * 0.8)

	# --- Foothills: subsidiary ridges in the outer flanks, following the meander ---
	var foothills = 0.0
	if ctx.foothill_strength > 0.0:
		var flank_t = clampf(lateral / ridge_width, 0.0, 1.0)
		# Hump sitting in the outer flank: zero at the crest and at the outer edge
		var foothill_env = smoothstep(0.2, 0.55, flank_t) * (1.0 - smoothstep(0.75, 1.0, flank_t))
		if foothill_env > 0.0:
			# Coarser 2D bumps give the foothills their own ridgelets, independent
			# of the along-ridge crest profile
			var fh_noise = ctx.get_detail_noise(Vector3(world_pos.x * 0.3, 0.0, world_pos.z * 0.3))
			var fh_mod = 0.65 + abs(fh_noise) * 0.7 # 0.65..1.35
			# Foothills rise with the main peaks and dip in the cols
			foothills = ctx.height * ctx.foothill_strength * foothill_env * fh_mod * (0.35 + peak_profile * 0.65)

	var result_height = crest_height + foothills

	# --- Surface detail (world-space roughness) ---
	var detail = ctx.get_detail_noise(world_pos)
	if detail != 0.0:
		result_height += result_height * detail * 0.12

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