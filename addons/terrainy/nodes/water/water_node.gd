@tool
class_name WaterNode
extends PrimitiveNode

const WaterEvaluationContext = preload("res://addons/terrainy/nodes/water/water_evaluation_context.gd")
const WaterSettingsRes = preload("res://addons/terrainy/resources/water_settings.gd")

## A water body that carves terrain and renders a water surface.
## Creates depressions filled with water at a specified level.

signal water_mesh_updated

@export_group("Terrain Carving")
## Height of the water surface in world coordinates
@export var water_level: float = 0.0:
	set(value):
		water_level = value
		_commit_parameter_change()
		_update_water_mesh()

## How deep to carve below water_level
@export var carve_depth: float = 10.0:
	set(value):
		carve_depth = max(0.0, value)
		_commit_parameter_change()

## Shore gradient (0=sharp cliff, 1=gradual slope into water)
@export_range(0.0, 1.0) var shore_slope: float = 0.3:
	set(value):
		shore_slope = value
		_commit_parameter_change()

## How flat the lake bottom is (0=natural variation, 1=completely flat bottom)
@export_range(0.0, 1.0) var bottom_flatness: float = 0.5:
	set(value):
		bottom_flatness = value
		_commit_parameter_change()

@export_group("Water Surface")
## Generate a water surface mesh
@export var generate_water_mesh: bool = true:
	set(value):
		generate_water_mesh = value
		_update_water_mesh_visibility()

## Resolution of the water mesh grid
@export_range(8, 256, 8) var mesh_resolution: int = 64:
	set(value):
		mesh_resolution = value
		_update_water_mesh()

## Custom material for water (overrides default shader)
@export var water_material: Material:
	set(value):
		water_material = value
		_apply_water_material()

## Optional water settings resource for appearance (ignored if water_material is set)
@export var water_settings: WaterSettingsRes:
	set(value):
		if water_settings and water_settings.settings_changed.is_connected(_on_settings_changed):
			water_settings.settings_changed.disconnect(_on_settings_changed)
		water_settings = value
		if water_settings and not water_settings.settings_changed.is_connected(_on_settings_changed):
			water_settings.settings_changed.connect(_on_settings_changed)
		_apply_water_settings()

@export_group("Water Appearance")
## Color for shallow water areas
@export var water_color_shallow: Color = Color(0.2, 0.6, 0.8, 0.8):
	set(value):
		water_color_shallow = value
		_update_water_shader_params()

## Color for deep water areas
@export var water_color_deep: Color = Color(0.05, 0.2, 0.4, 0.95):
	set(value):
		water_color_deep = value
		_update_water_shader_params()

## Depth at which water color transitions to "deep"
@export var depth_max: float = 10.0:
	set(value):
		depth_max = max(0.1, value)
		_update_water_shader_params()

## Width of foam band at shoreline
@export var foam_width: float = 2.0:
	set(value):
		foam_width = max(0.0, value)
		_update_water_shader_params()

## Intensity of foam effect
@export_range(0.0, 1.0) var foam_intensity: float = 0.8:
	set(value):
		foam_intensity = value
		_update_water_shader_params()

## Speed of wave animation
@export var wave_speed: float = 1.0:
	set(value):
		wave_speed = value
		_update_water_shader_params()

## Height of wave displacement
@export var wave_height: float = 0.2:
	set(value):
		wave_height = value
		_update_water_shader_params()

## Frequency of waves
@export var wave_frequency: float = 2.0:
	set(value):
		wave_frequency = max(0.1, value)
		_update_water_shader_params()

## Strength of wave normals
@export_range(0.0, 2.0) var normal_strength: float = 0.5:
	set(value):
		normal_strength = value
		_update_water_shader_params()

## Wave normal texture (optional, procedural if not set)
@export var wave_normal_texture: Texture2D:
	set(value):
		wave_normal_texture = value
		_update_water_shader_params()

## Foam texture (optional, procedural if not set)
@export var foam_texture: Texture2D:
	set(value):
		foam_texture = value
		_update_water_shader_params()

var _water_mesh_instance: MeshInstance3D = null
var _water_shader_material: ShaderMaterial = null
var _is_building_mesh: bool = false
var _composer: Node = null

func _ready() -> void:
	super._ready()
	if not parameters_changed.is_connected(_on_feature_parameters_changed):
		parameters_changed.connect(_on_feature_parameters_changed)
	_connect_to_composer()
	_create_water_mesh_instance()
	_update_water_mesh()

func _exit_tree() -> void:
	_disconnect_from_composer()
	if parameters_changed.is_connected(_on_feature_parameters_changed):
		parameters_changed.disconnect(_on_feature_parameters_changed)
	if _water_mesh_instance and is_instance_valid(_water_mesh_instance):
		_water_mesh_instance.queue_free()
		_water_mesh_instance = null

func _enter_tree() -> void:
	# Tool scripts can reload while the scene remains open; reconnect and rebuild.
	_connect_to_composer()
	if is_inside_tree():
		call_deferred("_ensure_water_mesh")

