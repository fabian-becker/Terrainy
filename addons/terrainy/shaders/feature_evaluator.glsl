// Feature evaluator compute shader (initial kernel: PRIMITIVE_HILL)
// Uses packed float/int buffers from the feature parameter contract.

#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Output heightmap (r32f)
layout(r32f, set = 0, binding = 0) uniform restrict writeonly image2D output_heightmap;

// Packed parameter buffers
layout(std430, set = 0, binding = 1) restrict readonly buffer ParamFloats {
	float param_floats[];
};

layout(std430, set = 0, binding = 2) restrict readonly buffer ParamInts {
	int param_ints[];
};

// Dispatch parameters
layout(std140, set = 0, binding = 3) uniform Params {
	int resolution_x;
	int resolution_y;
	int feature_type;
	int float_count;
	int int_count;
	float bounds_x;
	float bounds_y;
	float bounds_w;
	float bounds_h;
} params;

const int FEATURE_PRIMITIVE_HILL = 100;
const int FEATURE_PRIMITIVE_MOUNTAIN = 101;
const int FEATURE_PRIMITIVE_CRATER = 102;
const int FEATURE_PRIMITIVE_VOLCANO = 103;
const int FEATURE_PRIMITIVE_ISLAND = 104;
const int FEATURE_SHAPE = 200;
const int FEATURE_HEIGHTMAP = 210;
const int FEATURE_GRADIENT_LINEAR = 300;
const int FEATURE_GRADIENT_RADIAL = 301;
const int FEATURE_GRADIENT_CONE = 302;
const int FEATURE_GRADIENT_HEMISPHERE = 303;
const int FEATURE_LANDSCAPE_CANYON = 400;
const int FEATURE_LANDSCAPE_MOUNTAIN_RANGE = 401;
const int FEATURE_LANDSCAPE_DUNE_SEA = 402;
const int FEATURE_NOISE_PERLIN = 500;
const int FEATURE_NOISE_VORONOI = 501;
const int SHAPE_SMOOTH = 0;
const int SHAPE_CONE = 1;
const int SHAPE_DOME = 2;

float get_float(int idx) {
	return param_floats[idx];
}

int get_int(int idx) {
	return param_ints[idx];
}

float hill_multiplier(float normalized_distance, int shape_mode) {
	if (normalized_distance >= 1.0) {
		return 0.0;
	}

	if (shape_mode == SHAPE_SMOOTH) {
		float m = cos(normalized_distance * 1.57079632679);
		return m * m;
	} else if (shape_mode == SHAPE_CONE) {
		return 1.0 - normalized_distance;
	} else if (shape_mode == SHAPE_DOME) {
		return sqrt(max(0.0, 1.0 - normalized_distance * normalized_distance));
	}
	return 1.0 - normalized_distance;
}

float mountain_multiplier(float normalized_distance, int peak_type) {
	if (normalized_distance >= 1.0) {
		return 0.0;
	}
	if (peak_type == 0) {
		return pow(1.0 - normalized_distance, 1.5);
	} else if (peak_type == 1) {
		float m = cos(normalized_distance * 1.57079632679);
		return m * m;
	} else if (peak_type == 2) {
		if (normalized_distance < 0.3) {
			return 1.0;
		}
		float t = (normalized_distance - 0.3) / 0.7;
		return 1.0 - smoothstep(0.0, 1.0, t);
	}
	return 1.0 - normalized_distance;
}

float hash12(vec2 p, float seed) {
	return fract(sin(dot(p, vec2(127.1, 311.7)) + seed * 0.001) * 43758.5453);
}

vec2 grad2(vec2 p, float seed) {
	float angle = hash12(p, seed) * 6.28318530718;
	return vec2(cos(angle), sin(angle));
}

float perlin2(vec2 p, float seed) {
	vec2 ip = floor(p);
	vec2 fp = fract(p);
	vec2 u = fp * fp * (3.0 - 2.0 * fp);

	float n00 = dot(grad2(ip + vec2(0.0, 0.0), seed), fp - vec2(0.0, 0.0));
	float n10 = dot(grad2(ip + vec2(1.0, 0.0), seed), fp - vec2(1.0, 0.0));
	float n01 = dot(grad2(ip + vec2(0.0, 1.0), seed), fp - vec2(0.0, 1.0));
	float n11 = dot(grad2(ip + vec2(1.0, 1.0), seed), fp - vec2(1.0, 1.0));

	float nx0 = mix(n00, n10, u.x);
	float nx1 = mix(n01, n11, u.x);
	return mix(nx0, nx1, u.y);
}

