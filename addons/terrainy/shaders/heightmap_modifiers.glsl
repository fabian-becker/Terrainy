#[compute]
#version 450

// Heightmap modifier shader - applies smoothing, terracing, and clamping on GPU

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Input/Output heightmap
layout(r32f, set = 0, binding = 0) uniform restrict readonly image2D input_heightmap;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D output_heightmap;

// Modifier parameters
layout(std140, set = 0, binding = 2) uniform ModifierParams {
    int smoothing_mode;      // 0=none, 1=light, 2=medium, 3=heavy
    float smoothing_radius;  // in world units
    int enable_terracing;
    int terrace_levels;
    float terrace_smoothness;
    int enable_min_clamp;
    float min_height;
    int enable_max_clamp;
    float max_height;
    int resolution_x;
    int resolution_y;
    float step_x;           // world units per pixel (X)
    float step_y;           // world units per pixel (Y)
    float max_abs_height;   // actual height range for terracing normalization
} params;

// Sample heightmap with bounds checking
float sample_height(ivec2 coords) {
    if (coords.x < 0 || coords.x >= params.resolution_x || 
        coords.y < 0 || coords.y >= params.resolution_y) {
        return 0.0;
    }
    return imageLoad(input_heightmap, coords).r;
}

// Apply smoothing (box blur with variable radius)
float apply_smoothing(ivec2 pixel_coords, float center_height) {
    if (params.smoothing_mode == 0) {
        return center_height;
    }
    
    int sample_count;
    float sample_radius;  // in world units
    
    if (params.smoothing_mode == 1) {  // LIGHT
        sample_count = 4;
        sample_radius = params.smoothing_radius * 0.5;
    } else if (params.smoothing_mode == 2) {  // MEDIUM
        sample_count = 8;
        sample_radius = params.smoothing_radius;
    } else {  // HEAVY
        sample_count = 12;
        sample_radius = params.smoothing_radius * 1.5;
    }
    
    // Convert world-unit radius to pixel offsets (matching CPU path)
    float pixel_radius_x = sample_radius / max(params.step_x, 0.0001);
    float pixel_radius_y = sample_radius / max(params.step_y, 0.0001);
    float pixel_radius = max(pixel_radius_x, pixel_radius_y);
    
    float total_height = center_height;
    float total_weight = 1.0;
    
    // Sample in a circle around the pixel
    float angle_step = 6.28318530718 / float(sample_count);  // 2*PI
    for (int i = 0; i < sample_count; i++) {
        float angle = float(i) * angle_step;
        // Convert world-unit offset to pixel coordinates
        float ox = cos(angle) * pixel_radius_x;
        float oy = sin(angle) * pixel_radius_y;
        ivec2 sample_coords = pixel_coords + ivec2(round(ox), round(oy));
        
        float sampled_height = sample_height(sample_coords);
        
        // Weight by distance in pixel space
        float dist = sqrt(ox * ox + oy * oy);
        float weight = 1.0 - (dist / (pixel_radius * 1.5));
        weight = max(0.0, weight);
        
        total_height += sampled_height * weight;
        total_weight += weight;
    }
    
    return total_height / total_weight;
}

// Apply terracing effect
float apply_terracing(float height) {
    if (params.enable_terracing == 0 || params.terrace_levels <= 1) {
        return height;
    }
    
    // Use actual height range for normalization (matches CPU path)
    float max_abs = max(params.max_abs_height, 0.001);
    
    // Normalize to 0-1 range using actual height range
    float normalized_height = height / max_abs;
    
    // Calculate terrace level
    float level = floor(normalized_height * float(params.terrace_levels));
    float level_height = level / float(params.terrace_levels);
    
    if (params.terrace_smoothness > 0.001) {
        // Smooth transition between levels
        float next_level_height = (level + 1.0) / float(params.terrace_levels);
        float t = (normalized_height * float(params.terrace_levels)) - level;
        t = smoothstep(0.0, 1.0, clamp(t / max(params.terrace_smoothness, 0.001), 0.0, 1.0));
        level_height = mix(level_height, next_level_height, t);
    }
    
    return level_height * max_abs;
}

// Apply height clamping
float apply_clamping(float height) {
    if (params.enable_min_clamp != 0) {
        height = max(height, params.min_height);
    }
    if (params.enable_max_clamp != 0) {
        height = min(height, params.max_height);
    }
    return height;
}

void main() {
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);
    
    // Bounds check
    if (pixel_coords.x >= params.resolution_x || pixel_coords.y >= params.resolution_y) {
        return;
    }
    
    // Read base height
    float height = imageLoad(input_heightmap, pixel_coords).r;
    
    // Apply modifiers in order
    height = apply_smoothing(pixel_coords, height);
    height = apply_terracing(height);
    height = apply_clamping(height);
    
    // Write result
    imageStore(output_heightmap, pixel_coords, vec4(height, 0.0, 0.0, 1.0));
}
