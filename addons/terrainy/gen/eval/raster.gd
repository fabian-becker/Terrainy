@tool
extends RefCounted

## Shared rasterization helpers (worker safe, pure CPU).

## Normalized distance (0 = center, 1 = edge, > 1 outside) of a local XZ point in a shape
## with half extents [param half].
static func shape_distance(shape: int, lx: float, lz: float, half: Vector2) -> float:
	match shape:
		TerrainTypes.RegionShape.CIRCLE:
			var r := maxf(maxf(half.x, half.y), 0.0001)
			return sqrt(lx * lx + lz * lz) / r
		TerrainTypes.RegionShape.RECTANGLE:
			return maxf(absf(lx) / maxf(half.x, 0.0001), absf(lz) / maxf(half.y, 0.0001))
		_:
			var dx := lx / maxf(half.x, 0.0001)
			var dz := lz / maxf(half.y, 0.0001)
			return sqrt(dx * dx + dz * dz)

static func shape_half_extents(shape: int, size: Vector2) -> Vector2:
	if shape == TerrainTypes.RegionShape.CIRCLE:
		var r := maxf(maxf(size.x, size.y) * 0.5, 0.0001)
		return Vector2(r, r)
	return Vector2(maxf(size.x * 0.5, 0.0001), maxf(size.y * 0.5, 0.0001))

## World XZ bounds of a shape under [param xform] (rotation aware).
static func shape_bounds(xform: Transform3D, half: Vector2) -> Rect2:
	var corners := [
		xform * Vector3(-half.x, 0, -half.y), xform * Vector3(half.x, 0, -half.y),
		xform * Vector3(half.x, 0, half.y), xform * Vector3(-half.x, 0, half.y),
	]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in corners:
		lo = Vector2(minf(lo.x, c.x), minf(lo.y, c.z))
		hi = Vector2(maxf(hi.x, c.x), maxf(hi.y, c.z))
	return Rect2(lo, hi - lo)

## Resample a Curve3D into a world-space polyline with roughly [param step] spacing.
## Point y values are world heights minus [param y_reference].
static func polyline_from_curve(curve: Curve3D, xform: Transform3D, step: float, y_reference: float = 0.0) -> PackedVector3Array:
	var points := PackedVector3Array()
	if curve == null or curve.point_count < 2:
		return points
	var length := curve.get_baked_length()
	if length <= 0.0:
		return points
	var count := clampi(int(ceil(length / maxf(step, 0.05))), 1, 4096)
	for i in count + 1:
		var p := xform * curve.sample_baked(length * float(i) / float(count), true)
		p.y -= y_reference
		points.append(p)
	return points

static func polyline_bounds(points: PackedVector3Array, pad: float) -> Rect2:
	if points.is_empty():
		return Rect2()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in points:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
	lo -= Vector2(pad, pad)
	hi += Vector2(pad, pad)
	return Rect2(lo, hi - lo)