func prepare_evaluation_context() -> WaterEvaluationContext:
	return WaterEvaluationContext.from_water_feature(self)

func get_height_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return get_height_at_safe(world_pos, ctx)

func get_height_at_safe(world_pos: Vector3, context: EvaluationContext) -> float:
	var ctx = context as WaterEvaluationContext
	var local_pos = ctx.to_local(world_pos)
	var normalized_dist = _get_normalized_distance(local_pos, ctx)
	if normalized_dist >= 1.0:
		return 0.0
	
	var influence_weight = ctx.get_influence_weight(world_pos)
	if influence_weight <= 0.0:
		return 0.0

	var shore_zone = ctx.shore_slope
	var depth: float
	
	if normalized_dist > (1.0 - shore_zone):
		var slope_t = (normalized_dist - (1.0 - shore_zone)) / shore_zone
		depth = lerp(-ctx.carve_depth * ctx.bottom_flatness, 0.0, slope_t)
	else:
		depth = -ctx.carve_depth * ctx.bottom_flatness
	
	return depth * influence_weight

func _get_normalized_distance(local_pos: Vector3, ctx: WaterEvaluationContext) -> float:
	match ctx.influence_shape:
		InfluenceShape.CIRCLE:
			return Vector2(local_pos.x, local_pos.z).length() / max(ctx.influence_radius, 0.0001)
		InfluenceShape.RECTANGLE:
			var half_x = max(ctx.influence_size.x * 0.5, 0.0001)
			var half_z = max(ctx.influence_size.y * 0.5, 0.0001)
			return max(abs(local_pos.x) / half_x, abs(local_pos.z) / half_z)
		InfluenceShape.ELLIPSE:
			var nx = local_pos.x / max(ctx.influence_size.x * 0.5, 0.0001)
			var nz = local_pos.z / max(ctx.influence_size.y * 0.5, 0.0001)
			return sqrt(nx * nx + nz * nz)
		_:
			return 2.0

func get_gpu_param_pack() -> Dictionary:
	var extra_floats := PackedFloat32Array([
		water_level,
		carve_depth,
		shore_slope,
		bottom_flatness
	])
	return _build_gpu_param_pack(FeatureType.WATER, extra_floats, PackedInt32Array())

func _create_water_mesh_instance() -> void:
	if not _water_mesh_instance:
		_water_mesh_instance = MeshInstance3D.new()
		_water_mesh_instance.name = "WaterMesh"
		_water_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_water_mesh_instance, false, Node.INTERNAL_MODE_BACK)
	
	_setup_default_material()

func _setup_default_material() -> void:
	if not _water_shader_material:
		var shader = preload("res://addons/terrainy/shaders/water_shader.gdshader")
		if shader:
			_water_shader_material = ShaderMaterial.new()
			_water_shader_material.shader = shader
			_update_water_shader_params()
	
	if _water_mesh_instance and _water_shader_material and not water_material:
		_water_mesh_instance.material_override = _water_shader_material

func _update_water_shader_params() -> void:
	if not _water_shader_material:
		return
	
	_water_shader_material.set_shader_parameter("water_color_shallow", water_color_shallow)
	_water_shader_material.set_shader_parameter("water_color_deep", water_color_deep)
	_water_shader_material.set_shader_parameter("depth_max", depth_max)
	_water_shader_material.set_shader_parameter("foam_width", foam_width)
	_water_shader_material.set_shader_parameter("foam_intensity", foam_intensity)
	_water_shader_material.set_shader_parameter("wave_speed", wave_speed)
	_water_shader_material.set_shader_parameter("wave_height", wave_height)
	_water_shader_material.set_shader_parameter("wave_frequency", wave_frequency)
	_water_shader_material.set_shader_parameter("water_level", water_level)
	_water_shader_material.set_shader_parameter("normal_strength", normal_strength)
	_water_shader_material.set_shader_parameter("use_wave_normal", wave_normal_texture != null)
	_water_shader_material.set_shader_parameter("use_foam_texture", foam_texture != null)
	_water_shader_material.set_shader_parameter("influence_shape", int(influence_shape))
	_water_shader_material.set_shader_parameter("influence_size", Vector2(influence_size.x, influence_size.y))
	
	if wave_normal_texture:
		_water_shader_material.set_shader_parameter("wave_normal", wave_normal_texture)
	if foam_texture:
		_water_shader_material.set_shader_parameter("foam_texture", foam_texture)

func _apply_water_material() -> void:
	if not _water_mesh_instance:
		return
	
	if water_material:
		_water_mesh_instance.material_override = water_material
	else:
		_setup_default_material()
		if _water_shader_material:
			_water_mesh_instance.material_override = _water_shader_material
			_update_water_shader_params()

func _apply_water_settings() -> void:
	if water_settings:
		water_color_shallow = water_settings.water_color_shallow
		water_color_deep = water_settings.water_color_deep
		depth_max = water_settings.depth_max
		foam_width = water_settings.foam_width
		foam_intensity = water_settings.foam_intensity
		wave_speed = water_settings.wave_speed
		wave_height = water_settings.wave_height
		wave_frequency = water_settings.wave_frequency
		
		if water_settings.custom_material:
			water_material = water_settings.custom_material
		
		_update_water_shader_params()

