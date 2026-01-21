#[compute]
#version 450

// Workgroup size - 8x8 threads per workgroup
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Output influence map
layout(set = 0, binding = 0, r32f) uniform writeonly image2D influence_map;

// Parameters buffer
layout(set = 0, binding = 1, std140) uniform Params {
    vec4 feature_position;      // xyz = world position
    vec4 terrain_bounds;        // xy = position, zw = size
    vec4 influence_size;        // xy = size, z = shape (0=circle, 1=rect, 2=ellipse), w = edge_falloff
    ivec4 resolution;           // xy = resolution
    mat4 inverse_transform;     // Feature's inverse global transform
};

const float MIN_INFLUENCE_SIZE = 0.01;

// Calculate influence weight for a given local position
float calculate_influence(vec2 local_pos_2d, int shape, vec2 size, float falloff) {
    float distance = 0.0;
    float max_distance = 0.0;
    
    if (shape == 0) {
        // CIRCLE
        distance = length(local_pos_2d);
        max_distance = max(size.x, MIN_INFLUENCE_SIZE);
        
        if (distance >= max_distance) {
            return 0.0;
        }
    }
    else if (shape == 1) {
        // RECTANGLE
        vec2 half_size = size * 0.5;
        half_size = max(half_size, vec2(MIN_INFLUENCE_SIZE));
        
        if (abs(local_pos_2d.x) > half_size.x || abs(local_pos_2d.y) > half_size.y) {
            return 0.0;
        }
        
        // Distance to nearest edge
        float dist_x = half_size.x - abs(local_pos_2d.x);
        float dist_y = half_size.y - abs(local_pos_2d.y);
        distance = min(dist_x, dist_y);
        max_distance = min(half_size.x, half_size.y);
    }
    else if (shape == 2) {
        // ELLIPSE
        float safe_size_x = max(size.x, MIN_INFLUENCE_SIZE);
        float safe_size_y = max(size.y, MIN_INFLUENCE_SIZE);
        vec2 normalized = vec2(
            local_pos_2d.x / safe_size_x,
            local_pos_2d.y / safe_size_y
        );
        distance = length(normalized);
        max_distance = 1.0;
        
        if (distance >= max_distance) {
            return 0.0;
        }
    }
    
    if (falloff <= 0.0) {
        return 1.0;
    }
    
    // Calculate falloff
    if (shape == 1) {
        // Rectangle falloff
        float falloff_distance = max_distance * falloff;
        if (distance > falloff_distance) {
            return 1.0;
        }
        float t = distance / falloff_distance;
        return smoothstep(0.0, 1.0, t);
    }
    else {
        // Circle and ellipse falloff
        float falloff_start = max_distance * (1.0 - falloff);
        if (distance < falloff_start) {
            return 1.0;
        }
        float t = (distance - falloff_start) / (max_distance - falloff_start);
        return 1.0 - smoothstep(0.0, 1.0, t);
    }
}

void main() {
    ivec2 pixel_coord = ivec2(gl_GlobalInvocationID.xy);
    
    // Check bounds
    if (pixel_coord.x >= resolution.x || pixel_coord.y >= resolution.y) {
        return;
    }
    
    // Calculate world position for this pixel
    vec2 step = terrain_bounds.zw / vec2(resolution.xy - ivec2(1, 1));
    float world_x = terrain_bounds.x + (pixel_coord.x * step.x);
    float world_z = terrain_bounds.y + (pixel_coord.y * step.y);
    vec3 world_pos = vec3(world_x, 0.0, world_z);
    
    // Transform to local space using inverse transform
    vec4 local_pos_4d = inverse_transform * vec4(world_pos, 1.0);
    vec2 local_pos_2d = vec2(local_pos_4d.x, local_pos_4d.z);
    
    // Calculate influence weight
    int shape = int(influence_size.z);
    vec2 size = influence_size.xy;
    float falloff = influence_size.w;
    
    float weight = calculate_influence(local_pos_2d, shape, size, falloff);
    
    // Write to output
    imageStore(influence_map, pixel_coord, vec4(weight, 0.0, 0.0, 0.0));
}
