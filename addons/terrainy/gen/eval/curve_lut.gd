@tool
extends RefCounted

## Bakes [Curve] resources into lookup tables so worker threads (and the GPU kernels) never
## touch a Resource while composing. Sampling is linear between LUT entries over x in [0, 1].

const LUT_SIZE: int = 256

## LUT of [param curve] over x in [0, 1]. A null curve bakes the constant [param fallback].
static func bake(curve: Curve, fallback: float = 1.0, size: int = LUT_SIZE) -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	lut.resize(size)
	if curve == null or curve.point_count == 0:
		lut.fill(fallback)
		return lut
	var min_x: float = curve.min_domain
	var max_x: float = curve.max_domain
	for i in size:
		var t := float(i) / float(size - 1)
		lut[i] = curve.sample(lerpf(min_x, max_x, t))
	return lut

static func sample(lut: PackedFloat32Array, x: float) -> float:
	var n := lut.size()
	if n == 0:
		return 1.0
	var f := clampf(x, 0.0, 1.0) * float(n - 1)
	var i := int(f)
	if i >= n - 1:
		return lut[n - 1]
	return lerpf(lut[i], lut[i + 1], f - i)

## Fresh falloff curve that reproduces the 0.7 analytic falloff (edge_falloff = 0.3):
## weight = smoothstep(0, 0.3, e) with e = 0 at the domain edge and 1 at its center.
## Two points with zero tangents make Godot's cubic Bezier exactly that smoothstep.
static func default_falloff() -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.0), 0.0, 0.0)
	curve.add_point(Vector2(0.3, 1.0), 0.0, 0.0)
	curve.add_point(Vector2(1.0, 1.0), 0.0, 0.0)
	return curve

## 0.7 analytic falloff, kept as the reference for the default curve test.
static func analytic_falloff(e: float, edge_falloff: float = 0.3) -> float:
	if e <= 0.0:
		return 0.0
	if edge_falloff <= 0.0 or e >= edge_falloff:
		return 1.0
	var t := e / edge_falloff
	return t * t * (3.0 - 2.0 * t)
