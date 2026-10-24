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

## Relief: Array of Dictionary {noise, weight, offset, blend, scale, cos, sin, follow}
var relief: Array = []

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
	return not is_heightmap and domain_kind == TerrainTypes.DomainKind.REGION and relief.is_empty()

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
	var e_buf := PackedFloat32Array()
	var elev_buf := PackedFloat32Array()
	var count := rect.size.x * rect.size.y
	e_buf.resize(count)
	match domain_kind:
		TerrainTypes.DomainKind.GLOBAL:
			e_buf.fill(1.0)
		TerrainTypes.DomainKind.CORRIDOR:
			var raster := Raster.rasterize_polyline(polyline, half_width, grid, rect)
			var dist: PackedFloat32Array = raster["dist"]
			elev_buf = raster["elev"]
			var inv_hw := 1.0 / maxf(half_width, 0.0001)
			for i in count:
				var d := dist[i]
				e_buf[i] = 1.0 - d * inv_hw if d < half_width else 0.0
		_:
			_region_coordinates(grid, rect, e_buf)

	var hd := h_map.data
	var wd := w_map.data
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
	var has_relief := not relief.is_empty()
	var w := rect.size.x
	for y in rect.size.y:
		var gz: float = grid.origin.y + (rect.position.y + y) * grid.cell
		for x in w:
			var i := y * w + x
			var e := e_buf[i]
			if e <= 0.0:
				continue
			var weight := (CurveLut.sample(falloff_lut, e) if has_falloff else 1.0) * strength
			if weight <= 0.0:
				continue
			var gx: float = grid.origin.x + (rect.position.x + x) * grid.cell
			var p := CurveLut.sample(profile_lut, e)
			var s: float
			if is_heightmap:
				s = _heightmap_height(gx, gz)
			else:
				s = p * profile_height
			if has_relief:
				s = _apply_relief(s, p, gx, gz)
			var hv := base + s
			if use_curve_elev:
				hv += elev_buf[i]
			hd[i] = hv
			wd[i] = weight
	h_map.data = hd
	w_map.data = wd
	return {"h": h_map, "w": w_map}

func _region_coordinates(grid, rect: Rect2i, e_buf: PackedFloat32Array) -> void:
	var w := rect.size.x
	var b := inv_xform.basis
	var o := inv_xform.origin
	var y0 := xform.origin.y
	for y in rect.size.y:
		var gz: float = grid.origin.y + (rect.position.y + y) * grid.cell
		for x in w:
			var gx: float = grid.origin.x + (rect.position.x + x) * grid.cell
			var l := b * Vector3(gx, y0, gz) + o
			var d := Raster.shape_distance(shape, l.x, l.z, half)
			e_buf[y * w + x] = 1.0 - d if d < 1.0 else 0.0

func _apply_relief(s: float, p: float, gx: float, gz: float) -> float:
	var l := inv_xform * Vector3(gx, xform.origin.y, gz)
	for src in relief:
		var c: float = src["cos"]
		var sn: float = src["sin"]
		var sc: Vector2 = src["scale"]
		var u := (l.x * c - l.z * sn) / sc.x
		var v := (l.x * sn + l.z * c) / sc.y
		var noise: FastNoiseLite = src["noise"]
		var n: float = noise.get_noise_2d(u, v) * float(src["weight"]) + float(src["offset"])
		if src["follow"]:
			n *= p
		if int(src["blend"]) == 1:
			s *= 1.0 + n
		else:
			s += n
	return s

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
