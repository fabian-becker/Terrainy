#[compute]
#version 450

// Terrainy 2 compositor: blends one unit map into a target map over their overlap.
// CPU twin: gen/eval/composer.gd blend() / blend_value() - keep the formulas in sync.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) restrict buffer Target { float target[]; };
layout(std430, set = 0, binding = 1) restrict readonly buffer Src { float src[]; };
layout(std430, set = 0, binding = 2) restrict readonly buffer Weights { float weights[]; };
// ints: [target_x, target_y, target_w, src_x, src_y, src_w, rect_x, rect_y, rect_w, rect_h, mode]
layout(std430, set = 0, binding = 3) restrict readonly buffer IParams { int ip[]; };
// floats: [scale]
layout(std430, set = 0, binding = 4) restrict readonly buffer FParams { float fp[]; };

float blend_value(float t, float h, float ws, int mode) {
	if (mode == 0) return t + h * ws;
	if (mode == 1) return t - h * ws;
	if (mode == 2) return t + (max(t, h) - t) * min(ws, 1.0);
	if (mode == 3) return t + (min(t, h) - t) * min(ws, 1.0);
	if (mode == 4) return t * (1.0 + h * ws);
	if (mode == 5) return t + ((t + h) * 0.5 - t) * min(ws, 1.0);
	if (mode == 6) return t + (h - t) * min(ws, 1.0);
	return t + h * ws;
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= ip[8] || p.y >= ip[9]) {
		return;
	}
	int gx = ip[6] + p.x;
	int gy = ip[7] + p.y;
	int si = (gy - ip[4]) * ip[5] + (gx - ip[3]);
	float ws = weights[si] * fp[0];
	if (ws <= 0.0) {
		return;
	}
	int ti = (gy - ip[1]) * ip[2] + (gx - ip[0]);
	target[ti] = blend_value(target[ti], src[si], ws, ip[10]);
}
