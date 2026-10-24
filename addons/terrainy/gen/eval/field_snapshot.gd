@tool
extends RefCounted

## Immutable, worker-safe snapshot of a [TerrainFieldNode] or [TerrainHeightmapNode].
##
## [method evaluate] produces the unit's own height map `h` and its weight map `w` (domain
## falloff x strength) over the unit's bounds. Masks are applied later, at blend time, because
## slope/elevation masks read the map the unit is blended into.
##
##     height(wx, wz) = elevation_base + profile_offset + shape
##     shape          = profile(e) * profile_height, then each relief source:
##                      Add: shape += n   Multiply: shape *= 1 + n
##                      n = noise(local, rotated, scaled) * weight + offset (x profile(e) if follow)
##     weight         = falloff(e) * strength
##
## e is the normalized domain coordinate: 0 at the domain edge, 1 at its center / center line.

const Raster = preload("res://addons/terrainy/gen/eval/raster.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")
const HMap = preload("res://addons/terrainy/gen/eval/hmap.gd")

var is_heightmap: bool = false
var domain_kind: int = TerrainTypes.DomainKind.REGION
var shape: int = 0
var half: Vector2 = Vector2.ONE
var xform: Transform3D = Transform3D.IDENTITY
var inv_xform: Transform3D = Transform3D.IDENTITY
var bounds: Rect2 = Rect2()
var polyline: PackedVector3Array = PackedVector3Array()
var half_width: float = 4.0

var profile_lut: PackedFloat32Array = PackedFloat32Array()
var falloff_lut: PackedFloat32Array = PackedFloat32Array()
var has_falloff: bool = true
var profile_height: float = 10.0
var profile_offset: float = 0.0
var elevation_origin: int = TerrainTypes.ElevationOrigin.LOCAL
## Node height relative to the generator (Local elevation origin).
var node_rel_y: float = 0.0
## World height of the generator (World elevation origin).
var generator_y: float = 0.0
var strength: float = 1.0

## Relief stack, flattened out of the pixel loop by [method TerrainFieldNode.make_snapshot]:
## parallel arrays, one entry per layer, instead of one Dictionary per layer. The inner loop reads
## eight values per layer per sample; a Dictionary costs a String-keyed lookup for every one of them
## (268 M lookups for a full-grid two-layer field), while a packed index is a single load.
##
## The doubles stay doubles: [PackedFloat64Array], not [PackedFloat32Array]. Rounding cos/sin/scale
## to 32 bit here moves every composed height.
var relief_noise: Array[FastNoiseLite] = []
var relief_cos: PackedFloat64Array = PackedFloat64Array()
var relief_sin: PackedFloat64Array = PackedFloat64Array()
var relief_sx: PackedFloat64Array = PackedFloat64Array()
var relief_sy: PackedFloat64Array = PackedFloat64Array()
var relief_weight: PackedFloat64Array = PackedFloat64Array()
var relief_offset: PackedFloat64Array = PackedFloat64Array()
## 1 when the layer follows the profile, else 0.
var relief_follow: PackedByteArray = PackedByteArray()
## 1 when the layer multiplies, else 0.
var relief_mul: PackedByteArray = PackedByteArray()

# Heightmap source
var hm_data: PackedFloat32Array = PackedFloat32Array()
var hm_size: Vector2i = Vector2i.ZERO
var hm_region: Rect2 = Rect2(0, 0, 1, 1)
var hm_min: float = 0.0
var hm_max: float = 100.0
var hm_nearest: bool = false
var hm_meters: bool = false

var signature: String = ""

## True when the GPU field kernel reproduces this snapshot exactly (no noise, region domain).
func is_gpu_capable() -> bool:
	return not is_heightmap and domain_kind == TerrainTypes.DomainKind.REGION and relief_noise.is_empty()

func pixel_rect(grid) -> Rect2i:
	if domain_kind == TerrainTypes.DomainKind.GLOBAL:
		return grid.full_rect()
	return grid.rect_for_world(bounds, 1)

## Evaluate over the unit's pixel rect. Returns {"h": HMap, "w": HMap}.
func evaluate(grid) -> Dictionary:
	var rect := pixel_rect(grid)
	var h_map := HMap.new(rect)
	var w_map := HMap.new(rect)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return {"h": h_map, "w": w_map}
	evaluate_band(grid, rect, 0, rect.size.y, h_map.data, w_map.data)
	return {"h": h_map, "w": w_map}

