#[compute]
#version 450

// Terrainy 2 control kernel: folds one TEXTURE paint layer (already resampled to plane pixels)
// into the per-layer weight planes of a region. Paint wins: every claim is scaled by (1 - p)
// and p is added to the painted layer. CPU twin: gen/build/control_maps.gd (paint loop).

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// claims: layer-major, layer_count * pixel_count floats
layout(std430, set = 0, binding = 0) restrict buffer Claims { float claims[]; };
layout(std430, set = 0, binding = 1) restrict readonly buffer Paint { float paint[]; };
// ints: [pixel_count, layer_count, target_layer]
layout(std430, set = 0, binding = 2) restrict readonly buffer IParams { int ip[]; };

void main() {
	int i = int(gl_GlobalInvocationID.x);
	if (i >= ip[0]) {
		return;
	}
	float p = min(paint[i], 1.0);
	if (p <= 0.0) {
		return;
	}
	for (int j = 0; j < ip[1]; j++) {
		claims[j * ip[0] + i] *= 1.0 - p;
	}
	claims[ip[2] * ip[0] + i] += p;
}
