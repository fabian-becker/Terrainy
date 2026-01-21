shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Varying to pass world position from vertex to fragment shader
varying vec3 world_pos;

// Maximum number of texture layers supported
const int MAX_LAYERS = 32;

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
// [slope_max (rad), slope_falloff (rad), layer_strength, blend_mode]
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

// Sample normal map with world-space XZ mapping - returns tangent space normal
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
	// Parameter unpacking aligned with terrain_composer.gd:
	// blend_params packing: [layer_strength, slope_max, slope_falloff, blend_mode]
	float layer_strength = blend_params.x;
	float slope_max = blend_params.y;
	float slope_falloff = blend_params.z;
	// Note: blend_mode (blend_params.w) is currently unused
	
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
}

void fragment() {
	// Use world position from vertex shader for proper texture mapping
	float world_height = world_pos.y + world_height_offset;
	// Calculate slope angle (clamp handles downward-facing normals, keeping them at 90°)
	float slope_angle = acos(clamp(NORMAL.y, 0.0, 1.0)); // In radians
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
		
		// Pass 2: Normalize weights
		if (total_weight > 0.001) {
			for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
				weights[i] /= total_weight;
			}
		} else {
			// No layers contribute - zero all and use first layer
			for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
				weights[i] = 0.0;
			}
			if (layer_count > 0) {
				weights[0] = 1.0;
			}
		}
		
		// Pass 3: Blend all layers with world-space XZ projection
		vec3 final_albedo = vec3(0.0);
		vec3 final_normal = vec3(0.0);  // Accumulate tangent-space normals additively
		float final_roughness = 0.0;
		float final_metallic = 0.0;
		float final_ao = 0.0;
		
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
				vec3 layer_normal = sample_terrain_normal(normal_textures, tex_idx, world_pos, uv_scale, uv_offset);
				
				// Apply strength to normal intensity
				float normal_strength = clamp(color_normal.w, 0.0, 2.0);
				// Scale XY components by strength, keep Z
				layer_normal.xy *= normal_strength;
				// Accumulate normals additively (proper normal blending)
				final_normal += layer_normal * weight;
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
			if (extra_flags.x > 0.5) { // has_ao
				ao = mix(1.0, sample_terrain_texture(ao_textures, tex_idx, world_pos, uv_scale, uv_offset).r, pbr_params.z);
			}
			
			// Weighted blend for non-normal properties
			final_albedo += albedo * weight;
			final_roughness += roughness * weight;
			final_metallic += metallic_val * weight;
			final_ao += ao * weight;
		}
		
		// Output
		ALBEDO = final_albedo;
		// Normalize accumulated normal, or use neutral if no normals were applied
		if (length(final_normal) > 0.001) {
			NORMAL_MAP = normalize(final_normal);
		} else {
			NORMAL_MAP = vec3(0.0, 0.0, 1.0);  // Neutral tangent-space normal
		}
		ROUGHNESS = clamp(final_roughness, 0.0, 1.0);
		METALLIC = clamp(final_metallic, 0.0, 1.0);
		AO = clamp(final_ao, 0.0, 1.0);
	}
}