## Corridor raster for one rectangle. Parallel bands each rasterize their own rows instead of
## sharing one: a segment only ever visits the pixels of its own bounding box, so the bands
## together do the same work the single-rect call does.
func corridor_raster(grid, rect: Rect2i) -> Dictionary:
	if domain_kind != TerrainTypes.DomainKind.CORRIDOR or rect.size.x <= 0 or rect.size.y <= 0:
		return {}
	return Raster.rasterize_polyline(polyline, half_width, grid, rect)

## Evaluate rows `[y0, y1)` of [param rect] into [param hd] / [param wd], which are laid out like
## the whole [param rect]. Bands write disjoint rows, so a caller can run several on the pool.
##
## The per-sample math is written out instead of going through [CurveLut.sample]: this is the
## innermost loop of the compose and a GDScript call per sample costs more than the noise lookup.
## A region domain computes its normalized coordinate `e` in the same pass and keeps the local
## point, so the relief stack never repeats the inverse transform.
func evaluate_band(grid, rect: Rect2i, y0: int, y1: int, hd: PackedFloat32Array,
		wd: PackedFloat32Array) -> void:
	var w := rect.size.x
	var rows := y1 - y0
	if rows <= 0 or w <= 0:
		return
	var band := Rect2i(rect.position + Vector2i(0, y0), Vector2i(w, rows))
	var count := w * rows
	# A region's `e` comes out of the pixel loop itself (it needs the same local point the relief
	# does); global and corridor domains still need the buffer -- one constant, one raster.
	var region_inline := domain_kind == TerrainTypes.DomainKind.REGION
	var e_buf := PackedFloat32Array()
	var elev_buf := PackedFloat32Array()
	if not region_inline:
		e_buf.resize(count)
	match domain_kind:
		TerrainTypes.DomainKind.GLOBAL:
			e_buf.fill(1.0)
		TerrainTypes.DomainKind.CORRIDOR:
			var raster := corridor_raster(grid, band)
			var dist: PackedFloat32Array = raster.get("dist", PackedFloat32Array())
			elev_buf = raster.get("elev", PackedFloat32Array())
			var inv_hw := 1.0 / maxf(half_width, 0.0001)
			for i in count:
				var d := dist[i]
				e_buf[i] = 1.0 - d * inv_hw if d < half_width else 0.0
		_:
			pass

	var base := profile_offset
	match elevation_origin:
		TerrainTypes.ElevationOrigin.WORLD:
			base += -generator_y
		TerrainTypes.ElevationOrigin.LOCAL:
			base += node_rel_y
		TerrainTypes.ElevationOrigin.CURVE:
			# Region/global domains have no curve: fall back to the node height.
			if domain_kind != TerrainTypes.DomainKind.CORRIDOR:
				base += node_rel_y
	var use_curve_elev := elevation_origin == TerrainTypes.ElevationOrigin.CURVE and domain_kind == TerrainTypes.DomainKind.CORRIDOR
	# Relief parameters come straight from the snapshot's parallel arrays; only the noise objects
	# need a per-band copy (see below).
	var src_count := relief_noise.size()
	var r_cos := relief_cos
	var r_sin := relief_sin
	var r_sx := relief_sx
	var r_sy := relief_sy
	var r_w := relief_weight
	var r_off := relief_offset
	var r_follow := relief_follow
	var r_mul := relief_mul
	var r_noise: Array[FastNoiseLite] = []
	if src_count > 0:
		for k in src_count:
			# A private clone per band: FastNoiseLite guards its own state with a mutex, so sharing
			# one instance across bands serializes every noise lookup and caps the whole pass.
			r_noise.append(relief_noise[k].duplicate() if relief_noise[k] != null else null)
	var fo_n := falloff_lut.size()
	var pr_n := profile_lut.size()
	var fo_last := fo_n - 1
	var pr_last := pr_n - 1
	var hd_base := y0 * w
	var cell: float = grid.cell
	var ox: float = grid.origin.x
	var bx: float = band.position.x
	var xform_y := xform.origin.y
	# Region-domain hoists. `e32` gives `e` exactly the float32 value the buffer used to hold --
	# the falloff/profile lerps must see the same rounded number or every height moves.
	var bmat := inv_xform.basis
	var ovec := inv_xform.origin
	var half_v := half
	var shape_i := shape
	var e32 := PackedFloat32Array()
	if region_inline:
		e32.resize(1)
	for y in rows:
		# Per-row world Z, recomputed from the absolute row (never accumulated down the rows): the
		# unbanded loop read `origin.y + (rect.position.y + y) * cell`, and this is that expression
		# with `band.position.y == rect.position.y + y0`. Seeding one value per band and adding
		# `cell` is not bit-equal to it for a non-exactly-representable cell, which would make a
		# sample's height depend on the band split -- i.e. on the machine's core count.
		var gz: float = grid.world_z(band.position.y + y)
		var bpos := y * w
		for x in w:
			var bi := bpos + x
			var gx: float = ox + (bx + x) * cell
			var l := Vector3.ZERO
			var e := 1.0
			if region_inline:
				l = bmat * Vector3(gx, xform_y, gz) + ovec
				var d := Raster.shape_distance(shape_i, l.x, l.z, half_v)
				e32[0] = 1.0 - d if d < 1.0 else 0.0
				e = e32[0]
			else:
				e = e_buf[bi]
			if e <= 0.0:
				continue
			# Inlined CurveLut.sample: same math, no per-sample GDScript call.
			var fw := 1.0
			if has_falloff:
				if fo_n == 1:
					fw = falloff_lut[0]
				elif fo_n > 1:
					var ff := clampf(e, 0.0, 1.0) * float(fo_last)
					var fi := int(ff)
					fw = falloff_lut[fo_last] if fi >= fo_last else lerpf(falloff_lut[fi], falloff_lut[fi + 1], ff - fi)
			var weight := fw * strength
			if weight <= 0.0:
				continue
			var p := 1.0
			if pr_n == 1:
				p = profile_lut[0]
			elif pr_n > 1:
				var pf := clampf(e, 0.0, 1.0) * float(pr_last)
				var pi := int(pf)
				p = profile_lut[pr_last] if pi >= pr_last else lerpf(profile_lut[pi], profile_lut[pi + 1], pf - pi)
			var s: float
			if is_heightmap:
				s = _heightmap_height(gx, gz)
			else:
				s = p * profile_height
			if src_count > 0:
				if not region_inline:
					l = inv_xform * Vector3(gx, xform_y, gz)
				for k in src_count:
					var u := (l.x * r_cos[k] - l.z * r_sin[k]) / r_sx[k]
					var v := (l.x * r_sin[k] + l.z * r_cos[k]) / r_sy[k]
					var n: float = r_noise[k].get_noise_2d(u, v) * r_w[k] + r_off[k]
					if r_follow[k] == 1:
						n *= p
					if r_mul[k] == 1:
						s *= 1.0 + n
					else:
						s += n
			var hv := base + s
			if use_curve_elev:
				hv += elev_buf[bi]
			hd[hd_base + bi] = hv
			wd[hd_base + bi] = weight