func _on_settings_changed() -> void:
	_apply_water_settings()

func _update_water_mesh_visibility() -> void:
	if _water_mesh_instance:
		_water_mesh_instance.visible = generate_water_mesh

func _update_water_mesh() -> void:
	if not generate_water_mesh:
		if _water_mesh_instance:
			_water_mesh_instance.visible = false
		return

	if not _water_mesh_instance or not is_instance_valid(_water_mesh_instance):
		_create_water_mesh_instance()
	
	if _is_building_mesh:
		return
	
	_is_building_mesh = true
	call_deferred("_build_water_mesh")

func _build_water_mesh() -> void:
	if not is_inside_tree() or not _water_mesh_instance or not is_instance_valid(_water_mesh_instance):
		_is_building_mesh = false
		return
	
	var size_x: float
	var size_z: float
	match influence_shape:
		InfluenceShape.CIRCLE:
			var diameter = max(influence_size.x, influence_size.y)
			size_x = diameter
			size_z = diameter
		InfluenceShape.ELLIPSE:
			size_x = influence_size.x
			size_z = influence_size.y
		_:
			size_x = influence_size.x
			size_z = influence_size.y
	
	var water_y = water_level - global_position.y
	
	var half_res_x = mesh_resolution / 2
	var half_res_z = mesh_resolution / 2
	var step_x = size_x / float(mesh_resolution)
	var step_z = size_z / float(mesh_resolution)
	
	var vertex_count = (mesh_resolution + 1) * (mesh_resolution + 1)
	var vertices = PackedVector3Array()
	vertices.resize(vertex_count)
	var uvs = PackedVector2Array()
	uvs.resize(vertex_count)
	var indices = PackedInt32Array()
	indices.resize(mesh_resolution * mesh_resolution * 6)
	
	var vert_idx = 0
	for z in range(mesh_resolution + 1):
		for x in range(mesh_resolution + 1):
			var local_x = (x - half_res_x) * step_x
			var local_z = (z - half_res_z) * step_z
			
			vertices[vert_idx] = Vector3(local_x, water_y, local_z)
			uvs[vert_idx] = Vector2(x / float(mesh_resolution), z / float(mesh_resolution))
			vert_idx += 1
	
	var idx = 0
	for z in range(mesh_resolution):
		for x in range(mesh_resolution):
			var i = z * (mesh_resolution + 1) + x
			var i_right = i + 1
			var i_down = i + mesh_resolution + 1
			var i_diag = i_down + 1
			
			indices[idx] = i
			indices[idx + 1] = i_right
			indices[idx + 2] = i_down
			
			indices[idx + 3] = i_right
			indices[idx + 4] = i_diag
			indices[idx + 5] = i_down
			idx += 6
	
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var array_mesh = ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	var surface_tool = SurfaceTool.new()
	surface_tool.create_from(array_mesh, 0)
	surface_tool.generate_normals()
	var mesh = surface_tool.commit()
	
	if mesh:
		_water_mesh_instance.mesh = mesh
	
	_is_building_mesh = false
	_water_mesh_instance.visible = generate_water_mesh
	water_mesh_updated.emit()

func _ensure_water_mesh() -> void:
	if not is_inside_tree():
		return
	if not _water_mesh_instance or not is_instance_valid(_water_mesh_instance):
		_create_water_mesh_instance()
	if generate_water_mesh and (_water_mesh_instance.mesh == null or not _water_mesh_instance.visible):
		_update_water_mesh()

func _connect_to_composer() -> void:
	_disconnect_from_composer()
	var node: Node = get_parent()
	while node:
		if node.has_signal("terrain_updated"):
			_composer = node
			if not _composer.terrain_updated.is_connected(_on_composer_terrain_updated):
				_composer.terrain_updated.connect(_on_composer_terrain_updated)
			break
		node = node.get_parent()

func _disconnect_from_composer() -> void:
	if _composer and is_instance_valid(_composer):
		if _composer.terrain_updated.is_connected(_on_composer_terrain_updated):
			_composer.terrain_updated.disconnect(_on_composer_terrain_updated)
	_composer = null

func _on_composer_terrain_updated() -> void:
	_ensure_water_mesh()

func _on_feature_parameters_changed() -> void:
	_update_water_shader_params()
	_update_water_mesh()

func get_water_surface_bounds() -> AABB:
	var center = Vector3(global_position.x, water_level, global_position.z)
	var size: Vector3
	match influence_shape:
		InfluenceShape.CIRCLE:
			var diameter = max(influence_size.x, influence_size.y)
			size = Vector3(diameter, 0.1, diameter)
		InfluenceShape.ELLIPSE:
			size = Vector3(influence_size.x, 0.1, influence_size.y)
		_:
			size = Vector3(influence_size.x, 0.1, influence_size.y)
	return AABB(center - size * 0.5, size)

func get_carved_depth_at(world_pos: Vector3) -> float:
	var ctx = prepare_evaluation_context()
	return abs(get_height_at_safe(world_pos, ctx))