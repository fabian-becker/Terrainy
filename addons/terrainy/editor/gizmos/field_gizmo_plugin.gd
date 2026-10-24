@tool
extends EditorNode3DGizmoPlugin

## Domain + elevation gizmos (port of the 0.7 gizmo_handle system, generalized to the field
## model).
##
## TerrainFieldNode / TerrainHeightmapNode: footprint outline, full-weight (falloff) outline,
## live profile cross-section, handles for width / depth / height / falloff. Corridors draw
## their route and cross-section in 3D. TerrainFlattenModifier: footprint on its resolved target
## plane. TerrainHoleNode: volume outline. TerrainGenerator: the `base_height` datum plane.
##
## Gizmos are anchored at the field's resolved elevation, not at node-local y = 0:
## `TerrainFieldNode.elevation_anchor_world_y()` reports where `profile * profile_height` starts
## (on `base_height` for additive blends, the node level for target blends, the route for
## `Curve` corridors). Drawing at 0 left every gizmo buried under the terrain whenever the
## generator had a base height, which made the River (a `Curve` corridor) the only node whose
## gizmo appeared to be "3D aware".

const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")

enum Handle { SIZE_X, SIZE_Z, HEIGHT, FALLOFF, BASE_HEIGHT }

var undo_redo: EditorUndoRedoManager = null

func _init() -> void:
	create_material("domain", Color(0.55, 0.95, 0.6, 0.9))
	create_material("falloff", Color(0.55, 0.95, 0.6, 0.35))
	create_material("profile", Color(1.0, 0.85, 0.35, 0.95))
	create_material("hole", Color(1.0, 0.4, 0.4, 0.9))
	create_material("datum", Color(0.45, 0.7, 1.0, 0.7))
	create_handle_material("handles")

func _get_gizmo_name() -> String:
	return "terrainyField"

func _has_gizmo(node: Node3D) -> bool:
	return node is TerrainGenerator or node is TerrainFieldNode \
		or node is TerrainFlattenModifier or node is TerrainHoleNode

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d()
	if node is TerrainGenerator:
		_draw_generator(gizmo, node)
		return
	if node is TerrainHoleNode:
		_draw_hole(gizmo, node)
		return
	if node is TerrainFlattenModifier:
		_draw_flatten(gizmo, node)
		return
	var field := node as TerrainFieldNode
	match field.domain_kind:
		TerrainTypes.DomainKind.REGION:
			_draw_region(gizmo, field)
		TerrainTypes.DomainKind.CORRIDOR:
			_draw_corridor(gizmo, field)
		_:
			_draw_global(gizmo, field)

# --- Field domains --------------------------------------------------------------------------

func _draw_region(gizmo: EditorNode3DGizmo, field: TerrainFieldNode) -> void:
	var anchor: float = field.elevation_anchor_world_y()
	_draw_footprint(gizmo, field, field.region_shape, field.region_size, field.domain_falloff, anchor)
	var hx := field.region_size.x * 0.5
	var hz := field.region_size.y * 0.5
	if field.region_shape == TerrainTypes.RegionShape.CIRCLE:
		hx = maxf(field.region_size.x, field.region_size.y) * 0.5
		hz = hx
	var handles := PackedVector3Array([
		_place(field, Vector3(hx, 0, 0), anchor),
		_place(field, Vector3(0, 0, hz), anchor),
	])
	var ids := PackedInt32Array([Handle.SIZE_X, Handle.SIZE_Z])
	# Heightmaps take their elevation from the image, not from profile * profile_height, so a
	# cross-section/height handle there would be a dead control.
	if TerrainTypes.has_elevation(field.blend_mode) and not (field is TerrainHeightmapNode):
		_draw_profile(gizmo, field, anchor)
		handles.append(_place(field, Vector3.ZERO, anchor + field.profile_height))
		ids.append(Handle.HEIGHT)
	var inner := 1.0 - _full_weight_e(field.domain_falloff)
	handles.append(_place(field, Vector3(-hx * inner, 0, 0), anchor))
	ids.append(Handle.FALLOFF)
	gizmo.add_handles(handles, get_material("handles", gizmo), ids)