## Corridor rasterization fast path: instead of testing every pixel against every segment, each
## segment only visits the pixels of its own bounding box grown by [param reach]. Returns
## `{"dist": PackedFloat32Array, "elev": PackedFloat32Array}` over [param rect] (row-major):
## the distance to the nearest point of the polyline (INF where farther than reach) and the
## polyline height at that point.
static func rasterize_polyline(points: PackedVector3Array, reach: float, grid, rect: Rect2i) -> Dictionary:
	var w := rect.size.x
	var h := rect.size.y
	var dist := PackedFloat32Array()
	var elev := PackedFloat32Array()
	dist.resize(w * h)
	elev.resize(w * h)
	dist.fill(INF)
	if points.size() < 2 or w <= 0 or h <= 0:
		return {"dist": dist, "elev": elev}
	var reach_sq := reach * reach
	var cell: float = grid.cell
	var ox: float = grid.origin.x
	var oz: float = grid.origin.y
	for s in points.size() - 1:
		var a := points[s]
		var b := points[s + 1]
		var abx := b.x - a.x
		var abz := b.z - a.z
		var len_sq := abx * abx + abz * abz
		var inv_len := 1.0 / len_sq if len_sq > 1e-12 else 0.0
		var x0 := maxi(int(floor((minf(a.x, b.x) - reach - ox) / cell)), rect.position.x)
		var x1 := mini(int(ceil((maxf(a.x, b.x) + reach - ox) / cell)), rect.end.x - 1)
		var z0 := maxi(int(floor((minf(a.z, b.z) - reach - oz) / cell)), rect.position.y)
		var z1 := mini(int(ceil((maxf(a.z, b.z) + reach - oz) / cell)), rect.end.y - 1)
		for gz in range(z0, z1 + 1):
			var wz := oz + gz * cell
			var row := (gz - rect.position.y) * w - rect.position.x
			for gx in range(x0, x1 + 1):
				var wx := ox + gx * cell
				var t := ((wx - a.x) * abx + (wz - a.z) * abz) * inv_len
				t = clampf(t, 0.0, 1.0)
				var px := a.x + abx * t - wx
				var pz := a.z + abz * t - wz
				var d_sq := px * px + pz * pz
				if d_sq > reach_sq:
					continue
				var i := row + gx
				var d := sqrt(d_sq)
				if d < dist[i]:
					dist[i] = d
					elev[i] = lerpf(a.y, b.y, t)
	return {"dist": dist, "elev": elev}

## Reference (slow) nearest-point query used by the parity tests of the fast path.
static func polyline_nearest(points: PackedVector3Array, wx: float, wz: float) -> Vector2:
	var best := INF
	var best_elev := 0.0
	for s in points.size() - 1:
		var a := points[s]
		var b := points[s + 1]
		var abx := b.x - a.x
		var abz := b.z - a.z
		var len_sq := abx * abx + abz * abz
		var t := 0.0
		if len_sq > 1e-12:
			t = clampf(((wx - a.x) * abx + (wz - a.z) * abz) / len_sq, 0.0, 1.0)
		var px := a.x + abx * t - wx
		var pz := a.z + abz * t - wz
		var d := sqrt(px * px + pz * pz)
		if d < best:
			best = d
			best_elev = lerpf(a.y, b.y, t)
	return Vector2(best, best_elev)

## Bilinear sample of a row-major float buffer at fractional pixel coordinates (clamped).
static func sample_buffer(buffer: PackedFloat32Array, size: Vector2i, fx: float, fy: float) -> float:
	if size.x <= 0 or size.y <= 0 or buffer.size() < size.x * size.y:
		return 0.0
	fx = clampf(fx, 0.0, float(size.x - 1))
	fy = clampf(fy, 0.0, float(size.y - 1))
	var x0 := int(fx)
	var y0 := int(fy)
	var x1 := mini(x0 + 1, size.x - 1)
	var y1 := mini(y0 + 1, size.y - 1)
	var tx := fx - x0
	var ty := fy - y0
	var a := lerpf(buffer[y0 * size.x + x0], buffer[y0 * size.x + x1], tx)
	var b := lerpf(buffer[y1 * size.x + x0], buffer[y1 * size.x + x1], tx)
	return lerpf(a, b, ty)

static func smoothstep01(e0: float, e1: float, x: float) -> float:
	if e1 == e0:
		return 0.0 if x < e0 else 1.0
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

## Single channel float copy of an image (red channel or luminance).
static func image_channel(image: Image, use_luminance: bool = false) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if image == null or image.is_empty():
		return out
	var copy := image.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	if use_luminance:
		copy.convert(Image.FORMAT_RGBAF)
		var rgba := copy.get_data().to_float32_array()
		out.resize(rgba.size() / 4)
		for i in out.size():
			out[i] = rgba[i * 4] * 0.2126 + rgba[i * 4 + 1] * 0.7152 + rgba[i * 4 + 2] * 0.0722
		return out
	copy.convert(Image.FORMAT_RF)
	return copy.get_data().to_float32_array()