func _heightmap_height(gx: float, gz: float) -> float:
	if hm_size.x <= 0:
		return 0.0
	var u: float
	var v: float
	if domain_kind == TerrainTypes.DomainKind.GLOBAL:
		u = (gx - bounds.position.x) / maxf(bounds.size.x, 0.0001)
		v = (gz - bounds.position.y) / maxf(bounds.size.y, 0.0001)
	else:
		var l := inv_xform * Vector3(gx, xform.origin.y, gz)
		u = l.x / (half.x * 2.0) + 0.5
		v = l.z / (half.y * 2.0) + 0.5
	u = hm_region.position.x + clampf(u, 0.0, 1.0) * hm_region.size.x
	v = hm_region.position.y + clampf(v, 0.0, 1.0) * hm_region.size.y
	var fx := u * (hm_size.x - 1)
	var fy := v * (hm_size.y - 1)
	var raw: float
	if hm_nearest:
		var ix := clampi(int(round(fx)), 0, hm_size.x - 1)
		var iy := clampi(int(round(fy)), 0, hm_size.y - 1)
		raw = hm_data[iy * hm_size.x + ix]
	else:
		raw = Raster.sample_buffer(hm_data, hm_size, fx, fy)
	if hm_meters:
		return raw
	return lerpf(hm_min, hm_max, raw)

## Weight (falloff x strength, no mask) at one world position; used by queries.
func weight_at(wx: float, wz: float) -> float:
	var e := 0.0
	match domain_kind:
		TerrainTypes.DomainKind.GLOBAL:
			e = 1.0
		TerrainTypes.DomainKind.CORRIDOR:
			var n := Raster.polyline_nearest(polyline, wx, wz)
			e = 1.0 - n.x / maxf(half_width, 0.0001) if n.x < half_width else 0.0
		_:
			var l := inv_xform * Vector3(wx, xform.origin.y, wz)
			var d := Raster.shape_distance(shape, l.x, l.z, half)
			e = 1.0 - d if d < 1.0 else 0.0
	if e <= 0.0:
		return 0.0
	return (CurveLut.sample(falloff_lut, e) if has_falloff else 1.0) * strength
