@tool
extends RefCounted

## CPU twin of the `paint_apply` GPU kernel: applies a stamp list to a paint layer image.
##
## The work is expressed over flat buffers for the affected pixel rect so the CPU and the GPU
## path consume identical inputs:
## - value / coverage: the layer channels (coverage only for HEIGHT_ABSOLUTE)
## - surface: current terrain height (generator-local) at each pixel before the batch
## - surface_avg: local average of that surface (SMOOTH op on height layers)
## - noise: world-anchored noise per pixel (STAMP_NOISE)
## - stamps: STAMP_STRIDE floats per stamp, falloff LUTs concatenated (LUT_SIZE each)
##
## Stamps run in list order per pixel; height ops see the effect of earlier stamps of the same
## batch through `current = surface + (value - value_before) * opacity`.

const BrushStamp = preload("res://addons/terrainy/gen/paint/brush_stamp.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")
const PaintKind = TerrainPaintLayer.PaintKind

const STAMP_STRIDE: int = 8
const LUT_SIZE: int = 64

## Pack stamps into the shared flat layout. Returns {"stamps": PackedFloat32Array, "luts": PackedFloat32Array}.
static func pack(stamps: Array) -> Dictionary:
	var packed := PackedFloat32Array()
	var luts := PackedFloat32Array()
	for i in stamps.size():
		var s = stamps[i]
		packed.append_array(PackedFloat32Array([
			float(s.op), s.position.x, s.position.z, s.radius, s.strength, s.value,
			1.0 if s.erase else 0.0, float(i)
		]))
		var lut: PackedFloat32Array = s.falloff_lut
		if lut.size() != LUT_SIZE:
			lut = _resample_lut(lut)
		luts.append_array(lut)
	return {"stamps": packed, "luts": luts}

