@tool
extends RefCounted

## Stage 1: scans a generator subtree into a [CompositionPlan] (main thread only).
##
## The scene tree is the composition structure. Plain Node3D containers are transparent;
## disabled/hidden composable nodes drop out with their subtree; INDEPENDENT groups are skipped
## unless they are the preview-isolated node; Global-space units go to the post pass.

const CompositionPlan = preload("res://addons/terrainy/gen/eval/composition_plan.gd")
const Signature = preload("res://addons/terrainy/gen/eval/signature.gd")

## [param context]: grid, generator, generator_xform, noise_seed, palette (Array, appended to
## for contribution-owned layers), owned_layers (Array of indices, appended), isolate (Node),
## paint_nodes (the generator's paint layers, skipped here) and paint_snapshots (their ready
## snapshots, in scene order). Paint arrives pre-snapshotted because this layer must not know the
## paint node type -- the generator owns paint and hands over plain data.
static func build(generator: Node, context: Dictionary) -> RefCounted:
	var plan := CompositionPlan.new()
	plan.paint_layers = context.get("paint_snapshots", [])
	var isolate: Node = context.get("isolate")
	if isolate != null and is_instance_valid(isolate) and generator.is_ancestor_of(isolate) and isolate is TerrainComposableNode:
		var unit = _make_unit(isolate, context, plan, true)
		if unit != null:
			unit.space = TerrainTypes.Space.GROUP
			plan.root.children.append(unit)
	else:
		plan.root.children = _build_children(generator, context, plan)
	var parts := PackedStringArray()
	for unit in plan.root.children:
		parts.append(unit.signature)
	parts.append("#post")
	for unit in plan.post:
		parts.append(unit.signature)
	plan.signature = "|".join(parts)
	return plan

static func _build_children(node: Node, context: Dictionary, plan) -> Array:
	var result: Array = []
	var paint_nodes: Array = context.get("paint_nodes", [])
	for child in node.get_children():
		if child in paint_nodes:
			continue
		if child is TerrainComposableNode:
			var unit = _make_unit(child, context, plan, false)
			if unit == null:
				continue
			if unit.space == TerrainTypes.Space.GLOBAL:
				continue  # already registered in plan.post
			result.append(unit)
		elif child is Node3D and not (child is Path3D) and not (child is VisualInstance3D) and not (child is CollisionObject3D):
			# Organisational containers are transparent.
			if child.visible:
				result.append_array(_build_children(child, context, plan))
	return result

static func _make_unit(node: TerrainComposableNode, context: Dictionary, plan, forced: bool):
	if not node.enabled or not node.visible:
		return null
	var kind := node.get_unit_kind()
	match kind:
		CompositionPlan.UnitKind.HOLE:
			plan.holes.append(node.make_snapshot(context))
			plan.structure.append(node.get_instance_id())
			return null
		CompositionPlan.UnitKind.SCATTER, -1:
			return null
	if kind == CompositionPlan.UnitKind.GROUP and node.scope == TerrainTypes.Scope.INDEPENDENT and not forced:
		return null
	var unit := CompositionPlan.Unit.new()
	unit.kind = kind
	unit.node_id = node.get_instance_id()
	unit.node_name = node.name
	unit.space = node.space
	unit.bounds = node.get_influence_bounds()
	plan.structure.append(unit.node_id)
	plan.unit_count += 1
	var own_sig := ""
	match kind:
		CompositionPlan.UnitKind.FIELD:
			unit.snap = node.make_snapshot(context)
			unit.blend_mode = node.blend_mode
			unit.strength = node.strength
			own_sig = unit.snap.signature
			if node.mask:
				var mask_ctx := context.duplicate()
				mask_ctx["owner_xform"] = node.global_transform
				mask_ctx["owner_node"] = node
				unit.mask = node.mask.make_snapshot(mask_ctx)
				own_sig += "|mask:%s|%s" % [Signature.of_object(node.mask), unit.mask.signature]
			unit.contributions = _resolve_contributions(node, context)
			own_sig += "|c:%s" % str(unit.contributions)
		CompositionPlan.UnitKind.MODIFIER:
			unit.snap = node.make_snapshot(context)
			own_sig = unit.snap.signature
		CompositionPlan.UnitKind.GROUP:
			unit.blend_mode = node.blend_mode
			unit.strength = node.strength
			own_sig = "group|%d|%s" % [node.blend_mode, var_to_str(node.strength)]
	# Global units register before their descendants so the post pass keeps scene pre-order.
	if unit.space == TerrainTypes.Space.GLOBAL and not forced:
		plan.post.append(unit)
	if kind != CompositionPlan.UnitKind.MODIFIER:
		unit.children = _build_children(node, context, plan)
	var child_sigs := PackedStringArray()
	for child in unit.children:
		child_sigs.append(child.signature)
	unit.signature = "%d:%d:%d:%d:%s{%s}[%s]" % [unit.kind, unit.node_id, unit.space, unit.blend_mode,
		var_to_str(unit.strength), own_sig, ";".join(child_sigs)]
	return unit

static func _resolve_contributions(node: Node, context: Dictionary) -> Array:
	var result: Array = []
	if not ("surface_contributions" in node):
		return result
	var palette: Array = context.get("palette", [])
	var owned: Array = context.get("owned_layers", [])
	for contribution in node.surface_contributions:
		if contribution == null or not contribution.is_active():
			continue
		var index := palette.find(contribution.texture_layer)
		if index < 0:
			if palette.size() >= 32:
				push_warning("[terrainy] '%s': texture layer limit (32) reached, contribution skipped" % node.name)
				continue
			palette.append(contribution.texture_layer)
			index = palette.size() - 1
			owned.append(index)
		result.append({
			"layer": index, "mode": int(contribution.mode),
			"strength": contribution.strength, "gate": contribution.respect_layer_gate,
		})
	return result
