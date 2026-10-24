extends "res://addons/terrainy/tests/framework/test_case.gd"

## Editor tooling that can run headless: brush tool (raycast, stroke spacing, layer
## resolution), gallery node factory and configuration snapshots.

const BrushTool = preload("res://addons/terrainy/editor/brush/brush_tool.gd")
const GalleryDock = preload("res://addons/terrainy/editor/panel/gallery_dock.gd")

func _camera_over(gen: TerrainGenerator, pos: Vector3) -> Camera3D:
	var cam := Camera3D.new()
	gen.add_child(cam)
	cam.global_position = pos + Vector3(0, 40, 0.001)
	cam.look_at(pos, Vector3.FORWARD)
	return cam

func _center_click(cam: Camera3D, pressed: bool) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = cam.get_viewport().get_visible_rect().size * 0.5
	return e

func _plane_value(gen: TerrainGenerator, index: int, x: float, z: float) -> float:
	var img: Image = gen.get_weight_planes()["claims"][index]
	var w := gen.get_terrain_world_rect()
	var s := img.get_size()
	var px := Vector2i(
		clampi(int((x - w.position.x) / w.size.x * s.x), 0, s.x - 1),
		clampi(int((z - w.position.y) / w.size.y * s.y), 0, s.y - 1))
	return img.get_pixelv(px).r

func test_brush_raycast_hits_composed_surface() -> void:
	var f := make_field(6.0, Vector2(40, 40))
	f.domain_falloff = null
	var gen := build(make_generator(), [f])
	var cam := _camera_over(gen, Vector3.ZERO)
	var brush := BrushTool.new()
	brush.generator = gen
	brush.op = BrushStamp.StrokeOp.RAISE
	var hit := brush.raycast(cam, cam.get_viewport().get_visible_rect().size * 0.5)
	t.check(hit != Vector3.INF, "ray hits the terrain")
	t.check_almost_eq(hit.y, 6.0, "at the composed height", 0.05)

func test_brush_stroke_creates_a_sculpt_layer_and_paints() -> void:
	var gen := build(make_generator())
	var cam := _camera_over(gen, Vector3.ZERO)
	var brush := BrushTool.new()
	brush.generator = gen
	brush.op = BrushStamp.StrokeOp.RAISE
	brush.radius = 6.0
	brush.strength = 1.0
	brush.height_scale = 2.0
	t.check(brush.handle_input(cam, _center_click(cam, true)), "press consumed")
	t.check(brush.handle_input(cam, _center_click(cam, false)), "release consumed")
	var layers := gen.get_paint_layers()
	t.check_eq(layers.size(), 1, "a Sculpt layer was created")
	if layers.size() == 1:
		t.check_eq(int(layers[0].kind), TerrainPaintLayer.PaintKind.HEIGHT_DELTA, "height delta layer")
	t.check(h_at(gen, 0, 0) > 1.5, "stroke raised the terrain (%.2f)" % h_at(gen, 0, 0))

func test_texture_brush_targets_the_palette_layer() -> void:
	var gen := build(make_generator(64, 64.0, func(g: TerrainGenerator): g.texture_layers = [TerrainyTextureLayer.new(), TerrainyTextureLayer.new()]))
	var cam := _camera_over(gen, Vector3.ZERO)
	var brush := BrushTool.new()
	brush.generator = gen
	brush.op = BrushStamp.StrokeOp.TEXTURE
	brush.texture_index = 1
	brush.strength = 1.0
	brush.handle_input(cam, _center_click(cam, true))
	brush.handle_input(cam, _center_click(cam, false))
	var layer: TerrainPaintLayer = gen.get_paint_layers()[0]
	t.check_eq(int(layer.kind), TerrainPaintLayer.PaintKind.TEXTURE, "texture layer created")
	t.check_eq(layer.texture_layer_index, 1, "targets palette layer 1")
	t.check(TerrainyAPI.get_texture_blend_at(gen, Vector3.ZERO)[1] > 0.9, "painted surface reported by the API")

func test_texture_erase_toggle_removes_paint() -> void:
	var gen := build(make_generator(64, 64.0, func(g: TerrainGenerator): g.texture_layers = [TerrainyTextureLayer.new(), TerrainyTextureLayer.new()]))
	var cam := _camera_over(gen, Vector3.ZERO)
	var brush := BrushTool.new()
	brush.generator = gen
	brush.op = BrushStamp.StrokeOp.TEXTURE
	brush.texture_index = 0
	brush.radius = 6.0
	brush.strength = 1.0
	brush.handle_input(cam, _center_click(cam, true))
	brush.handle_input(cam, _center_click(cam, false))
	t.check(_plane_value(gen, 0, 0, 0) > 0.9, "painted")
	brush.texture_erase = true
	brush.handle_input(cam, _center_click(cam, true))
	brush.handle_input(cam, _center_click(cam, false))
	t.check(_plane_value(gen, 0, 0, 0) < 0.1, "Erase toggle removed the paint weight")

func test_texture_erase_toggle_does_not_affect_other_ops() -> void:
	var gen := build(make_generator())
	var cam := _camera_over(gen, Vector3.ZERO)
	var brush := BrushTool.new()
	brush.generator = gen
	brush.op = BrushStamp.StrokeOp.RAISE
	brush.texture_erase = true
	brush.radius = 6.0
	brush.strength = 1.0
	brush.height_scale = 2.0
	brush.handle_input(cam, _center_click(cam, true))
	brush.handle_input(cam, _center_click(cam, false))
	t.check(h_at(gen, 0, 0) > 1.5, "Raise still raises while the Texture Erase toggle is on")

func test_bracket_keys_resize_the_brush() -> void:
	var gen := build(make_generator())
	var brush := BrushTool.new()
	brush.generator = gen
	brush.op = BrushStamp.StrokeOp.RAISE
	var r := brush.radius
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_BRACKETRIGHT
	brush.handle_input(null, key)
	t.check(brush.radius > r, "] grows the radius")

func test_gallery_creates_every_node_kind() -> void:
	var dock := GalleryDock.new()
	for entry in dock._entries():
		var node := GalleryDock.create_node(entry[1])
		t.check(node != null, "gallery creates %s" % entry[0])
		if node:
			node.free()
	dock.free()

func test_config_snapshot_round_trip() -> void:
	var f := make_field(9.0, Vector2(24, 24), Vector3(30, 0, 0))
	f.name = "TestPlateau"
	var smooth := TerrainSmoothModifier.new()
	smooth.name = "Smooth"
	f.add_child(smooth)
	var gen := build(make_generator(), [f])
	t.check_eq(GalleryDock.save_config(f, "zz_test_plateau"), OK, "configuration saved")
	var path := GalleryDock.CONFIG_DIR + "/zz_test_plateau.tscn"
	var packed: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	t.check(packed != null, "snapshot loads")
	if packed:
		var copy := packed.instantiate()
		t.check(copy is TerrainFieldNode, "root type kept")
		t.check_almost_eq(copy.profile_height, 9.0, "parameters kept")
		t.check((copy as Node3D).position == Vector3.ZERO, "snapshot is position independent")
		t.check(copy.get_node_or_null("Smooth") is TerrainSmoothModifier, "children kept")
		copy.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if DirAccess.get_files_at(GalleryDock.CONFIG_DIR).is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GalleryDock.CONFIG_DIR))
	gen.queue_free()
