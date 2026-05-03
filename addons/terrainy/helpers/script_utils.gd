class_name TerrainyScriptUtils
extends RefCounted

## Path-independent script identification utilities.

## Check if a node's script inherits from a target class_name.
static func is_script_type(node: Node, target_class: String) -> bool:
	if not node:
		return false
	var script = node.get_script()
	if not script:
		return false

	# Fast path: exact match
	if script.get_global_name() == target_class:
		return true

	# Slow path: walk inheritance
	var base = script.get_base_script()
	while base:
		if base.get_global_name() == target_class:
			return true
		base = base.get_base_script()

	return false


## Check if a node's script is exactly a target class.
static func is_exact_script(node: Node, target_class: String) -> bool:
	if not node:
		return false
	var script = node.get_script()
	if not script:
		return false
	return script.get_global_name() == target_class
