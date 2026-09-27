shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Varying to pass world position and normal from vertex to fragment shader
varying vec3 world_pos;
varying vec3 world_normal;

// Maximum number of texture layers supported
const int MAX_LAYERS = 32;

// Texture layer blend modes - must match TerrainTextureLayer.blend_mode export order
const int LAYER_BLEND_NORMAL = 0;
const int LAYER_BLEND_ADD = 1;
const int LAYER_BLEND_MULTIPLY = 2;

// Texture arrays for PBR materials
uniform sampler2DArray albedo_textures : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray normal_textures : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray roughness_textures : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray metallic_textures : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray ao_textures : filter_linear_mipmap_anisotropic, repeat_enable;

// Layer count
uniform int layer_count : hint_range(0, 32) = 0;

// Layer parameters (packed for efficiency)
// Each layer has: [height_min, height_max, height_falloff, slope_min (rad)]
uniform vec4 layer_height_slope_params[MAX_LAYERS];
// [layer_strength, slope_max (rad), slope_falloff (rad), blend_mode]
uniform vec4 layer_blend_params[MAX_LAYERS];
// [uv_scale.x, uv_scale.y, uv_offset.x, uv_offset.y]
uniform vec4 layer_uv_params[MAX_LAYERS];
// [albedo_color.rgb, normal_strength]
uniform vec4 layer_color_normal[MAX_LAYERS];
// [roughness, metallic, ao_strength, unused]
uniform vec4 layer_pbr_params[MAX_LAYERS];
// [has_albedo, has_normal, has_roughness, has_metallic]
uniform vec4 layer_texture_flags[MAX_LAYERS];
// [has_ao, use_height_curve, use_slope_curve, unused]
uniform vec4 layer_extra_flags[MAX_LAYERS];
// Future-proof: maps layer index → texture array slice (currently just identity)
uniform int layer_texture_index[MAX_LAYERS];

// World space parameters for blending
uniform float world_height_offset = 0.0;
uniform float blend_noise_scale : hint_range(0.0, 100.0) = 10.0;
uniform float blend_noise_strength : hint_range(0.0, 20.0) = 2.0;
// Compatibility renderer workaround: disable AO if array sampling is unreliable
uniform bool compatibility_disable_ao = false;

// Simple 2D noise function for height variation
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Fractal noise for more organic variation
float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	float frequency = 1.0;
	
	for (int i = 0; i < 4; i++) {
		value += amplitude * noise(p * frequency);
		frequency *= 2.0;
		amplitude *= 0.5;
	}
	
	return value;
}

// Sample texture with world-space XZ mapping (top-down for terrain)
vec4 sample_terrain_texture(sampler2DArray tex_array, int layer_idx, vec3 position, vec2 uv_scale, vec2 uv_offset) {
	// Use world XZ coordinates for UV mapping (top-down projection)
	vec2 uv = (position.xz / max(uv_scale, vec2(0.001))) + uv_offset;
	return texture(tex_array, vec3(uv, float(layer_idx)));
}

// Sample normal map with world-space XZ mapping.
// The result is the decoded map value in the top-down (planar) projection frame:
// xy is the world XZ height-gradient and z points away from the surface (world +Y).
vec3 sample_terrain_normal(sampler2DArray tex_array, int layer_idx, vec3 position, vec2 uv_scale, vec2 uv_offset) {
	vec2 uv = (position.xz / max(uv_scale, vec2(0.001))) + uv_offset;
	vec3 normal_map = texture(tex_array, vec3(uv, float(layer_idx))).xyz;
	// Decode from [0,1] to [-1,1]
	return normal_map * 2.0 - 1.0;
}

// Calculate blend weight for a layer based on height and slope
float calculate_layer_weight(int layer_idx, float world_height, float slope_angle, float height_noise) {
	vec4 hs_params = layer_height_slope_params[layer_idx];
	vec4 blend_params = layer_blend_params[layer_idx];
	
	float height_min = hs_params.x;
	float height_max = hs_params.y;
	float height_falloff = hs_params.z;
	float slope_min = hs_params.w;
	// Parameter unpacking aligned with terrain_material_builder.gd:
	// blend_params packing: [layer_strength, slope_max, slope_falloff, blend_mode]
	float layer_strength = blend_params.x;
	float slope_max = blend_params.y;
	float slope_falloff = blend_params.z;
	// blend_params.w (blend_mode) is consumed in fragment() during layer blending
	
	float weight = 1.0;
	
	// Use precomputed height noise (computed once per fragment)
	float adjusted_height = world_height + height_noise * blend_noise_strength;
	
	// Height influence with smoother falloff
	float height_weight = 1.0;
	if (height_falloff > 0.001) {
		if (adjusted_height < height_min) {
			float dist = height_min - adjusted_height;
			height_weight *= 1.0 - smoothstep(0.0, height_falloff, dist);
		} else if (adjusted_height > height_max) {
			float dist = adjusted_height - height_max;
			height_weight *= 1.0 - smoothstep(0.0, height_falloff, dist);
		}
	} else {
		// No falloff - hard cutoff
		if (adjusted_height < height_min || adjusted_height > height_max) {
			return 0.0;
		}
	}
	weight *= height_weight;
	
	// Slope influence with smoother falloff
	float slope_weight = 1.0;
	if (slope_falloff > 0.001) {
		if (slope_angle < slope_min) {
			float dist = slope_min - slope_angle;
			slope_weight *= 1.0 - smoothstep(0.0, slope_falloff, dist);
		} else if (slope_angle > slope_max) {
			float dist = slope_angle - slope_max;
			slope_weight *= 1.0 - smoothstep(0.0, slope_falloff, dist);
		}
	} else {
		// No falloff - hard cutoff
		if (slope_angle < slope_min || slope_angle > slope_max) {
			return 0.0;
		}
	}
	weight *= slope_weight;
	
	return weight * layer_strength;
}

