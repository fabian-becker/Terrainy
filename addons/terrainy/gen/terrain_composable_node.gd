@tool
@icon("res://addons/terrainy/icons/field.svg")
class_name TerrainComposableNode
extends Node3D

## Base class of every node that takes part in a [TerrainGenerator]'s composition tree
## (fields, heightmaps, groups, modifiers, holes, scatter).
##
## The scene tree IS the composition structure: siblings blend in tree order, and [member space]
## decides what a node reads/evaluates against (see the design doc §5.9):
## - Local: the direct parent unit's own output (nested sculpting: a child of a mountain
##   field shapes only that mountain).
## - Group: the nearest ancestor [TerrainFieldGroup]'s accumulated composite (the generator's
##   running composite at the root). Default.
## - Global: the whole-terrain composite, in a dedicated post-compose pass in scene order.

## Disabled nodes (and their subtree) are skipped by the composition.
@export var enabled: bool = true:
	set(value):
		enabled = value
		_commit()

## What this node reads / evaluates against.
@export var space: TerrainTypes.Space = TerrainTypes.Space.GROUP:
	set(value):
		space = value
		_commit()

## Bumped on every parameter change; joins the composition signature.
var revision: int = 0

var _generator_cache: WeakRef = null

func _init() -> void:
	set_notify_transform(true)

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_TRANSFORM_CHANGED:
			if is_inside_tree():
				_on_transform_changed()
		NOTIFICATION_ENTER_TREE, NOTIFICATION_EXIT_TREE, NOTIFICATION_PARENTED, NOTIFICATION_UNPARENTED:
			_generator_cache = null
		NOTIFICATION_VISIBILITY_CHANGED:
			_commit()

func _on_transform_changed() -> void:
	_commit()

## Record a parameter change and ask the owning generator for a (debounced) rebuild.
func _commit() -> void:
	revision += 1
	var generator := get_generator()
	if generator:
		generator.notify_node_changed(self)
	update_gizmos()

## Nearest [TerrainGenerator] ancestor, or null.
func get_generator() -> Node:
	if _generator_cache != null:
		var cached = _generator_cache.get_ref()
		if is_instance_valid(cached) and cached.is_ancestor_of(self):
			return cached
	var node := get_parent()
	while node != null:
		if node is TerrainGenerator:
			_generator_cache = weakref(node)
			return node
		node = node.get_parent()
	return null

## True when the node and every composable ancestor are enabled and visible.
func is_effectively_enabled() -> bool:
	if not enabled or not is_visible_in_tree():
		return false
	var node := get_parent()
	while node != null and not (node is TerrainGenerator):
		if node is TerrainComposableNode and not node.enabled:
			return false
		node = node.get_parent()
	return true

## Global transform, or the local one while outside the tree (snapshots of detached nodes).
func world_transform() -> Transform3D:
	return global_transform if is_inside_tree() else transform

## Plan unit kind, see composition_plan.gd. -1 = not a composition unit.
func get_unit_kind() -> int:
	return -1

## Connect a resource's changed signal to _commit (no duplicates).
func _track_resource(old: Resource, new: Resource) -> void:
	if old and old.changed.is_connected(_commit):
		old.changed.disconnect(_commit)
	if new and not new.changed.is_connected(_commit):
		new.changed.connect(_commit)

## World XZ rectangle this node can affect (used for dirty-chunk bookkeeping and gizmos).
func get_influence_bounds() -> Rect2:
	return Rect2()
