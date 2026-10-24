#[compute]
#version 450

// Terrainy 2 paint kernel: applies a stamp list to a rect of a paint layer.
// CPU twin: gen/paint/paint_stamper.gd apply_buffers() - keep the op math in sync.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) restrict buffer Value { float value[]; };
layout(std430, set = 0, binding = 1) restrict buffer Coverage { float coverage[]; };
layout(std430, set = 0, binding = 2) restrict readonly buffer Surface { float surface[]; };
layout(std430, set = 0, binding = 3) restrict readonly buffer Avg { float avg_h[]; };
layout(std430, set = 0, binding = 4) restrict readonly buffer Noise { float noise_v[]; };
// 8 floats per stamp: op, x, z, radius, strength, value, erase, lut index
layout(std430, set = 0, binding = 5) restrict readonly buffer Stamps { float stamps[]; };
layout(std430, set = 0, binding = 6) restrict readonly buffer Luts { float luts[]; };
// ints: [kind, rect_x, rect_y, rect_w, rect_h, grid, stamp_count, lut_size]
layout(std430, set = 0, binding = 7) restrict readonly buffer IParams { int ip[]; };
// floats: [world_x, world_z, world_size, opacity]
layout(std430, set = 0, binding = 8) restrict readonly buffer FParams { float fp[]; };

const int K_DELTA = 0;
const int K_ABSOLUTE = 1;
const int OP_RAISE = 0;
const int OP_LOWER = 1;
const int OP_FLATTEN = 2;
const int OP_SMOOTH = 3;
const int OP_NOISE = 4;
const int OP_SET = 5;

float lut_sample(int index, float x) {
	int n = ip[7];
	float f = clamp(x, 0.0, 1.0) * float(n - 1);
	int i = int(f);
	int base = index * n;
	if (i >= n - 1) {
		return luts[base + n - 1];
	}
	return mix(luts[base + i], luts[base + i + 1], f - float(i));
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= ip[3] || p.y >= ip[4]) {
		return;
	}
	int kind = ip[0];
	float px = fp[2] / float(ip[5]);
	float wx = fp[0] + (float(ip[1] + p.x) + 0.5) * px;
	float wz = fp[1] + (float(ip[2] + p.y) + 0.5) * px;
	int i = p.y * ip[3] + p.x;
	float opacity = fp[3];
	float v = value[i];
	float v0 = v;
	float c = kind == K_ABSOLUTE ? coverage[i] : 0.0;
	bool is_height = kind == K_DELTA || kind == K_ABSOLUTE;
	for (int s = 0; s < ip[6]; s++) {
		int b = s * 8;
		float dx = wx - stamps[b + 1];
		float dz = wz - stamps[b + 2];
		float radius = stamps[b + 3];
		float dist = sqrt(dx * dx + dz * dz);
		if (dist >= radius) {
			continue;
		}
		float f = lut_sample(int(stamps[b + 7]), 1.0 - dist / radius);
		float amount = stamps[b + 4] * f;
		if (amount == 0.0) {
			continue;
		}
		int op = int(stamps[b]);
		float target = stamps[b + 5];
		bool erase = stamps[b + 6] > 0.5;
		if (is_height) {
			float current = surface[i] + (v - v0) * opacity;
			if (kind == K_ABSOLUTE) {
				current = c <= 0.0 ? surface[i] : mix(surface[i], v, c * opacity);
			}
			if (op == OP_RAISE || op == OP_LOWER) {
				float sgn = ((op == OP_LOWER) != erase) ? -1.0 : 1.0;
				if (kind == K_ABSOLUTE) {
					if (c <= 0.0) {
						v = surface[i];
					}
					v += sgn * amount;
					c = min(c + clamp(amount, 0.0, 1.0), 1.0);
				} else {
					v += sgn * amount;
				}
			} else if (op == OP_FLATTEN || op == OP_SET) {
				float k = clamp(amount, 0.0, 1.0);
				if (kind == K_ABSOLUTE) {
					if (erase) {
						c = max(c - k, 0.0);
					} else {
						v = c <= 0.0 ? target : mix(v, target, k);
						c = min(c + k, 1.0);
					}
				} else if (op == OP_SET) {
					v = mix(v, target, k);
				} else {
					v += (target - current) * k / max(opacity, 0.0001);
				}
			} else if (op == OP_SMOOTH) {
				float k2 = clamp(amount, 0.0, 1.0);
				if (kind == K_ABSOLUTE) {
					if (c > 0.0) {
						v = mix(v, avg_h[i], k2);
					}
				} else {
					v += (avg_h[i] - current) * k2 / max(opacity, 0.0001);
				}
			} else if (op == OP_NOISE) {
				v += (erase ? -1.0 : 1.0) * amount * noise_v[i];
			} else if (kind == K_ABSOLUTE) {
				c = clamp(c + (erase ? -amount : amount), 0.0, 1.0);
			}
		} else {
			if (op == OP_SET) {
				v = mix(v, target, clamp(amount, 0.0, 1.0));
			} else {
				v = clamp(v + ((erase || op == OP_LOWER) ? -amount : amount), 0.0, 1.0);
			}
		}
	}
	value[i] = v;
	if (kind == K_ABSOLUTE) {
		coverage[i] = c;
	}
}