void vertex() {
	// Calculate world position in vertex shader for proper texture mapping
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Calculate world normal for view-independent slope
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Use world position from vertex shader for proper texture mapping
	float world_height = world_pos.y + world_height_offset;
	// Calculate slope angle using world-space normal (view-independent)
	float slope_angle = acos(clamp(world_normal.y, 0.0, 1.0)); // In radians
	vec2 world_xz = vec2(world_pos.x, world_pos.z);
	
	// OPTIMIZATION: Compute noise ONCE per fragment for all layers
	float height_noise = 0.0;
	if (blend_noise_scale > 0.001) {
		height_noise = fbm(world_xz / blend_noise_scale) * 2.0 - 1.0;
	}
	
	// Handle case when no layers exist
	if (layer_count == 0) {
		ALBEDO = vec3(1.0, 0.0, 1.0);  // Magenta for visibility
		ROUGHNESS = 0.8;
		METALLIC = 0.0;
		AO = 1.0;
	} else {
		// Pass 1: Calculate weights
		float weights[MAX_LAYERS];
		float total_weight = 0.0;
		
		for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
			// Pass precomputed noise instead of recalculating
			weights[i] = calculate_layer_weight(i, world_height, slope_angle, height_noise);
			total_weight += weights[i];
		}
		
		// Pass 2: Normalize Normal-mode weights; Add/Multiply layers keep raw weights
		float normal_weight_total = 0.0;
		for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
			if (int(layer_blend_params[i].w) == LAYER_BLEND_NORMAL) {
				normal_weight_total += weights[i];
			}
		}
		
		int seed_layer = -1;
		if (total_weight > 0.001) {
			if (normal_weight_total > 0.001) {
				for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
					if (int(layer_blend_params[i].w) == LAYER_BLEND_NORMAL) {
						weights[i] /= normal_weight_total;
					}
				}
			} else {
				// No Normal layer contributes - seed the base with the first
				// contributing layer so Add/Multiply-only stacks stay visible
				for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
					if (weights[i] > 0.001) {
						seed_layer = i;
						break;
					}
				}
				if (seed_layer >= 0) {
					weights[seed_layer] = 1.0;
				} else {
					// Only sub-threshold weights - fall back to the first layer
					for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
						weights[i] = 0.0;
					}
					weights[0] = 1.0;
					seed_layer = 0;
				}
			}
		} else {
			// No layers contribute - zero all and use first layer
			for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
				weights[i] = 0.0;
			}
			weights[0] = 1.0;
			seed_layer = 0;
		}
		
		// Pass 3: Blend all layers with world-space XZ projection
		// Normal/Add layers accumulate additively; Multiply layers modulate.
		vec3 final_albedo = vec3(0.0);
		vec3 final_normal = vec3(0.0);  // Accumulate tangent-space normals additively
		float final_roughness = 0.0;
		float final_metallic = 0.0;
		float final_ao = 0.0;
		vec3 albedo_multiply = vec3(1.0);
		float roughness_multiply = 1.0;
		float metallic_multiply = 1.0;
		float ao_multiply = 1.0;
		bool has_additive_layers = false;
		
		for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
			float weight = weights[i];
			if (weight < 0.001) continue;
			
			// Get layer parameters
			vec4 uv_params = layer_uv_params[i];
			vec2 uv_scale = uv_params.xy;
			vec2 uv_offset = uv_params.zw;
			vec4 color_normal = layer_color_normal[i];
			vec4 pbr_params = layer_pbr_params[i];
			vec4 tex_flags = layer_texture_flags[i];
			vec4 extra_flags = layer_extra_flags[i];
			
			int tex_idx = layer_texture_index[i];
			
			// Sample albedo with world-space mapping
			vec3 albedo = color_normal.rgb;
			if (tex_flags.x > 0.5) { // has_albedo
				albedo *= sample_terrain_texture(albedo_textures, tex_idx, world_pos, uv_scale, uv_offset).rgb;
			}
			
		// Sample normal with world-space mapping
			if (tex_flags.y > 0.5) { // has_normal
				// The normal map is projected top-down, so its XY channels describe a
				// height-gradient field in world XZ rather than a tangent-space normal.
				// Perturb the geometric world normal with that gradient and re-express the
				// result in the mesh tangent frame, so slopes stay geometrically correct
				// (a flat normal map yields the untouched surface normal).
				vec2 normal_gradient = sample_terrain_normal(normal_textures, tex_idx, world_pos, uv_scale, uv_offset).xy;
				
				// Apply strength to normal intensity
				float normal_strength = clamp(color_normal.w, 0.0, 2.0);
				vec3 perturbed_world_normal = normalize(world_normal + vec3(normal_gradient.x, 0.0, normal_gradient.y) * normal_strength);
				// Godot's fragment-stage TANGENT/BINORMAL/NORMAL are view space
				vec3 perturbed_view_normal = (VIEW_MATRIX * vec4(perturbed_world_normal, 0.0)).xyz;
				vec3 layer_normal = vec3(
					dot(perturbed_view_normal, TANGENT),
					dot(perturbed_view_normal, BINORMAL),
					dot(perturbed_view_normal, NORMAL)
				);
				// Accumulate XY perturbation weighted (UDN-style: blend detail, not add)
				final_normal.xy += layer_normal.xy * weight;
				// Track accumulated Z separately for reconstruction
				final_normal.z += layer_normal.z * weight;
			}
			
			// Sample roughness with world-space mapping
			float roughness = pbr_params.x;
			if (tex_flags.z > 0.5) { // has_roughness
				roughness *= sample_terrain_texture(roughness_textures, tex_idx, world_pos, uv_scale, uv_offset).r;
			}
			
			// Sample metallic with world-space mapping
			float metallic_val = pbr_params.y;
			if (tex_flags.w > 0.5) { // has_metallic
				metallic_val *= sample_terrain_texture(metallic_textures, tex_idx, world_pos, uv_scale, uv_offset).r;
			}
			
			// Sample AO with world-space mapping
			float ao = 1.0;
			if (extra_flags.x > 0.5 && !compatibility_disable_ao) { // has_ao
				ao = mix(1.0, sample_terrain_texture(ao_textures, tex_idx, world_pos, uv_scale, uv_offset).r, pbr_params.z);
			}
			
			int blend_mode = int(layer_blend_params[i].w);
			if (i == seed_layer) {
				blend_mode = LAYER_BLEND_NORMAL;
			}
			
			if (blend_mode == LAYER_BLEND_MULTIPLY) {
				// Multiply-mode layer modulates the blended result so far;
				// weight/strength control how strongly (white = neutral)
				albedo_multiply *= mix(vec3(1.0), albedo, weight);
				roughness_multiply *= mix(1.0, roughness, weight);
				metallic_multiply *= mix(1.0, metallic_val, weight);
				ao_multiply *= mix(1.0, ao, weight);
			} else {
				// Normal (normalized weights) and Add (raw weights) accumulate
				has_additive_layers = true;
				final_albedo += albedo * weight;
				final_roughness += roughness * weight;
				final_metallic += metallic_val * weight;
				final_ao += ao * weight;
			}
		}
		
		// Apply Multiply-mode modulation to the additively blended base
		if (has_additive_layers) {
			final_albedo *= albedo_multiply;
			final_roughness *= roughness_multiply;
			final_metallic *= metallic_multiply;
			final_ao *= ao_multiply;
		} else {
			// Multiply-only stack: start from a neutral additive base
			// (white albedo, AO 1) so Multiply layers remain visible on their own
			final_albedo = albedo_multiply;
			final_roughness = roughness_multiply;
			final_metallic = metallic_multiply;
			final_ao = ao_multiply;
		}
		
		// Output
		ALBEDO = final_albedo;
		// Reconstruct normal from accumulated XY perturbation.
		// UDN-style blending: the Z component is derived from the accumulated
		// perturbation magnitude rather than simple addition, producing correct
		// lighting at layer boundaries.
		if (length(final_normal.xy) > 0.001) {
			final_normal.z = sqrt(max(0.0, 1.0 - dot(final_normal.xy, final_normal.xy)));
			NORMAL_MAP = normalize(final_normal);
		} else {
			NORMAL_MAP = vec3(0.0, 0.0, 1.0);  // Neutral tangent-space normal
		}
		ROUGHNESS = clamp(final_roughness, 0.0, 1.0);
		METALLIC = clamp(final_metallic, 0.0, 1.0);
		AO = clamp(final_ao, 0.0, 1.0);
	}
}