void cellular2(vec2 p, float seed, out float f1, out float f2, out float cell_value) {
	vec2 ip = floor(p);
	f1 = 1e9;
	f2 = 1e9;
	cell_value = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = ip + vec2(x, y);
			vec2 rand = vec2(hash12(cell, seed), hash12(cell + 13.37, seed));
			vec2 diff = (cell + rand) - p;
			float d = dot(diff, diff);
			if (d < f1) {
				f2 = f1;
				f1 = d;
				cell_value = rand.x;
			} else if (d < f2) {
				f2 = d;
			}
		}
	}
	f1 = sqrt(f1);
	f2 = sqrt(f2);
}

vec2 rotate2d(vec2 p, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

float shape_distance(vec2 pos, int shape_type, float radius) {
	vec2 abs_pos = abs(pos);
	if (shape_type == 0) {
		return length(pos);
	} else if (shape_type == 1) {
		return max(abs_pos.x, abs_pos.y);
	} else if (shape_type == 2) {
		return abs_pos.x + abs_pos.y;
	} else if (shape_type == 3) {
		float angle = atan(pos.y, pos.x);
		float star_radius = radius * (0.6 + 0.4 * abs(sin(angle * 2.5)));
		return length(pos) / star_radius * radius;
	} else if (shape_type == 4) {
		return min(abs_pos.x, abs_pos.y) * 2.0 + max(abs_pos.x, abs_pos.y) * 0.5;
	}
	return length(pos);
}

float sample_heightmap(int data_offset, ivec2 size, int wrap_mode, int invert, vec2 uv) {
	if (size.x <= 0 || size.y <= 0) {
		return 0.0;
	}

	float u = uv.x;
	float v = uv.y;
	if (wrap_mode == 1) {
		u = u - floor(u);
		v = v - floor(v);
	} else {
		u = clamp(u, 0.0, 1.0);
		v = clamp(v, 0.0, 1.0);
	}

	float x = u * float(size.x - 1);
	float y = v * float(size.y - 1);
	int x0 = int(floor(x));
	int y0 = int(floor(y));
	int x1 = min(x0 + 1, size.x - 1);
	int y1 = min(y0 + 1, size.y - 1);
	float dx = x - float(x0);
	float dy = y - float(y0);

	int idx00 = y0 * size.x + x0;
	int idx10 = y0 * size.x + x1;
	int idx01 = y1 * size.x + x0;
	int idx11 = y1 * size.x + x1;

	float h00 = param_floats[data_offset + idx00];
	float h10 = param_floats[data_offset + idx10];
	float h01 = param_floats[data_offset + idx01];
	float h11 = param_floats[data_offset + idx11];

	float h0 = mix(h00, h10, dx);
	float h1 = mix(h01, h11, dx);
	float h = mix(h0, h1, dy);

	if (invert == 1) {
		h = 1.0 - h;
	}
	return h;
}

float influence_normalized_distance(vec3 local_pos, int influence_shape, vec2 influence_size) {
	if (influence_shape == 0) {
		float radius = max(max(influence_size.x, influence_size.y), 0.0001);
		return length(local_pos.xz) / radius;
	} else if (influence_shape == 1) {
		vec2 half_size = influence_size * 0.5;
		if (half_size.x <= 0.0 || half_size.y <= 0.0) {
			return 2.0;
		}
		return max(abs(local_pos.x) / half_size.x, abs(local_pos.z) / half_size.y);
	} else if (influence_shape == 2) {
		vec2 half_size = influence_size * 0.5;
		if (half_size.x <= 0.0 || half_size.y <= 0.0) {
			return 2.0;
		}
		float nx = local_pos.x / half_size.x;
		float nz = local_pos.z / half_size.y;
		return sqrt(nx * nx + nz * nz);
	}
	return 2.0;
}

void main() {
	ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);
	if (pixel_coords.x >= params.resolution_x || pixel_coords.y >= params.resolution_y) {
		return;
	}

	float u = float(pixel_coords.x) / float(max(params.resolution_x - 1, 1));
	float v = float(pixel_coords.y) / float(max(params.resolution_y - 1, 1));
	float world_x = params.bounds_x + u * params.bounds_w;
	float world_z = params.bounds_y + v * params.bounds_h;

	// Base float layout indices
	int base_float = 0;
	vec3 world_pos = vec3(world_x, 0.0, world_z);
	vec2 influence_size = vec2(get_float(base_float + 3), get_float(base_float + 4));
	// Inverse basis (columns) and origin
	vec3 c0 = vec3(get_float(base_float + 7), get_float(base_float + 8), get_float(base_float + 9));
	vec3 c1 = vec3(get_float(base_float + 10), get_float(base_float + 11), get_float(base_float + 12));
	vec3 c2 = vec3(get_float(base_float + 13), get_float(base_float + 14), get_float(base_float + 15));
	vec3 inv_origin = vec3(get_float(base_float + 16), get_float(base_float + 17), get_float(base_float + 18));
	vec3 local_pos = c0 * world_pos.x + c1 * world_pos.y + c2 * world_pos.z + inv_origin;

	int influence_shape = get_int(0);

	float height = 0.0;
	if (params.feature_type == FEATURE_PRIMITIVE_HILL) {
		float hill_height = get_float(19);
		int shape_mode = get_int(2);
		float nd = influence_normalized_distance(local_pos, influence_shape, influence_size);
		float multiplier = hill_multiplier(nd, shape_mode);
		height = hill_height * multiplier;
	} else if (params.feature_type == FEATURE_PRIMITIVE_MOUNTAIN) {
		float mountain_height = get_float(19);
		float noise_strength = get_float(20);
		float noise_frequency = get_float(21);
		int peak_type = get_int(2);
		int noise_enabled = get_int(5);
		float nd = influence_normalized_distance(local_pos, influence_shape, influence_size);
		float multiplier = mountain_multiplier(nd, peak_type);
		height = mountain_height * multiplier;
		if (noise_enabled == 1 && noise_strength > 0.0) {
			float n_signed = perlin2(vec2(world_x * noise_frequency, world_z * noise_frequency), float(get_int(4)));
			height += n_signed * mountain_height * noise_strength * multiplier;
		}
	} else if (params.feature_type == FEATURE_PRIMITIVE_CRATER) {
		float crater_height = get_float(19);
		float rim_height = get_float(20);
		float rim_width = get_float(21);
		float floor_ratio = get_float(22);
		float radius = max(max(influence_size.x, influence_size.y), 0.0001);
		float dist = length(local_pos.xz);
		if (dist >= radius) {
			height = 0.0;
		} else {
			float floor_radius = radius * floor_ratio;
			if (dist < floor_radius) {
				height = -crater_height;
			} else {
				float slope_distance = (dist - floor_radius) / max(radius - floor_radius, 0.0001);
				float rim_peak_pos = rim_width;
				if (slope_distance < rim_peak_pos) {
					height = mix(-crater_height, rim_height, slope_distance / max(rim_peak_pos, 0.0001));
				} else {
					float fall_t = (slope_distance - rim_peak_pos) / max(1.0 - rim_peak_pos, 0.0001);
					height = mix(rim_height, 0.0, smoothstep(0.0, 1.0, fall_t));
				}
			}
		}
	} else if (params.feature_type == FEATURE_PRIMITIVE_VOLCANO) {
		float volcano_height = get_float(19);
		float crater_ratio = get_float(20);
		float crater_depth = get_float(21);
		float slope_concavity = get_float(22);
		float radius = max(max(influence_size.x, influence_size.y), 0.0001);
		float dist = length(local_pos.xz);
		if (dist >= radius) {
			height = 0.0;
		} else {
			float crater_radius = radius * crater_ratio;
			if (dist < crater_radius) {
				float crater_t = dist / max(crater_radius, 0.0001);
				height = volcano_height - (crater_depth * (1.0 - crater_t * crater_t));
			} else {
				float slope_distance = (dist - crater_radius) / max(radius - crater_radius, 0.0001);
				height = volcano_height * pow(1.0 - slope_distance, slope_concavity);
			}
		}
	} else if (params.feature_type == FEATURE_PRIMITIVE_ISLAND) {
		float island_height = get_float(19);
		float beach_width = get_float(20);
		float beach_height = get_float(21);
		float noise_strength = get_float(22);
		float noise_frequency = get_float(23);
		int noise_enabled = get_int(4);
		float radius = max(max(influence_size.x, influence_size.y), 0.0001);
		float dist = length(local_pos.xz);
		if (dist >= radius) {
			height = 0.0;
		} else {
			float normalized_distance = dist / radius;
			if (normalized_distance > (1.0 - beach_width)) {
				height = beach_height;
			} else {
				float inland_t = normalized_distance / max(1.0 - beach_width, 0.0001);
				height = island_height - (island_height - beach_height) * inland_t;
			}
			if (noise_enabled == 1 && noise_strength > 0.0) {
				float n_signed = perlin2(vec2(world_x * noise_frequency, world_z * noise_frequency), float(get_int(3)));
				height += height * (n_signed * noise_strength);
			}
			height = max(0.0, height);
		}
	} else if (params.feature_type == FEATURE_SHAPE) {
		float shape_height = get_float(19);
		float smoothness = get_float(20);
		float rotation = get_float(21);
		int shape_type = get_int(2);
		float radius = max(influence_size.x, 0.0001);
		vec2 pos_2d = rotate2d(local_pos.xz, rotation);
		float dist = shape_distance(pos_2d, shape_type, radius);
		if (dist >= radius) {
			height = 0.0;
		} else {
			float edge_start = radius * (1.0 - smoothness);
			float height_factor = 1.0;
			if (dist > edge_start && radius > edge_start) {
				float edge_t = (dist - edge_start) / max(radius - edge_start, 0.0001);
				height_factor = 1.0 - smoothstep(0.0, 1.0, edge_t);
			}
			height = shape_height * height_factor;
		}
	} else if (params.feature_type == FEATURE_HEIGHTMAP) {
		float height_scale = get_float(19);
		float height_offset = get_float(20);
		int wrap_mode = get_int(2);
		int invert = get_int(3);
		int size_x = get_int(4);
		int size_y = get_int(5);
		int data_offset = get_int(6);
		vec2 size = vec2(influence_size.x, influence_size.y);
		if (size.x > 0.0 && size.y > 0.0) {
			vec2 uv = vec2(local_pos.x / size.x + 0.5, local_pos.z / size.y + 0.5);
			float h = sample_heightmap(data_offset, ivec2(size_x, size_y), wrap_mode, invert, uv);
			height = (h * height_scale) + height_offset;
		}
	} else if (params.feature_type == FEATURE_GRADIENT_LINEAR) {
		float start_h = get_float(19);
		float end_h = get_float(20);
		vec2 dir = normalize(vec2(get_float(21), get_float(22)));
		int interpolation = get_int(2);
		vec2 pos_2d = local_pos.xz;
		float projected = dot(pos_2d, dir);
		float radius = max(influence_size.x, 0.0001);
		float t = (projected + radius) / (radius * 2.0);
		t = clamp(t, 0.0, 1.0);
		if (interpolation == 1) {
			t = smoothstep(0.0, 1.0, t);
		} else if (interpolation == 2) {
			t = t * t;
		} else if (interpolation == 3) {
			t = 1.0 - (1.0 - t) * (1.0 - t);
		}
		height = mix(start_h, end_h, t);
	} else if (params.feature_type == FEATURE_GRADIENT_RADIAL) {
		float start_h = get_float(19);
		float end_h = get_float(20);
		int falloff = get_int(2);
		float radius = max(max(influence_size.x, influence_size.y), 0.0001);
		float dist = length(world_pos.xz - vec2(get_float(0), get_float(2)));
		float nd = dist / radius;
		if (nd >= 1.0) {
			height = end_h;
		} else {
			float t = 0.0;
			if (falloff == 0) {
				t = nd;
			} else if (falloff == 1) {
				t = smoothstep(0.0, 1.0, nd);
			} else if (falloff == 2) {
				t = sqrt(nd);
			} else if (falloff == 3) {
				t = nd * nd;
			}
			height = mix(start_h, end_h, t);
		}
	} else if (params.feature_type == FEATURE_GRADIENT_CONE) {
		float start_h = get_float(19);
		float end_h = get_float(20);
		float sharpness = get_float(21);
		float radius = max(influence_size.x, 0.0001);
		float dist = length(local_pos.xz);
		if (dist >= radius) {
			height = end_h;
		} else {
			float nd = dist / radius;
			float height_factor = pow(1.0 - nd, sharpness);
			height = mix(end_h, start_h, height_factor);
		}
	} else if (params.feature_type == FEATURE_GRADIENT_HEMISPHERE) {
		float start_h = get_float(19);
		float end_h = get_float(20);
		float flatness = get_float(21);
		float radius = max(influence_size.x, 0.0001);
		float dist = length(local_pos.xz);
		if (dist >= radius) {
			height = end_h;
		} else {
			float nd = dist / radius;
			float height_factor = sqrt(max(0.0, 1.0 - nd * nd));
			if (flatness > 0.0 && nd < flatness) {
				height_factor = sqrt(max(0.0, 1.0 - flatness * flatness));
			}
			height = end_h + start_h * height_factor;
		}
	} else if (params.feature_type == FEATURE_LANDSCAPE_CANYON) {
		float canyon_height = get_float(19);
		vec2 dir = normalize(vec2(get_float(20), get_float(21)));
		vec2 perp = vec2(-dir.y, dir.x);
		float canyon_width = get_float(22);
		float wall_slope = get_float(23);
		float meander_strength = get_float(24);
		float noise_frequency = get_float(25);
		float normalized_distance = influence_normalized_distance(local_pos, influence_shape, influence_size);
		if (normalized_distance >= 1.0) {
			height = 0.0;
		} else {
			float lateral_distance = abs(dot(local_pos.xz, perp));
			float meander = perlin2(vec2(world_x * noise_frequency, world_z * noise_frequency), float(get_int(2))) * canyon_width * meander_strength;
			lateral_distance += meander;
			float half_width = canyon_width * 0.5;
			if (lateral_distance < half_width) {
				height = -canyon_height;
			} else if (lateral_distance < half_width + canyon_height / max(wall_slope, 0.0001)) {
				float wall_dist = lateral_distance - half_width;
				float wall_height = wall_dist * wall_slope;
				height = -canyon_height + wall_height;
			} else {
				height = 0.0;
			}
		}
	} else if (params.feature_type == FEATURE_LANDSCAPE_MOUNTAIN_RANGE) {
		float range_height = get_float(19);
		vec2 dir = normalize(vec2(get_float(20), get_float(21)));
		vec2 perp = vec2(-dir.y, dir.x);
		float ridge_sharpness = get_float(22);
		float peak_freq = get_float(23);
		float detail_freq = get_float(24);
		float normalized_distance = influence_normalized_distance(local_pos, influence_shape, influence_size);
		if (normalized_distance >= 1.0) {
			height = 0.0;
		} else {
			float lateral_distance = abs(dot(local_pos.xz, perp));
			float ridge_width = max(max(influence_size.x, influence_size.y), 0.0001);
			if (influence_shape != 0) {
				ridge_width = max(influence_size.y * 0.5, 0.0001);
			}
			float ridge_falloff = 1.0 - pow(lateral_distance / ridge_width, ridge_sharpness);
			ridge_falloff = max(0.0, ridge_falloff);
			height = range_height * ridge_falloff;
			float along_ridge = dot(local_pos.xz, dir);
			float peak_var = perlin2(vec2(along_ridge * peak_freq, 0.0), float(get_int(2)));
			height *= 0.7 + peak_var * 0.3;
			float detail = perlin2(vec2(world_x * detail_freq, world_z * detail_freq), float(get_int(3)));
			height += height * detail * 0.2;
		}
	} else if (params.feature_type == FEATURE_LANDSCAPE_DUNE_SEA) {
		float dune_height = get_float(19);
		vec2 dir = normalize(vec2(get_float(20), get_float(21)));
		vec2 perp = vec2(-dir.y, dir.x);
		float dune_frequency = get_float(22);
		float primary_freq = get_float(23);
		float detail_freq = get_float(24);
		float normalized_distance = influence_normalized_distance(local_pos, influence_shape, influence_size);
		if (normalized_distance >= 1.0) {
			height = 0.0;
		} else {
			float across_wind = dot(local_pos.xz, perp);
			float primary_noise = perlin2(vec2(world_x * primary_freq, world_z * primary_freq), float(get_int(2)));
			float dune_pattern = sin(across_wind * dune_frequency * 10.0 + primary_noise * 3.0);
			dune_pattern = (dune_pattern + 1.0) * 0.5;
			float height_variation = perlin2(vec2(world_x * 0.5, world_z * 0.5), float(get_int(2)));
			dune_pattern *= (0.5 + height_variation * 0.5);
			height = dune_height * dune_pattern;
			float ripples = perlin2(vec2(world_x * detail_freq, world_z * detail_freq), float(get_int(3)));
			height += ripples * 0.3;
			float edge_fade = 1.0 - pow(normalized_distance, 2.0);
			height *= edge_fade;
		}
	} else if (params.feature_type == FEATURE_NOISE_PERLIN) {
		float amplitude = get_float(19);
		float frequency = get_float(20);
		float n_signed = perlin2(vec2(world_x * frequency, world_z * frequency), float(get_int(3)));
		height = (n_signed + 1.0) * 0.5 * amplitude;
	} else if (params.feature_type == FEATURE_NOISE_VORONOI) {
		float amplitude = get_float(19);
		float frequency = get_float(20);
		int distance_mode = get_int(2);
		float f1;
		float f2;
		float cell_val;
		cellular2(vec2(world_x * frequency, world_z * frequency), float(get_int(5)), f1, f2, cell_val);
		float h = f1;
		if (distance_mode == 1) {
			h = f2;
		} else if (distance_mode == 2) {
			h = f2 - f1;
		} else if (distance_mode == 3) {
			h = cell_val;
		}
		height = h * amplitude;
	}

	imageStore(output_heightmap, pixel_coords, vec4(height, 0.0, 0.0, 1.0));
}
