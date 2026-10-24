@tool
extends RefCounted

## Builds the per-chunk MultiMeshInstance3D of every TerrainScatterNode (main thread).

const MAX_CANDIDATES_PER_CHUNK := 400000

## Deterministic placement of [param scatter] inside [param chunk]: chunk-local transforms.
static func place(generator: Node, scatter: Node, chunk, grid, final_map, holes) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	if scatter.density <= 0.0 or final_map == null:
		return out
	var spacing: float = scatter.spacing()
	var b: Rect2 = chunk.world_bounds
	var cx0 := int(floor(b.position.x / spacing))
	var cz0 := int(floor(b.position.y / spacing))
	var cx1 := int(ceil(b.end.x / spacing))
	var cz1 := int(ceil(b.end.y / spacing))
	if (cx1 - cx0) * (cz1 - cz0) > MAX_CANDIDATES_PER_CHUNK:
		push_warning("[terrainy] '%s' density too high for one chunk; clamped" % scatter.name)
		return out
	var mask_snaps: Array = []
	var ctx := {"grid": grid, "generator": generator, "generator_xform": generator.global_transform,
		"owner_xform": scatter.global_transform, "owner_node": scatter}
	for m in scatter.masks:
		if m:
			mask_snaps.append(m.make_snapshot(ctx))
	var gy: float = generator.global_position.y
	var center := b.get_center()
	var seed_base := int(hash([generator.noise_seed, scatter.noise_seed]))
	var rng := RandomNumberGenerator.new()
	var inv2c: float = 1.0 / (2.0 * grid.cell)
	var far: Vector2 = grid.origin + Vector2(grid.size, grid.size)
	var last_x := b.end.x >= far.x - 0.0001
	var last_z := b.end.y >= far.y - 0.0001
	for cz in range(cz0, cz1):
		for cx in range(cx0, cx1):
			rng.seed = hash([seed_base, cx, cz])
			var wx := (cx + rng.randf()) * spacing
			var wz := (cz + rng.randf()) * spacing
			var keep_roll := rng.randf()
			var yaw := rng.randf() * TAU
			var scale := lerpf(scatter.scale_min, scatter.scale_max, rng.randf())
			# Half-open ownership so neighbouring chunks never place the same candidate twice
			# (the last chunk row/column also owns the terrain's far edge).
			if wx < b.position.x or wz < b.position.y:
				continue
			if wx >= b.end.x and not (last_x and wx <= b.end.x):
				continue
			if wz >= b.end.y and not (last_z and wz <= b.end.y):
				continue
			var g: Vector2 = grid.sample_of(Vector2(wx, wz))
			if g.x < 0.0 or g.y < 0.0 or g.x > grid.samples - 1 or g.y > grid.samples - 1:
				continue
			if holes != null and holes.sample_bilinear(g.x, g.y) >= 0.5:
				continue
			var h: float = final_map.sample_bilinear(g.x, g.y)
			var world_h := h + gy
			if world_h < scatter.elevation_min or world_h > scatter.elevation_max:
				continue
			var dx: float = (final_map.sample_bilinear(g.x + 1.0, g.y) - final_map.sample_bilinear(g.x - 1.0, g.y)) * inv2c
			var dz: float = (final_map.sample_bilinear(g.x, g.y + 1.0) - final_map.sample_bilinear(g.x, g.y - 1.0)) * inv2c
			var slope := rad_to_deg(atan(sqrt(dx * dx + dz * dz)))
			if slope < scatter.slope_min or slope > scatter.slope_max:
				continue
			var keep := 1.0
			for snap in mask_snaps:
				keep *= snap.value_at(wx, wz, h, slope)
				if keep <= 0.0:
					break
			if keep_roll >= keep:
				continue
			var basis := Basis(Vector3.UP, yaw if scatter.random_yaw else 0.0)
			if scatter.align_to_normal > 0.0:
				var n := Vector3(-dx, 1.0, -dz).normalized()
				var tilt := Quaternion(Vector3.UP, Vector3.UP.slerp(n, scatter.align_to_normal).normalized())
				basis = Basis(tilt) * basis
			basis = basis.scaled(Vector3.ONE * scale)
			out.append(Transform3D(basis, Vector3(wx - center.x, h + scatter.height_offset, wz - center.y)))
			if out.size() >= scatter.max_instances_per_chunk:
				return out
	return out

## Refresh the scatter instances of one chunk. [param only_id] >= 0 refreshes that scatter
## node only (removing its instances when it is not in [param scatters] any more).
static func refresh_chunk(generator: Node, chunk, scatters: Array, grid, final_map, holes, only_id: int = -1) -> void:
	var wanted := {}
	for s in scatters:
		wanted[s.get_instance_id()] = s
	for id in chunk.scatter.keys():
		if (only_id < 0 and not wanted.has(id)) or (only_id >= 0 and id == only_id and not wanted.has(id)):
			var old: Node = chunk.scatter[id]
			if is_instance_valid(old):
				old.queue_free()
			chunk.scatter.erase(id)
			chunk.scatter_transforms.erase(id)
	for id in wanted:
		if only_id >= 0 and id != only_id:
			continue
		var scatter = wanted[id]
		var transforms := place(generator, scatter, chunk, grid, final_map, holes)
		var mmi: MultiMeshInstance3D = chunk.scatter.get(id)
		if transforms.is_empty() or scatter.mesh == null:
			if mmi and is_instance_valid(mmi):
				mmi.queue_free()
			chunk.scatter.erase(id)
			chunk.scatter_transforms.erase(id)
			continue
		chunk.scatter_transforms[id] = transforms
		if mmi == null or not is_instance_valid(mmi):
			mmi = MultiMeshInstance3D.new()
			mmi.name = "Scatter_%d" % id
			chunk.root.add_child(mmi, false, Node.INTERNAL_MODE_BACK)
			chunk.scatter[id] = mmi
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = scatter.mesh
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
		mmi.multimesh = mm
		mmi.material_override = scatter.material_override
		mmi.cast_shadow = scatter.cast_shadows

## Every instance transform of a scatter node in generator-local space (tests, bake).
static func collect(generator: Node, scatter: Node) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var chunks = generator.get_chunk_manager()
	if chunks == null:
		return out
	for chunk in chunks.chunks.values():
		for xf in chunk.scatter_transforms.get(scatter.get_instance_id(), []):
			out.append(chunk.root.transform * xf)
	return out