func _draw_global(gizmo: EditorNode3DGizmo, field: TerrainFieldNode) -> void:
	if not TerrainTypes.has_elevation(field.blend_mode) or field is TerrainHeightmapNode:
		return
	var anchor: float = field.elevation_anchor_world_y()
	var bottom := _place(field, Vector3.ZERO, anchor)
	var top := _place(field, Vector3.ZERO, anchor + field.profile_height)
	gizmo.add_lines(PackedVector3Array([bottom, top]), get_material("profile", gizmo))
	gizmo.add_handles(PackedVector3Array([top]), get_material("handles", gizmo),
		PackedInt32Array([Handle.HEIGHT]))

func _draw_corridor(gizmo: EditorNode3DGizmo, field: TerrainFieldNode) -> void:
	var path := field.get_domain_path_node()
	if path == null or path.curve == null or path.curve.point_count < 2:
		return
	var path_xf: Transform3D = path.global_transform if path.is_inside_tree() else path.transform
	var field_inv: Transform3D = field.global_transform.affine_inverse()
	var length := path.curve.get_baked_length()
	var steps := clampi(int(length / 2.0), 2, 512)
	var hw := field.domain_width * 0.5
	var has_meters: bool = TerrainTypes.has_elevation(field.blend_mode)
	var edge_a := PackedVector3Array()
	var edge_b := PackedVector3Array()
	var center := PackedVector3Array()
	for i in steps + 1:
		var along := float(i) / float(steps)
		var xf := path.curve.sample_baked_with_rotation(length * along, true)
		var mid: Vector3 = path_xf * xf.origin
		var side: Vector3 = (path_xf.basis * xf.basis.x).normalized()
		var anchor: float = field.elevation_anchor_world_y(along)
		var pa := mid + side * hw
		var pb := mid - side * hw
		pa.y = anchor + (field.sample_profile(0.0) * field.profile_height if has_meters else 0.0)
		pb.y = pa.y
		edge_a.append(field_inv * pa)
		edge_b.append(field_inv * pb)
		if has_meters:
			var pc := mid
			pc.y = anchor + field.sample_profile(1.0) * field.profile_height
			center.append(field_inv * pc)
	var edges := PackedVector3Array()
	for i in steps:
		edges.append_array([edge_a[i], edge_a[i + 1], edge_b[i], edge_b[i + 1]])
	gizmo.add_lines(edges, get_material("domain", gizmo))
	if has_meters:
		var bed := PackedVector3Array()
		for i in steps:
			bed.append_array([center[i], center[i + 1]])
		gizmo.add_lines(bed, get_material("profile", gizmo))
		var mid_world := _corridor_mid_world(field)
		if mid_world != Vector3.INF:
			var anchor: float = field.elevation_anchor_world_y(0.5)
			var handle_world := Vector3(mid_world.x, anchor + field.profile_height, mid_world.z)
			gizmo.add_handles(PackedVector3Array([field_inv * handle_world]),
				get_material("handles", gizmo), PackedInt32Array([Handle.HEIGHT]))

## Cross-section of a region field, from [param anchor] (the profile datum) upward.
func _draw_profile(gizmo: EditorNode3DGizmo, field: TerrainFieldNode, anchor: float) -> void:
	var hx := field.region_size.x * 0.5
	if field.region_shape == TerrainTypes.RegionShape.CIRCLE:
		hx = maxf(field.region_size.x, field.region_size.y) * 0.5
	var lines := PackedVector3Array()
	var steps := 32
	var prev := Vector3.ZERO
	for i in steps * 2 + 1:
		var x := -hx + 2.0 * hx * i / (steps * 2)
		var e := 1.0 - absf(x) / hx
		var h := anchor + field.sample_profile(e) * field.profile_height
		var p := _place(field, Vector3(x, 0, 0), h)
		if i > 0:
			lines.append(prev)
			lines.append(p)
		prev = p
	gizmo.add_lines(lines, get_material("profile", gizmo))

# --- Datum / target planes ------------------------------------------------------------------