static func _resample_lut(lut: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(LUT_SIZE)
	for i in LUT_SIZE:
		var x := float(i) / float(LUT_SIZE - 1)
		out[i] = CurveLut.sample(lut, x) if not lut.is_empty() else (x * x * (3.0 - 2.0 * x))
	return out

static func lut_sample(luts: PackedFloat32Array, index: int, x: float) -> float:
	var f := clampf(x, 0.0, 1.0) * float(LUT_SIZE - 1)
	var i := int(f)
	var base := index * LUT_SIZE
	if i >= LUT_SIZE - 1:
		return luts[base + LUT_SIZE - 1]
	return lerpf(luts[base + i], luts[base + i + 1], f - i)

## Paint pixel rect touched by [param stamps] on a layer of [param grid] px over [param world].
static func stamps_rect(stamps: Array, world: Rect2, grid: int) -> Rect2i:
	var px := world.size.x / float(grid)
	var result := Rect2i()
	var first := true
	for s in stamps:
		var x0 := int(floor((s.position.x - s.radius - world.position.x) / px))
		var y0 := int(floor((s.position.z - s.radius - world.position.y) / px))
		var x1 := int(ceil((s.position.x + s.radius - world.position.x) / px))
		var y1 := int(ceil((s.position.z + s.radius - world.position.y) / px))
		var r := Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
		result = r if first else result.merge(r)
		first = false
	return result.intersection(Rect2i(0, 0, grid, grid))

## Read the layer channels of [param rect] as float buffers {"value", "coverage"}.
static func read_buffers(image: Image, kind: int, rect: Rect2i) -> Dictionary:
	var region := image.get_region(rect)
	var value := PackedFloat32Array()
	var coverage := PackedFloat32Array()
	match kind:
		PaintKind.HEIGHT_DELTA:
			value = region.get_data().to_float32_array()
		PaintKind.HEIGHT_ABSOLUTE:
			var rg := region.get_data().to_float32_array()
			value.resize(rg.size() / 2)
			coverage.resize(rg.size() / 2)
			for i in value.size():
				value[i] = rg[i * 2]
				coverage[i] = rg[i * 2 + 1]
		_:
			region.convert(Image.FORMAT_RF)
			value = region.get_data().to_float32_array()
	return {"value": value, "coverage": coverage}

## Write float buffers back into the layer image (weight kinds are quantized to R8).
static func write_buffers(image: Image, kind: int, rect: Rect2i, value: PackedFloat32Array, coverage: PackedFloat32Array) -> void:
	var region: Image
	match kind:
		PaintKind.HEIGHT_DELTA:
			region = Image.create_from_data(rect.size.x, rect.size.y, false, Image.FORMAT_RF, value.to_byte_array())
		PaintKind.HEIGHT_ABSOLUTE:
			var rg := PackedFloat32Array()
			rg.resize(value.size() * 2)
			for i in value.size():
				rg[i * 2] = value[i]
				rg[i * 2 + 1] = coverage[i]
			region = Image.create_from_data(rect.size.x, rect.size.y, false, Image.FORMAT_RGF, rg.to_byte_array())
		_:
			var bytes := PackedByteArray()
			bytes.resize(value.size())
			for i in value.size():
				bytes[i] = int(round(clampf(value[i], 0.0, 1.0) * 255.0))
			region = Image.create_from_data(rect.size.x, rect.size.y, false, Image.FORMAT_R8, bytes)
	image.blit_rect(region, Rect2i(Vector2i.ZERO, rect.size), rect.position)

## Side inputs for the height ops: surface heights, their local average and the noise,
## sampled at the centers of the pixels of [param rect]. [param height_at] maps world XZ ->
## generator-local height; [param avg_radius] is in meters.
static func gather_inputs(rect: Rect2i, world: Rect2, grid: int, stamps: Array, height_at: Callable, avg_radius: float) -> Dictionary:
	var n := rect.size.x * rect.size.y
	var surface := PackedFloat32Array()
	var avg := PackedFloat32Array()
	var noise := PackedFloat32Array()
	surface.resize(n)
	avg.resize(n)
	noise.resize(n)
	var needs_surface := false
	var needs_avg := false
	var noise_src: FastNoiseLite = null
	for s in stamps:
		if s.op == BrushStamp.StrokeOp.FLATTEN or s.op == BrushStamp.StrokeOp.SMOOTH:
			needs_surface = true
		if s.op == BrushStamp.StrokeOp.SMOOTH:
			needs_avg = true
		if s.op == BrushStamp.StrokeOp.STAMP_NOISE and s.noise != null:
			noise_src = s.noise
	if not (needs_surface or noise_src):
		return {"surface": surface, "avg": avg, "noise": noise}
	var px := world.size.x / float(grid)
	var r := maxf(avg_radius, px)
	for y in rect.size.y:
		var wz := world.position.y + (rect.position.y + y + 0.5) * px
		for x in rect.size.x:
			var wx := world.position.x + (rect.position.x + x + 0.5) * px
			var i := y * rect.size.x + x
			if needs_surface and height_at.is_valid():
				surface[i] = height_at.call(Vector2(wx, wz))
				if needs_avg:
					var acc := 0.0
					for o in [Vector2(-r, 0), Vector2(r, 0), Vector2(0, -r), Vector2(0, r), Vector2(-r, -r) * 0.7071, Vector2(r, r) * 0.7071, Vector2(-r, r) * 0.7071, Vector2(r, -r) * 0.7071]:
						acc += height_at.call(Vector2(wx, wz) + o)
					avg[i] = (acc + surface[i]) / 9.0
			if noise_src:
				noise[i] = noise_src.get_noise_2d(wx, wz)
	return {"surface": surface, "avg": avg, "noise": noise}

## The kernel. Modifies value/coverage in place over a rect of the layer.
static func apply_buffers(kind: int, rect: Rect2i, world: Rect2, grid: int, opacity: float,
		value: PackedFloat32Array, coverage: PackedFloat32Array, surface: PackedFloat32Array,
		avg: PackedFloat32Array, noise: PackedFloat32Array, stamps: PackedFloat32Array, luts: PackedFloat32Array) -> void:
	var px := world.size.x / float(grid)
	var count := stamps.size() / STAMP_STRIDE
	var is_height := kind == PaintKind.HEIGHT_DELTA or kind == PaintKind.HEIGHT_ABSOLUTE
	for y in rect.size.y:
		var wz := world.position.y + (rect.position.y + y + 0.5) * px
		for x in rect.size.x:
			var wx := world.position.x + (rect.position.x + x + 0.5) * px
			var i := y * rect.size.x + x
			var v := value[i]
			var v0 := v
			var c := coverage[i] if kind == PaintKind.HEIGHT_ABSOLUTE else 0.0
			for s in count:
				var b := s * STAMP_STRIDE
				var dx := wx - stamps[b + 1]
				var dz := wz - stamps[b + 2]
				var radius := stamps[b + 3]
				var dist := sqrt(dx * dx + dz * dz)
				if dist >= radius:
					continue
				var f := lut_sample(luts, int(stamps[b + 7]), 1.0 - dist / radius)
				var amount := stamps[b + 4] * f
				if amount == 0.0:
					continue
				var op := int(stamps[b])
				var target := stamps[b + 5]
				var erase := stamps[b + 6] > 0.5
				if is_height:
					var current := surface[i] + (v - v0) * opacity
					if kind == PaintKind.HEIGHT_ABSOLUTE:
						current = surface[i] if c <= 0.0 else lerpf(surface[i], v, c * opacity)
					match op:
						BrushStamp.StrokeOp.RAISE, BrushStamp.StrokeOp.LOWER:
							var sign := -1.0 if (op == BrushStamp.StrokeOp.LOWER) != erase else 1.0
							if kind == PaintKind.HEIGHT_ABSOLUTE:
								if c <= 0.0:
									v = surface[i]
								v += sign * amount
								c = minf(c + clampf(amount, 0.0, 1.0), 1.0)
							else:
								v += sign * amount
						BrushStamp.StrokeOp.FLATTEN, BrushStamp.StrokeOp.SET_VALUE:
							var k := clampf(amount, 0.0, 1.0)
							if kind == PaintKind.HEIGHT_ABSOLUTE:
								if erase:
									c = maxf(c - k, 0.0)
								else:
									v = target if c <= 0.0 else lerpf(v, target, k)
									c = minf(c + k, 1.0)
							elif op == BrushStamp.StrokeOp.SET_VALUE:
								v = lerpf(v, target, k)
							else:
								v += (target - current) * k / maxf(opacity, 0.0001)
						BrushStamp.StrokeOp.SMOOTH:
							var k2 := clampf(amount, 0.0, 1.0)
							if kind == PaintKind.HEIGHT_ABSOLUTE:
								if c > 0.0:
									v = lerpf(v, avg[i], k2)
							else:
								v += (avg[i] - current) * k2 / maxf(opacity, 0.0001)
						BrushStamp.StrokeOp.STAMP_NOISE:
							v += (-1.0 if erase else 1.0) * amount * noise[i]
						_:
							if kind == PaintKind.HEIGHT_ABSOLUTE:
								c = clampf(c + (-amount if erase else amount), 0.0, 1.0)
				else:
					match op:
						BrushStamp.StrokeOp.SET_VALUE:
							v = lerpf(v, target, clampf(amount, 0.0, 1.0))
						_:
							v = clampf(v + (-amount if erase or op == BrushStamp.StrokeOp.LOWER else amount), 0.0, 1.0)
			value[i] = v
			if kind == PaintKind.HEIGHT_ABSOLUTE:
				coverage[i] = c

## Apply stamps to a layer (CPU path). Returns the touched paint px rect (empty = nothing).
## [param height_at] (world XZ -> generator-local height) feeds FLATTEN / SMOOTH height ops.
static func apply_to_layer(layer, stamps: Array, world: Rect2, height_at: Callable = Callable()) -> Rect2i:
	var image: Image = layer.get_data()
	var grid: int = image.get_width()
	var rect := stamps_rect(stamps, world, grid)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return Rect2i()
	var bufs := read_buffers(image, layer.kind, rect)
	var avg_r := 2.0
	for s in stamps:
		avg_r = maxf(avg_r, s.radius * 0.2)
	var inputs := gather_inputs(rect, world, grid, stamps, height_at, avg_r)
	var packed := pack(stamps)
	var cov: PackedFloat32Array = bufs["coverage"]
	if cov.is_empty():
		cov.resize((bufs["value"] as PackedFloat32Array).size())
	apply_buffers(layer.kind, rect, world, grid, layer.opacity, bufs["value"], cov,
		inputs["surface"], inputs["avg"], inputs["noise"], packed["stamps"], packed["luts"])
	write_buffers(image, layer.kind, rect, bufs["value"], cov)
	layer.content_rect = rect if not layer.has_data() else layer.content_rect.merge(rect)
	return rect
