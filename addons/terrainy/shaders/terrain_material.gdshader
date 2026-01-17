shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Varying to pass world position from vertex to fragment shader
varying vec3 world_pos;

// Maximum number of texture layers supported
const int MAX_LAYERS = 32;

// Texture arrays for PBR materials
uniform sampler2DArray albedo_textures : filter_linear_mipmap, repeat_enable;
uniform sampler2DArray normal_textures : filter_linear_mipmap, repeat_enable;
uniform sampler2DArray roughness_textures : filter_linear_mipmap, repeat_enable;
uniform sampler2DArray metallic_textures : filter_linear_mipmap, repeat_enable;
uniform sampler2DArray ao_textures : filter_linear_mipmap, repeat_enable;

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

// World space parameters for blending
uniform float world_height_offset = 0.0;

// Calculate blend weight for a layer based on height and slope
float calculate_layer_weight(int layer_idx, float world_height, float slope_angle) {
	vec4 hs_params = layer_height_slope_params[layer_idx];
	vec4 blend_params = layer_blend_params[layer_idx];
	
	float height_min = hs_params.x;
	float height_max = hs_params.y;
	float height_falloff = hs_params.z;
	float slope_min = hs_params.w;
	float slope_max = blend_params.x;
	float slope_falloff = blend_params.y;
	float layer_strength = blend_params.z;
	
	float weight = 1.0;
	
	// Height influence with falloff
	if (world_height < height_min - height_falloff) {
		return 0.0;
	} else if (world_height < height_min + height_falloff) {
		float t = (world_height - (height_min - height_falloff)) / (height_falloff * 2.0);
		weight *= smoothstep(0.0, 1.0, t);
	}
	
	if (world_height > height_max + height_falloff) {
		return 0.0;
	} else if (world_height > height_max - height_falloff) {
		float t = ((height_max + height_falloff) - world_height) / (height_falloff * 2.0);
		weight *= smoothstep(0.0, 1.0, t);
	}
	
	// Slope influence with falloff
	if (slope_angle < slope_min - slope_falloff) {
		return 0.0;
	} else if (slope_angle < slope_min + slope_falloff) {
		float t = (slope_angle - (slope_min - slope_falloff)) / (slope_falloff * 2.0);
		weight *= smoothstep(0.0, 1.0, t);
	}
	
	if (slope_angle > slope_max + slope_falloff) {
		return 0.0;
	} else if (slope_angle > slope_max - slope_falloff) {
		float t = ((slope_max + slope_falloff) - slope_angle) / (slope_falloff * 2.0);
		weight *= smoothstep(0.0, 1.0, t);
	}
	
	return weight * layer_strength;
}

void vertex() {
	// Calculate world position in vertex shader for proper texture mapping
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Use world position from vertex shader for proper texture mapping
	float world_height = world_pos.y + world_height_offset;
	float slope_angle = acos(clamp(NORMAL.y, 0.0, 1.0)); // In radians
	
	// Handle case when no layers exist
	if (layer_count == 0) {
		ALBEDO = vec3(0.5);
		ROUGHNESS = 0.8;
		METALLIC = 0.0;
		AO = 1.0;
	} else {
		// Calculate blend weights for all layers
		float weights[MAX_LAYERS];
		float total_weight = 0.0;
		
		for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
			weights[i] = calculate_layer_weight(i, world_height, slope_angle);
			total_weight += weights[i];
		}
		
		// Normalize weights
		if (total_weight > 0.001) {
			for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
				weights[i] /= total_weight;
			}
		} else {
			// No layers contribute - use first layer with full weight
			weights[0] = 1.0;
			total_weight = 1.0;
		}
		
		// Blend all layers
		vec3 final_albedo = vec3(0.0);
		vec3 final_normal_map = vec3(0.5, 0.5, 1.0);
		float final_roughness = 0.0;
		float final_metallic = 0.0;
		float final_ao = 0.0;
		
		for (int i = 0; i < layer_count && i < MAX_LAYERS; i++) {
			if (weights[i] < 0.001) continue;
			
			// Get layer parameters
			vec4 uv_params = layer_uv_params[i];
			// Use world-space XZ coordinates for texture mapping to prevent swimming
			// Divide by scale to get proper tiling (larger scale = smaller tiles)
			vec2 world_uv = vec2(world_pos.x, world_pos.z);
			vec2 layer_uv = (world_uv / uv_params.xy) + uv_params.zw;
			vec4 color_normal = layer_color_normal[i];
			vec4 pbr_params = layer_pbr_params[i];
			vec4 tex_flags = layer_texture_flags[i];
			vec4 extra_flags = layer_extra_flags[i];
			
			// Sample albedo
			vec3 albedo = color_normal.rgb;
			if (tex_flags.x > 0.5) { // has_albedo
				albedo *= texture(albedo_textures, vec3(layer_uv, float(i))).rgb;
			}
			
			// Sample normal
			vec3 normal_sample = vec3(0.5, 0.5, 1.0);
			if (tex_flags.y > 0.5) { // has_normal
				normal_sample = texture(normal_textures, vec3(layer_uv, float(i))).rgb;
				// Apply strength by lerping between flat normal and sampled normal
				normal_sample = mix(vec3(0.5, 0.5, 1.0), normal_sample, color_normal.w);
			}
			// Keep in tangent space [0,1] for now, will convert after blending
			vec3 layer_normal_map = normal_sample;
			
			// Sample roughness
			float roughness = pbr_params.x;
			if (tex_flags.z > 0.5) { // has_roughness
				roughness *= texture(roughness_textures, vec3(layer_uv, float(i))).r;
			}
			
			// Sample metallic
			float metallic_val = pbr_params.y;
			if (tex_flags.w > 0.5) { // has_metallic
				metallic_val *= texture(metallic_textures, vec3(layer_uv, float(i))).r;
			}
			
			// Sample AO
			float ao = 1.0;
			if (extra_flags.x > 0.5) { // has_ao
				ao = mix(1.0, texture(ao_textures, vec3(layer_uv, float(i))).r, pbr_params.z);
			}
			
			// Blend based on blend mode
			int blend_mode = int(layer_blend_params[i].w);
			float weight = weights[i];
			
			if (blend_mode == 0) { // Normal blend
				final_albedo += albedo * weight;
				final_normal_map += layer_normal_map * weight;
				final_roughness += roughness * weight;
				final_metallic += metallic_val * weight;
				final_ao += ao * weight;
			} else if (blend_mode == 1) { // Add
				final_albedo += albedo * weight;
				final_normal_map += layer_normal_map * weight;
				final_roughness += roughness * weight;
				final_metallic += metallic_val * weight;
				final_ao += ao * weight;
			} else if (blend_mode == 2) { // Multiply
				final_albedo = mix(final_albedo, final_albedo * albedo, weight);
				final_normal_map += layer_normal_map * weight;
				final_roughness = mix(final_roughness, final_roughness * roughness, weight);
				final_metallic = mix(final_metallic, final_metallic * metallic_val, weight);
				final_ao = mix(final_ao, final_ao * ao, weight);
			}
		}
		
		// Convert blended normal from [0,1] tangent space to [-1,1] and normalize
		vec3 final_normal = normalize(final_normal_map * 2.0 - 1.0);
		
		// Output
		ALBEDO = final_albedo;
		NORMAL_MAP = final_normal;
		ROUGHNESS = clamp(final_roughness, 0.0, 1.0);
		METALLIC = clamp(final_metallic, 0.0, 1.0);
		AO = clamp(final_ao, 0.0, 1.0);
	}
}