func _draw_generator(gizmo: EditorNode3DGizmo, gen: TerrainGenerator) -> void:
	var half := Vector2(gen.terrain_size, gen.terrain_size) * 0.5
	var y := gen.base_height
	var ring := _outline(TerrainTypes.RegionShape.RECTANGLE, half, y)
	var diagonals := PackedVector3Array([
		Vector3(-half.x, y, -half.y), Vector3(half.x, y, half.y),
		Vector3(half.x, y, -half.y), Vector3(-half.x, y, half.y),
	])
	var lines := PackedVector3Array()
	lines.append_array(ring)
	lines.append_array(diagonals)
	gizmo.add_lines(lines, get_material("datum", gizmo))
	gizmo.add_handles(PackedVector3Array([Vector3(-half.x, y, -half.y)]),
		get_material("handles", gizmo), PackedInt32Array([Handle.BASE_HEIGHT]))

func _draw_flatten(gizmo: EditorNode3DGizmo, mod: TerrainFlattenModifier) -> void:
	var target_y: float = mod.resolve_target_world_y()
	_draw_footprint(gizmo, mod, mod.footprint_shape, mod.footprint_size, mod.falloff, target_y)
	var half := mod.footprint_size * 0.5
	# Two diagonals across the footprint make the target plane readable from above.
	gizmo.add_lines(PackedVector3Array([
		_place(mod, Vector3(-half.x, 0, -half.y), target_y),
		_place(mod, Vector3(half.x, 0, half.y), target_y),
		_place(mod, Vector3(half.x, 0, -half.y), target_y),
		_place(mod, Vector3(-half.x, 0, half.y), target_y),
	]), get_material("profile", gizmo))
	var handles := PackedVector3Array([
		_place(mod, Vector3(half.x, 0, 0), target_y),
		_place(mod, Vector3(0, 0, half.y), target_y),
	])
	var ids := PackedInt32Array([Handle.SIZE_X, Handle.SIZE_Z])
	if mod.target_mode != TerrainFlattenModifier.TargetMode.NODE_HEIGHT:
		handles.append(_place(mod, Vector3.ZERO, target_y))
		ids.append(Handle.HEIGHT)
	gizmo.add_handles(handles, get_material("handles", gizmo), ids)

func _draw_hole(gizmo: EditorNode3DGizmo, hole: TerrainHoleNode) -> void:
	var h := hole.size * 0.5
	var lines := PackedVector3Array()
	if hole.hole_shape == TerrainHoleNode.HoleShape.BOX:
		for y in [-h.y, h.y]:
			lines.append_array(_outline(2, Vector2(h.x, h.z), y))
		for c in [Vector2(-h.x, -h.z), Vector2(h.x, -h.z), Vector2(h.x, h.z), Vector2(-h.x, h.z)]:
			lines.append_array([Vector3(c.x, -h.y, c.y), Vector3(c.x, h.y, c.y)])
	else:
		var ys := [-h.y, 0.0, h.y] if hole.hole_shape == TerrainHoleNode.HoleShape.CYLINDER else [0.0]
		for y in ys:
			lines.append_array(_outline(1, Vector2(h.x, h.z), y))
	gizmo.add_lines(lines, get_material("hole", gizmo))

# --- Geometry helpers -----------------------------------------------------------------------

## Normalized coordinate where the falloff curve first reaches full weight.
func _full_weight_e(curve: Curve) -> float:
	if curve == null:
		return 0.0
	var lut := CurveLut.bake(curve)
	for i in lut.size():
		if lut[i] >= 0.99:
			return float(i) / float(lut.size() - 1)
	return 1.0

## Footprint ring in node-local XZ, at local y = 0.
func _outline_local(shape: int, half: Vector2, scale: float = 1.0) -> PackedVector3Array:
	var lines := PackedVector3Array()
	var hx := half.x * scale
	var hz := half.y * scale
	if shape == 2:
		var c := [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]
		for i in 4:
			lines.append(c[i])
			lines.append(c[(i + 1) % 4])
		return lines
	if shape == 0:
		var r := maxf(hx, hz)
		hx = r
		hz = r
	var steps := 48
	for i in steps:
		var a := TAU * i / steps
		var b := TAU * (i + 1) / steps
		lines.append(Vector3(cos(a) * hx, 0, sin(a) * hz))
		lines.append(Vector3(cos(b) * hx, 0, sin(b) * hz))
	return lines

