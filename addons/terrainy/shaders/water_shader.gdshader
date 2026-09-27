shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_lambert, specular_schlick_ggx;

// Water colors
uniform vec4 water_color_shallow : source_color = vec4(0.2, 0.6, 0.8, 0.8);
uniform vec4 water_color_deep : source_color = vec4(0.05, 0.2, 0.4, 0.95);

// Depth parameters
uniform float depth_max : hint_range(0.1, 50.0) = 10.0;
uniform float water_level : hint_range(-100.0, 100.0) = 0.0;

// Shape parameters (0 = circle, 1 = rectangle, 2 = ellipse)
uniform int influence_shape : hint_range(0, 2) = 0;
uniform vec2 influence_size = vec2(50.0, 50.0);

// Foam
uniform float foam_width : hint_range(0.0, 10.0) = 2.0;
uniform float foam_intensity : hint_range(0.0, 1.0) = 0.8;
uniform float foam_tiling : hint_range(0.1, 10.0) = 1.0;
uniform sampler2D foam_texture : filter_linear_mipmap_anisotropic, repeat_enable;

// Waves
uniform float wave_speed : hint_range(0.0, 5.0) = 1.0;
uniform float wave_height : hint_range(0.0, 2.0) = 0.2;
uniform float wave_frequency : hint_range(0.1, 10.0) = 2.0;
uniform float wave_tiling : hint_range(0.1, 20.0) = 1.0;
uniform sampler2D wave_normal : filter_linear_mipmap_anisotropic, repeat_enable;

// Depth texture
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

// Flags
uniform bool use_foam_texture = false;
uniform bool use_wave_normal = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.5;

// Time
uniform float time_scale : hint_range(0.0, 5.0) = 1.0;

// Varying
varying vec3 world_pos;
varying vec3 local_pos;
varying vec2 uv_coords;

// Noise function for foam variation
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

void vertex() {
	// Store world position and UV
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	local_pos = VERTEX.xyz;
	uv_coords = UV;
	
	// Apply wave displacement
	float time = TIME * time_scale;
	float wave_offset = sin(world_pos.x * wave_frequency + time * wave_speed) 
		* cos(world_pos.z * wave_frequency * 0.7 + time * wave_speed * 0.8);
	
	// Multiple wave frequencies for more natural look
	float wave2 = sin(world_pos.x * wave_frequency * 2.3 + time * wave_speed * 1.3) 
		* cos(world_pos.z * wave_frequency * 1.9 + time * wave_speed * 1.1);
	
	VERTEX.y += (wave_offset * 0.7 + wave2 * 0.3) * wave_height;
}

