#[compute]
#version 450

// Simplified heightmap compositor

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Output heightmap (r32f for 4x bandwidth reduction)
layout(r32f, set = 0, binding = 0) uniform restrict writeonly image2D output_heightmap;

// Input data as storage buffers (simpler and more compatible)
layout(std430, set = 0, binding = 1) restrict readonly buffer HeightmapData {
    float heightmap_data[];  // Flattened heightmap data
};

layout(std430, set = 0, binding = 2) restrict readonly buffer InfluenceData {
    float influence_data[];  // Flattened influence weight data
};

// Parameters
layout(std140, set = 0, binding = 3) uniform Params {
    int layer_count;
    float base_height;
    int resolution_x;
    int resolution_y;
} params;

// Layer properties
layout(std140, set = 0, binding = 4) uniform LayerData {
    vec4 blend_strength[32];  // x: blend_mode, y: strength, z-w: unused
} layer_data;

// Blend modes
const int BLEND_ADD = 0;
const int BLEND_SUBTRACT = 1;
const int BLEND_MULTIPLY = 2;
const int BLEND_MAX = 3;
const int BLEND_MIN = 4;
const int BLEND_AVERAGE = 5;

float apply_blend_mode(float current_height, float feature_height, float weight, float strength, int blend_mode) {
    float weighted_height = feature_height * weight * strength;
    
    if (blend_mode == BLEND_ADD) {
        return current_height + weighted_height;
    } else if (blend_mode == BLEND_SUBTRACT) {
        return current_height - weighted_height;
    } else if (blend_mode == BLEND_MULTIPLY) {
        return current_height * (1.0 + weighted_height);
    } else if (blend_mode == BLEND_MAX) {
        return max(current_height, feature_height * weight);
    } else if (blend_mode == BLEND_MIN) {
        return min(current_height, feature_height * weight);
    } else if (blend_mode == BLEND_AVERAGE) {
        return mix(current_height, feature_height * weight, strength * 0.5);
    }
    return current_height + weighted_height;
}

void main() {
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);
    
    // Bounds check
    if (pixel_coords.x >= params.resolution_x || pixel_coords.y >= params.resolution_y) {
        return;
    }
    
    // Start with base height
    float final_height = params.base_height;
    
    // Calculate linear index for this pixel
    int pixel_index = pixel_coords.y * params.resolution_x + pixel_coords.x;
    int total_pixels = params.resolution_x * params.resolution_y;
    
    // Blend each layer (clamp to 32 to prevent buffer overrun)
    int layer_count = min(params.layer_count, 32);
    for (int i = 0; i < layer_count; i++) {
        // Calculate offset for this layer
        int layer_offset = i * total_pixels;
        int data_index = layer_offset + pixel_index;
        
        // Sample feature heightmap
        float feature_height = heightmap_data[data_index];
        
        // Sample influence weight
        float influence_weight = influence_data[data_index];
        
        // Skip if no influence
        if (influence_weight <= 0.001) {
            continue;
        }
        
        // Get layer properties
        int blend_mode = int(layer_data.blend_strength[i].x);
        float strength = layer_data.blend_strength[i].y;
        
        // Apply blend
        final_height = apply_blend_mode(final_height, feature_height, influence_weight, strength, blend_mode);
    }
    
    // Write result
    imageStore(output_heightmap, pixel_coords, vec4(final_height, 0.0, 0.0, 1.0));
}
