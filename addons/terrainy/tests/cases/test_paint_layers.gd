extends "res://addons/terrainy/tests/framework/test_case.gd"

## Paint stack: kinds, ordering, determinism, revisions, dirty rects, resampling, bundle.

const PaintStamper = preload("res://addons/terrainy/gen/paint/paint_stamper.gd")
const PaintController = preload("res://addons/terrainy/gen/paint/paint_controller.gd")

func _gen_with_layer(kind: int, children: Array = []) -> Array:
	var gen := make_generator()
	var layer := TerrainPaintLayer.new()
	layer.name = "L"
	layer.kind = kind
	gen.add_child(layer)
	build(gen, children)
	return [gen, layer]

func test_raise_and_lower_on_delta_layer() -> void:
	var pair := _gen_with_layer(TerrainPaintLayer.PaintKind.HEIGHT_DELTA)
	var gen: TerrainGenerator = pair[0]
	var layer: TerrainPaintLayer = pair[1]
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.RAISE, Vector3(0, 0, 0), 6.0, 2.0)])
	t.check_almost_eq(h_at(gen, 0, 0), 2.0, "raised at the center", 0.1)
	t.check_almost_eq(h_at(gen, 15, 0), 0.0, "outside the brush")
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.LOWER, Vector3(0, 0, 0), 6.0, 2.0)])
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "lowered back", 0.1)

func test_strokes_survive_procedural_recomposition() -> void:
	var hill := make_field(5.0, Vector2(20, 20), Vector3(-20, 0, 0))
	var pair := _gen_with_layer(TerrainPaintLayer.PaintKind.HEIGHT_DELTA, [hill])
	var gen: TerrainGenerator = pair[0]
	var layer: TerrainPaintLayer = pair[1]
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.RAISE, Vector3(10, 0, 10), 5.0, 3.0)])
	var painted := h_at(gen, 10, 10)
	hill.position = Vector3(10, 0, 10)
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 10, 10), painted + 5.0, "stroke stays anchored in world XZ on top of the moved field", 0.15)
	hill.position = Vector3(-20, 0, 0)
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 10, 10), painted, "deterministic recomposition", 1e-4)

func test_flatten_brush_targets_height() -> void:
	var hill := make_field(10.0, Vector2(40, 40))
	hill.domain_falloff = null
	var pair := _gen_with_layer(TerrainPaintLayer.PaintKind.HEIGHT_DELTA, [hill])
	var gen: TerrainGenerator = pair[0]
	var layer: TerrainPaintLayer = pair[1]
	for i in 6:
		gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.FLATTEN, Vector3.ZERO, 6.0, 1.0, 4.0)])
	t.check_almost_eq(h_at(gen, 0, 0), 4.0, "flattened toward 4 m", 0.1)

func test_absolute_layer_pins_height() -> void:
	var base := TerrainFieldNode.new()
	base.domain_kind = TerrainTypes.DomainKind.GLOBAL
	base.profile_height = 8.0
	var pair := _gen_with_layer(TerrainPaintLayer.PaintKind.HEIGHT_ABSOLUTE, [base])
	var gen: TerrainGenerator = pair[0]
	var layer: TerrainPaintLayer = pair[1]
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.SET_VALUE, Vector3.ZERO, 6.0, 1.0, 2.0)])
	t.check_almost_eq(h_at(gen, 0, 0), 2.0, "pinned", 0.05)
	base.profile_height = 20.0
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 2.0, "absolute pin ignores the procedural change", 0.05)
	t.check_almost_eq(h_at(gen, 20, 20), 20.0, "uncovered area follows procedural")

func test_smooth_layer_softens() -> void:
	var cliff := make_field(10.0, Vector2(30, 30))
	cliff.region_shape = TerrainTypes.RegionShape.RECTANGLE
	cliff.domain_falloff = null
	var pair := _gen_with_layer(TerrainPaintLayer.PaintKind.SMOOTH, [cliff])
	var gen: TerrainGenerator = pair[0]
	var layer: TerrainPaintLayer = pair[1]
	var before := absf(h_at(gen, 14, 0) - h_at(gen, 15, 0))
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.SMOOTH, Vector3(15, 0, 0), 6.0, 1.0)])
	var after := absf(h_at(gen, 14, 0) - h_at(gen, 15, 0))
	t.check(after < before * 0.7, "smooth layer softens the cliff (%.2f -> %.2f)" % [before, after])