## Footprint ring at a local Y (holes are true volumes in node space).
func _outline(shape: int, half: Vector2, y: float, scale: float = 1.0) -> PackedVector3Array:
	var ring := _outline_local(shape, half, scale)
	for i in ring.size():
		var p := ring[i]
		p.y = y
		ring[i] = p
	return ring

## Map a node-local XZ point to a world-height plane, back into node-local space. This keeps
## drawn geometry aligned with the evaluator, which treats elevation as a world-Y scalar.
func _place(node: Node3D, local: Vector3, world_y: float) -> Vector3:
	var xf := node.global_transform
	var w: Vector3 = xf * Vector3(local.x, 0.0, local.z)
	return xf.affine_inverse() * Vector3(w.x, world_y, w.z)

func _place_ring(node: Node3D, ring: PackedVector3Array, world_y: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in ring:
		out.append(_place(node, p, world_y))
	return out

func _draw_footprint(gizmo: EditorNode3DGizmo, node: Node3D, shape: int, size: Vector2,
		falloff: Curve, world_y: float) -> void:
	var half := size * 0.5
	gizmo.add_lines(_place_ring(node, _outline_local(shape, half), world_y), get_material("domain", gizmo))
	var inner := 1.0 - _full_weight_e(falloff)
	if inner < 0.999:
		gizmo.add_lines(_place_ring(node, _outline_local(shape, half, inner), world_y),
			get_material("falloff", gizmo))

func _corridor_mid_world(field: TerrainFieldNode) -> Vector3:
	var path := field.get_domain_path_node()
	if path == null or path.curve == null or path.curve.point_count < 2:
		return Vector3.INF
	var xf: Transform3D = path.global_transform if path.is_inside_tree() else path.transform
	return xf * path.curve.sample_baked(path.curve.get_baked_length() * 0.5)

## Closest point to the mouse ray on the vertical world line through [param point].
## Elevation is a world-Y quantity, so height handles drag along world up, not the node axis.
func _vertical_hit(camera: Camera3D, screen_pos: Vector2, point: Vector3) -> Vector3:
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var axis := Vector3.UP
	var w := origin - point
	var b := axis.dot(dir)
	var denom := 1.0 - b * b
	if absf(denom) < 1e-6:
		return Vector3.INF
	var t := (axis.dot(w) - b * dir.dot(w)) / denom
	return point + axis * t

# --- Handles --------------------------------------------------------------------------------

func _get_handle_name(_gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> String:
	match handle_id:
		Handle.SIZE_X:
			return "Width"
		Handle.SIZE_Z:
			return "Depth"
		Handle.HEIGHT:
			return "Height"
		Handle.FALLOFF:
			return "Falloff"
		Handle.BASE_HEIGHT:
			return "Base Height"
	return ""

func _get_handle_value(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> Variant:
	var node := gizmo.get_node_3d()
	if node is TerrainGenerator:
		return node.base_height
	if node is TerrainFlattenModifier:
		if handle_id == Handle.HEIGHT:
			return node.target_height
		return node.footprint_size
	var field := node as TerrainFieldNode
	match handle_id:
		Handle.HEIGHT:
			return field.profile_height
		Handle.FALLOFF:
			return field.domain_falloff.duplicate() if field.domain_falloff else null
	return field.region_size

func _set_handle(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool,
		camera: Camera3D, screen_pos: Vector2) -> void:
	var node := gizmo.get_node_3d()
	if node is TerrainGenerator:
		if handle_id != Handle.BASE_HEIGHT:
			return
		var point := Vector3(node.global_position.x,
			node.global_position.y + node.base_height, node.global_position.z)
		var hit := _vertical_hit(camera, screen_pos, point)
		if hit == Vector3.INF:
			return
		node.base_height = snappedf(hit.y - node.global_position.y, 0.01)
		return
	if node is TerrainFlattenModifier:
		_set_flatten_handle(node, handle_id, camera, screen_pos)
		return
	var field := node as TerrainFieldNode
	if handle_id == Handle.HEIGHT:
		var anchor: float = field.elevation_anchor_world_y(0.5)
		var point := Vector3(field.global_position.x, anchor, field.global_position.z)
		if field.domain_kind == TerrainTypes.DomainKind.CORRIDOR:
			var mid := _corridor_mid_world(field)
			if mid != Vector3.INF:
				point = Vector3(mid.x, anchor, mid.z)
		var hit := _vertical_hit(camera, screen_pos, point)
		if hit == Vector3.INF:
			return
		field.profile_height = snappedf(hit.y - anchor, 0.01)
		return
	var plane := Plane(Vector3.UP, Vector3(0.0, field.elevation_anchor_world_y(), 0.0))
	var hit = plane.intersects_ray(camera.project_ray_origin(screen_pos),
		camera.project_ray_normal(screen_pos))
	if hit == null:
		return
	var local: Vector3 = field.global_transform.affine_inverse() * hit
	match handle_id:
		Handle.SIZE_X, Handle.SIZE_Z:
			var size := field.region_size
			if field.region_shape == TerrainTypes.RegionShape.CIRCLE:
				var r := maxf(Vector2(local.x, local.z).length() * 2.0, 0.1)
				size = Vector2(r, r)
			elif handle_id == Handle.SIZE_X:
				size.x = maxf(absf(local.x) * 2.0, 0.1)
			else:
				size.y = maxf(absf(local.z) * 2.0, 0.1)
			field.region_size = size
		Handle.FALLOFF:
			var hx := field.region_size.x * 0.5
			if field.region_shape == TerrainTypes.RegionShape.CIRCLE:
				hx = maxf(field.region_size.x, field.region_size.y) * 0.5
			var band := clampf(1.0 - absf(local.x) / maxf(hx, 0.001), 0.0, 1.0)
			# Rebuild the default-shaped falloff with the dragged band width.
			var c := Curve.new()
			c.add_point(Vector2(0, 0), 0, 0)
			if band > 0.001:
				c.add_point(Vector2(band, 1), 0, 0)
			c.add_point(Vector2(1, 1), 0, 0)
			field.domain_falloff = c

func _set_flatten_handle(mod: TerrainFlattenModifier, handle_id: int,
		camera: Camera3D, screen_pos: Vector2) -> void:
	if handle_id == Handle.HEIGHT:
		var target_y: float = mod.resolve_target_world_y()
		var point := Vector3(mod.global_position.x, target_y, mod.global_position.z)
		var hit := _vertical_hit(camera, screen_pos, point)
		if hit == Vector3.INF:
			return
		match mod.target_mode:
			TerrainFlattenModifier.TargetMode.ABSOLUTE:
				mod.target_height = snappedf(hit.y, 0.01)
			TerrainFlattenModifier.TargetMode.OWNER_LEVEL:
				var owner_unit := mod.get_owner_unit()
				var owner_y: float = (owner_unit as Node3D).global_position.y if owner_unit is Node3D else mod.global_position.y
				mod.target_height = snappedf(hit.y - owner_y, 0.01)
		return
	var plane := Plane(Vector3.UP, Vector3(0.0, mod.resolve_target_world_y(), 0.0))
	var hit = plane.intersects_ray(camera.project_ray_origin(screen_pos),
		camera.project_ray_normal(screen_pos))
	if hit == null:
		return
	var local: Vector3 = mod.global_transform.affine_inverse() * hit
	var size: Vector2 = mod.footprint_size
	if handle_id == Handle.SIZE_X:
		size.x = maxf(absf(local.x) * 2.0, 0.1)
	else:
		size.y = maxf(absf(local.z) * 2.0, 0.1)
	mod.footprint_size = size

func _commit_handle(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool,
		restore: Variant, cancel: bool) -> void:
	var node := gizmo.get_node_3d()
	var prop := "region_size"
	if node is TerrainGenerator:
		prop = "base_height"
	elif node is TerrainFlattenModifier:
		prop = "target_height" if handle_id == Handle.HEIGHT else "footprint_size"
	elif handle_id == Handle.HEIGHT:
		prop = "profile_height"
	elif handle_id == Handle.FALLOFF:
		prop = "domain_falloff"
	if cancel:
		node.set(prop, restore)
		return
	if undo_redo == null:
		return
	undo_redo.create_action("terrainy: edit %s" % prop)
	undo_redo.add_do_property(node, prop, node.get(prop))
	undo_redo.add_undo_property(node, prop, restore)
	undo_redo.commit_action(false)