void fragment() {
	float time = TIME * time_scale;
	
	// Compute true water thickness using scene depth
	float scene_depth_raw = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 screen_pos = vec4(SCREEN_UV * 2.0 - 1.0, scene_depth_raw, 1.0);
	vec4 view_pos = INV_PROJECTION_MATRIX * screen_pos;
	view_pos.xyz /= view_pos.w;
	float scene_depth = -view_pos.z;
	float surface_depth = -VERTEX.z;
	float water_thickness = max(scene_depth - surface_depth, 0.0);
	float depth_factor = clamp(water_thickness / depth_max, 0.0, 1.0);
	
	// Blend between shallow and deep colors
	vec4 water_color = mix(water_color_shallow, water_color_deep, depth_factor);
	
	// Backface handling: darken and make more opaque so water looks solid from below
	vec3 base_normal = NORMAL;
	if (!FRONT_FACING) {
		base_normal = -base_normal;
		water_color.rgb *= 0.75;
		water_color.a = min(water_color.a + 0.25, 1.0);
	}
	
	// Sample wave normal for surface detail
	vec2 uv_offset = vec2(time * wave_speed * 0.1, time * wave_speed * 0.05);
	vec2 wave_uv = world_pos.xz * wave_tiling + uv_offset;
	
	vec3 computed_normal;
	if (use_wave_normal) {
		vec3 normal_map_sample = texture(wave_normal, wave_uv).rgb;
		computed_normal = normalize(normal_map_sample * 2.0 - 1.0);
	} else {
		// Procedural normal from derivative
		float nx = sin(world_pos.x * wave_frequency + time * wave_speed * 0.5);
		float nz = cos(world_pos.z * wave_frequency + time * wave_speed * 0.3);
		computed_normal = normalize(vec3(nx * 0.3, 1.0, nz * 0.3));
	}
	
	// Apply normal strength
	computed_normal.xy *= normal_strength;
	computed_normal = normalize(computed_normal);
	
	// Flip normal for backfaces so the water looks solid from below
	if (!FRONT_FACING) {
		computed_normal = -computed_normal;
	}
	
	NORMAL_MAP = computed_normal;
	
	// Calculate foam at shorelines (based on depth)
	float foam_noise = fbm(world_pos.xz * foam_tiling + time * 0.5);
	float foam_mask = 0.0;
	
	// Foam appears in shallow water and at random foam patches
	float shoreline_factor = 1.0 - clamp(water_thickness / foam_width, 0.0, 1.0);
	shoreline_factor = pow(shoreline_factor, 2.0); // Sharpen the edge
	
	// Combine shoreline foam with noise
	foam_mask = shoreline_factor * foam_intensity;
	foam_mask += foam_noise * 0.15 * foam_intensity;
	foam_mask = clamp(foam_mask, 0.0, 1.0);
	
	// Sample foam texture if available
	vec3 final_color = water_color.rgb;
	float final_alpha = mix(water_color_shallow.a, water_color_deep.a, depth_factor);
	
	if (use_foam_texture && foam_intensity > 0.0) {
		vec2 foam_uv = world_pos.xz * foam_tiling + vec2(foam_noise * 0.1);
		float foam_tex = texture(foam_texture, foam_uv).r;
		vec3 foam_color = mix(vec3(1.0), vec3(0.9, 0.95, 1.0), foam_tex);
		final_color = mix(final_color, foam_color, foam_mask * foam_intensity);
	} else if (foam_intensity > 0.0) {
		// Procedural foam
		vec3 foam_color = vec3(1.0);
		final_color = mix(final_color, foam_color, foam_mask * foam_intensity);
	}
	
	// Apply alpha
	ALBEDO = final_color;
	ROUGHNESS = mix(0.1, 0.8, foam_mask); // Foam is rougher
	METALLIC = 0.0;
	
	// Fake chromatic light diffraction at glancing angles
	vec3 view_dir = normalize(CAMERA_POSITION_WORLD - world_pos);
	float fresnel = pow(1.0 - abs(dot(view_dir, base_normal)), 3.0);
	vec3 chromatic = vec3(fresnel * 1.1, fresnel * 0.9, fresnel * 0.7) * 0.4;
	ALBEDO += chromatic;
	
	// Shape masking for circle/ellipse/rectangle
	float shape_alpha = 1.0;
	
	if (influence_shape == 0) {
		// Circle
		float radius = max(max(influence_size.x, influence_size.y) * 0.5, 0.001);
		float dist = length(local_pos.xz) / radius;
		shape_alpha = 1.0 - smoothstep(0.98, 1.0, dist);
	} else if (influence_shape == 1) {
		// Rectangle
		vec2 half_size = influence_size * 0.5;
		vec2 pos_2d = local_pos.xz / max(half_size, vec2(0.001));
		vec2 abs_pos = abs(pos_2d);
		float max_dist = max(abs_pos.x, abs_pos.y);
		shape_alpha = 1.0 - smoothstep(0.98, 1.0, max_dist);
	} else {
		// Ellipse
		vec2 half_size = max(influence_size * 0.5, vec2(0.001));
		vec2 pos_2d = local_pos.xz / half_size;
		float dist_sq = dot(pos_2d, pos_2d);
		shape_alpha = 1.0 - smoothstep(0.96, 1.0, sqrt(dist_sq));
	}
	
	// Transparency based on depth and foam
	final_alpha = mix(final_alpha, 1.0, foam_mask * foam_intensity);
	ALPHA = final_alpha * shape_alpha;
	
	// Specular for water shininess
	SPECULAR = 0.5;
}