func test_layer_order_and_opacity() -> void:
	var gen := make_generator()
	var a := TerrainPaintLayer.new()
	a.name = "Abs"
	a.kind = TerrainPaintLayer.PaintKind.HEIGHT_ABSOLUTE
	var d := TerrainPaintLayer.new()
	d.name = "Delta"
	d.kind = TerrainPaintLayer.PaintKind.HEIGHT_DELTA
	gen.add_child(a)
	gen.add_child(d)
	build(gen)
	gen.paint_stamps(a, [stamp(BrushStamp.StrokeOp.SET_VALUE, Vector3.ZERO, 6.0, 1.0, 5.0)])
	gen.paint_stamps(d, [stamp(BrushStamp.StrokeOp.RAISE, Vector3.ZERO, 6.0, 1.0)])
	t.check_almost_eq(h_at(gen, 0, 0), 6.0, "delta after absolute adds on top", 0.05)
	gen.move_child(d, 0)
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 5.0, "absolute after delta pins", 0.05)
	a.opacity = 0.5
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 0, 0), 3.0, "half opacity pin: lerp(1, 5, 0.5)", 0.05)

func test_revision_joins_signature_and_stroke_dirties_only_its_chunks() -> void:
	var pair := _gen_with_layer(TerrainPaintLayer.PaintKind.HEIGHT_DELTA)
	var gen: TerrainGenerator = pair[0]
	var layer: TerrainPaintLayer = pair[1]
	var rev := layer.revision
	var regions: Array = []
	gen.terrain_region_updated.connect(func(aabb): regions.append(aabb))
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.RAISE, Vector3(-16, 0, -16), 4.0, 1.0)])
	settle(gen)
	t.check(layer.revision > rev, "stroke bumps the revision")
	t.check_eq(regions.size(), 1, "only the chunk under the stroke rebuilt")

func test_stamper_rect_and_content_rect() -> void:
	var pair := _gen_with_layer(TerrainPaintLayer.PaintKind.MASK)
	var gen: TerrainGenerator = pair[0]
	var layer: TerrainPaintLayer = pair[1]
	t.check(not layer.has_data(), "fresh layer is empty")
	var rect := gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.MASK, Vector3(10, 0, 10), 4.0, 1.0)])
	t.check(rect.size.x > 0 and rect.size.x <= 20, "stroke rect is brush sized (%s)" % rect)
	t.check(layer.has_data(), "content tracked")
	var computed := TerrainPaintLayer.compute_content_rect(layer.get_data())
	t.check(rect.encloses(computed), "content rect inside the stroke rect")
	var w := layer.get_content_world_rect()
	t.check(w.has_point(Vector2(10, 10)), "world content rect covers the stroke")

func test_undo_round_trip_via_rect_copy() -> void:
	var pair := _gen_with_layer(TerrainPaintLayer.PaintKind.HEIGHT_DELTA)
	var gen: TerrainGenerator = pair[0]
	var layer: TerrainPaintLayer = pair[1]
	var full := Rect2i(Vector2i.ZERO, layer.get_data().get_size())
	var before := layer.copy_rect(full)
	var content := layer.content_rect
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.RAISE, Vector3.ZERO, 6.0, 3.0)])
	t.check(h_at(gen, 0, 0) > 2.0, "painted")
	layer.paste_rect(before, Vector2i.ZERO, content)
	t.check_almost_eq(h_at(gen, 0, 0), 0.0, "undo restores the terrain")

func test_resample_on_terrain_size_change_keeps_world_anchoring() -> void:
	var pair := _gen_with_layer(TerrainPaintLayer.PaintKind.HEIGHT_DELTA)
	var gen: TerrainGenerator = pair[0]
	var layer: TerrainPaintLayer = pair[1]
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.RAISE, Vector3(8, 0, 8), 5.0, 2.0)])
	var painted := h_at(gen, 8, 8)
	gen.terrain_size = 128.0
	gen.terrain_resolution = 128
	gen.rebuild_now()
	t.check_almost_eq(h_at(gen, 8, 8), painted, "stroke stays at its world position", 0.25)
	t.check_almost_eq(h_at(gen, 40, 40), 0.0, "new area empty")

## Godot writes exported resource paths as `uid://` strings, and `take_over_path()` can leave
## `resource_path` holding one too. A UID is not a filesystem path: opening `uid://x.tmp` fails
## with ERR_FILE_CANT_OPEN, which made every editor scene save report "could not save paint
## bundle (error 12)". The resolver must turn it back into a real path.
func test_bundle_path_may_be_a_uid() -> void:
	var sidecar := "res://addons/terrainy/demo/terrainy_demo_terrainy.tpaint.uid"
	if not FileAccess.file_exists(sidecar):
		t.skip("demo bundle has no .uid sidecar")
		return
	var uid_text := FileAccess.get_file_as_string(sidecar).strip_edges()
	t.check(uid_text.begins_with("uid://"), "sidecar holds a uid")
	var gen := TerrainGenerator.new()
	gen.paint_bundle_path = uid_text
	t.check_eq(gen.resolve_paint_bundle_path(),
		"res://addons/terrainy/demo/terrainy_demo_terrainy.tpaint",
		"uid resolves to the real bundle path")
	gen.paint_bundle_path = "user://plain.tpaint"
	t.check_eq(gen.resolve_paint_bundle_path(), "user://plain.tpaint", "plain paths pass through")
	t.check_eq(PaintController.resolved_path("uid://doesnotexist"), "",
		"unknown uid falls through to the next candidate")
	gen.free()

