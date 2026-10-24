#[compute]
#version 450

// Terrainy 2 field kernel: Region domain x profile LUT x falloff LUT (no relief: noise stays
// on the CPU, as in 0.7). CPU twin: gen/eval/field_snapshot.gd evaluate().

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) restrict writeonly buffer OutH { float out_h[]; };
layout(std430, set = 0, binding = 1) restrict writeonly buffer OutW { float out_w[]; };
layout(std430, set = 0, binding = 2) restrict readonly buffer Profile { float profile_lut[]; };
layout(std430, set = 0, binding = 3) restrict readonly buffer Falloff { float falloff_lut[]; };
// ints: [rect_x, rect_y, rect_w, rect_h, shape, has_falloff, lut_size]
layout(std430, set = 0, binding = 4) restrict readonly buffer IParams { int ip[]; };
// floats: [b00,b01,b02, b10,b11,b12, b20,b21,b22 (inverse basis, row major: l = B*v + o),
//          o.x,o.y,o.z, node_y, half.x, half.y, origin.x, origin.y, cell, profile_height,
//          base, strength]
layout(std430, set = 0, binding = 5) restrict readonly buffer FParams { float fp[]; };

float lut(int which, float x) {
	int n = ip[6];
	float f = clamp(x, 0.0, 1.0) * float(n - 1);
	int i = int(f);
	if (i >= n - 1) {
		return which == 0 ? profile_lut[n - 1] : falloff_lut[n - 1];
	}
	float a = which == 0 ? profile_lut[i] : falloff_lut[i];
	float b = which == 0 ? profile_lut[i + 1] : falloff_lut[i + 1];
	return mix(a, b, f - float(i));
}

float shape_distance(int shape, float lx, float lz, vec2 h) {
	if (shape == 0) {
		float r = max(max(h.x, h.y), 0.0001);
		return sqrt(lx * lx + lz * lz) / r;
	}
	if (shape == 2) {
		return max(abs(lx) / max(h.x, 0.0001), abs(lz) / max(h.y, 0.0001));
	}
	float dx = lx / max(h.x, 0.0001);
	float dz = lz / max(h.y, 0.0001);
	return sqrt(dx * dx + dz * dz);
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= ip[2] || p.y >= ip[3]) {
		return;
	}
	int i = p.y * ip[2] + p.x;
	float gx = fp[15] + float(ip[0] + p.x) * fp[17];
	float gz = fp[16] + float(ip[1] + p.y) * fp[17];
	vec3 v = vec3(gx, fp[12], gz);
	float lx = fp[0] * v.x + fp[1] * v.y + fp[2] * v.z + fp[9];
	float lz = fp[6] * v.x + fp[7] * v.y + fp[8] * v.z + fp[11];
	float d = shape_distance(ip[4], lx, lz, vec2(fp[13], fp[14]));
	float e = d < 1.0 ? 1.0 - d : 0.0;
	if (e <= 0.0) {
		out_h[i] = 0.0;
		out_w[i] = 0.0;
		return;
	}
	float weight = (ip[5] != 0 ? lut(1, e) : 1.0) * fp[20];
	if (weight <= 0.0) {
		out_h[i] = 0.0;
		out_w[i] = 0.0;
		return;
	}
	out_h[i] = fp[19] + lut(0, e) * fp[18];
	out_w[i] = weight;
}