func test_bundle_round_trip() -> void:
	var path := "user://terrainy_test_bundle.tpaint"
	var pair := _gen_with_layer(TerrainPaintLayer.PaintKind.HEIGHT_DELTA)
	var gen: TerrainGenerator = pair[0]
	var layer: TerrainPaintLayer = pair[1]
	gen.paint_bundle_path = path
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.RAISE, Vector3(4, 0, -4), 5.0, 2.5)])
	var painted := h_at(gen, 4, -4)
	t.check_eq(gen.save_paint(), OK, "bundle saved")
	t.check(FileAccess.file_exists(path), "bundle file exists")
	t.check(not FileAccess.file_exists(path + ".tmp"), "no temp file left behind")
	var bundle := TerrainPaintBundle.load_from_file(path)
	t.check(bundle != null and bundle.get_section(gen.paint_section).has(layer.layer_uid), "section + layer stored")
	# A second generator sharing the bundle keeps its own section.
	var other := make_generator()
	other.paint_bundle_path = path
	var ol := TerrainPaintLayer.new()
	ol.kind = TerrainPaintLayer.PaintKind.MASK
	other.add_child(ol)
	build(other)
	other.paint_stamps(ol, [stamp(BrushStamp.StrokeOp.MASK, Vector3.ZERO, 3.0, 1.0)])
	other.save_paint()
	bundle = TerrainPaintBundle.load_from_file(path)
	t.check_eq(bundle.sections.size(), 2, "both generators' sections in one file")
	# Reload into a fresh generator with the same section / layer uid.
	var copy := make_generator()
	copy.paint_bundle_path = path
	copy.paint_section = gen.paint_section
	var cl := TerrainPaintLayer.new()
	cl.layer_uid = layer.layer_uid
	cl.kind = TerrainPaintLayer.PaintKind.HEIGHT_DELTA
	copy.add_child(cl)
	copy.position = Vector3(500, 0, 0)
	spawn(copy)
	copy.position = Vector3.ZERO
	copy.rebuild_now()
	t.check_almost_eq(h_at(copy, 4, -4), painted, "reloaded paint recomposes identically", 1e-4)
	# Loading stored data must not look like an edit: otherwise merely opening a scene bumps
	# every layer's revision and rewrites the bundle on exit.
	t.check_eq(cl.revision, layer.revision, "loading keeps the stored revision")
	# The registered format is what makes a `.tpaint` a resource the exporter follows, so the
	# scene can hold it as a dependency instead of an unshippable path string.
	t.check(ResourceLoader.exists(path), "ResourceLoader recognises .tpaint")
	var loaded = ResourceLoader.load(path)
	t.check(loaded is TerrainPaintBundle, "ResourceLoader loads .tpaint as a TerrainPaintBundle")
	if loaded is TerrainPaintBundle:
		t.check(loaded.get_section(gen.paint_section).has(layer.layer_uid), "loaded bundle carries the section")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_cpu_stamp_kernel_is_order_dependent_and_bounded() -> void:
	var image := Image.create(32, 32, false, Image.FORMAT_R8)
	var layer := TerrainPaintLayer.new()
	layer.kind = TerrainPaintLayer.PaintKind.TEXTURE
	layer.set_data(image)
	var world := Rect2(-16, -16, 32, 32)
	var rect := PaintStamper.apply_to_layer(layer, [stamp(BrushStamp.StrokeOp.TEXTURE, Vector3.ZERO, 4.0, 3.0)], world)
	var data := layer.get_float_data()
	var mx := 0.0
	for v in data:
		mx = maxf(mx, v)
	t.check(mx <= 1.0, "weight kinds stay in 0..1")
	t.check(rect.size.x > 0, "touched rect")
	layer.free()

func test_bundle_rejects_corrupt_headers() -> void:
	var bytes := TerrainPaintBundle.new().to_bytes()
	t.check(TerrainPaintBundle.from_bytes(bytes) != null, "clean bundle parses")
	var wrong_version := bytes.duplicate()
	wrong_version.encode_u32(4, TerrainPaintBundle.VERSION + 1)
	t.check(TerrainPaintBundle.from_bytes(wrong_version) == null, "unknown version rejected")
	var huge := bytes.duplicate()
	huge.encode_u32(8, 0xFFFFFFF0)
	t.check(TerrainPaintBundle.from_bytes(huge) == null, "oversized payload rejected")
