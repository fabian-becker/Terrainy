extends "res://addons/terrainy/tests/framework/test_case.gd"

## CPU <-> GPU parity (tested contract; skips without a RenderingDevice, i.e. in headless CI).
## Run locally/nightly without --headless:
##     godot --path . --script res://addons/terrainy/tests/run_tests.gd -- --filter=gpu

const TerrainGrid = preload("res://addons/terrainy/gen/eval/terrain_grid.gd")
const Composer = preload("res://addons/terrainy/gen/eval/composer.gd")
const GpuCompositor = preload("res://addons/terrainy/gen/build/gpu/gpu_compositor.gd")
const GpuFieldEvaluator = preload("res://addons/terrainy/gen/build/gpu/gpu_field_evaluator.gd")
const GpuPaint = preload("res://addons/terrainy/gen/build/gpu/gpu_paint.gd")
const PaintStamper = preload("res://addons/terrainy/gen/paint/paint_stamper.gd")
const CurveLut = preload("res://addons/terrainy/gen/eval/curve_lut.gd")

func _max_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var worst := 0.0
	for i in a.size():
		worst = maxf(worst, absf(a[i] - b[i]))
	return worst

func test_cpu_fallback_when_gpu_is_unavailable() -> void:
	# Always runs: GPU flags on must never break a build (silent CPU fallback).
	var gen := make_generator(64, 64.0, func(g: TerrainGenerator):
		g.use_gpu_composition = true
		g.use_gpu_feature_evaluation = true
		g.use_gpu_paint = true
		g.use_multithreading = false)
	var layer := TerrainPaintLayer.new()
	gen.add_child(layer)
	build(gen, [make_field(4.0, Vector2(20, 20))])
	t.check_almost_eq(h_at(gen, 0, 0), 4.0, "composed with GPU flags on")
	gen.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.RAISE, Vector3.ZERO, 4.0, 1.0)])
	t.check_almost_eq(h_at(gen, 0, 0), 5.0, "painted with GPU flags on", 0.01)

func test_blend_kernel_matches_cpu() -> void:
	if not has_rendering_device() or not GpuCompositor.is_available():
		t.skip(gpu_skip_reason())
		return
	for mode in 7:
		var target := HMap.new(Rect2i(0, 0, 40, 30))
		var src := HMap.new(Rect2i(10, 5, 25, 20))
		var weights := PackedFloat32Array()
		weights.resize(src.data.size())
		for i in target.data.size():
			target.data[i] = sin(i * 0.37) * 4.0
		for i in src.data.size():
			src.data[i] = cos(i * 0.21) * 6.0
			weights[i] = fmod(i * 0.013, 1.2)
		var cpu = target.duplicate_map()
		Composer.blend(cpu, src, weights, mode, 0.8)
		t.check(GpuCompositor.blend(target, src, weights, mode, 0.8), "GPU path taken (mode %d)" % mode)
		t.check(_max_diff(cpu.data, target.data) < 1e-4, "blend mode %d parity" % mode)

func test_field_kernel_matches_cpu() -> void:
	if not has_rendering_device() or not GpuFieldEvaluator.is_available():
		t.skip(gpu_skip_reason())
		return
	var grid := TerrainGrid.new(64, 64.0, Vector2.ZERO)
	var gpu := GpuFieldEvaluator.new()
	for shape in 3:
		var f := make_field(7.0, Vector2(40, 24), Vector3(3, 2, -4))
		f.region_shape = shape
		f.rotation.y = 0.6
		var p := Curve.new()
		p.add_point(Vector2(0, 0.2))
		p.add_point(Vector2(1, 1))
		f.profile = p
		var snap = f.make_snapshot({"grid": grid, "generator_xform": Transform3D.IDENTITY})
		var cpu: Dictionary = snap.evaluate(grid)
		var res: Dictionary = gpu.evaluate(snap, grid)
		t.check(not res.is_empty(), "GPU path taken (shape %d)" % shape)
		if not res.is_empty():
			# Compare the contribution h * w: at the rim the weight underflows differently in
			# float32 (GPU) and float64 (GDScript), and a height with zero weight is inert.
			var hd := 0.0
			for i in cpu["h"].data.size():
				hd = maxf(hd, absf(cpu["h"].data[i] * cpu["w"].data[i] - res["h"].data[i] * res["w"].data[i]))
			t.check(hd < 1e-3, "weighted height parity shape %d (max %.6f)" % [shape, hd])
			t.check(_max_diff(cpu["w"].data, res["w"].data) < 1e-3, "weight parity shape %d" % shape)
		f.free()

func test_noise_fields_stay_on_the_cpu() -> void:
	var f := make_field()
	f.relief_layers = [TerrainReliefSource.new()]
	var snap = f.make_snapshot({"grid": TerrainGrid.new(32, 32.0, Vector2.ZERO)})
	t.check(not snap.is_gpu_capable(), "relief (noise) is never evaluated by the kernel")
	f.free()

func test_paint_kernel_matches_cpu_for_all_ops() -> void:
	if not has_rendering_device() or not GpuPaint.is_available():
		t.skip(gpu_skip_reason())
		return
	var world := Rect2(-32, -32, 64, 64)
	var noise := FastNoiseLite.new()
	for kind in 5:
		for op in 8:
			var rect := Rect2i(20, 20, 24, 24)
			var n := rect.size.x * rect.size.y
			var value := PackedFloat32Array()
			var coverage := PackedFloat32Array()
			var surface := PackedFloat32Array()
			var avg := PackedFloat32Array()
			var nz := PackedFloat32Array()
			for i in n:
				value.append(0.3 + 0.2 * sin(i * 0.1) if kind > 1 else sin(i * 0.1))
				coverage.append(0.5 if kind == 1 and i % 3 != 0 else 0.0)
				surface.append(2.0 + cos(i * 0.05))
				avg.append(2.0)
				nz.append(noise.get_noise_1d(i))
			var s1 = stamp(op, Vector3(-4, 0, -2), 6.0, 0.7, 1.5, false)
			var s2 = stamp(op, Vector3(-1, 0, -3), 5.0, 0.4, 0.5, false)
			s2.erase = true
			var packed := PaintStamper.pack([s1, s2])
			var cv := value.duplicate()
			var cc := coverage.duplicate()
			PaintStamper.apply_buffers(kind, rect, world, 128, 0.8, cv, cc, surface, avg, nz, packed["stamps"], packed["luts"])
			var gv := value.duplicate()
			var gc := coverage.duplicate()
			t.check(GpuPaint.apply_buffers(kind, rect, world, 128, 0.8, gv, gc, surface, avg, nz, packed["stamps"], packed["luts"]), "GPU paint path taken")
			t.check(_max_diff(cv, gv) < 1e-4 and _max_diff(cc, gc) < 1e-4, "paint parity kind %d op %d" % [kind, op])

func test_control_kernel_matches_cpu() -> void:
	if not has_rendering_device() or not GpuPaint.is_available():
		t.skip(gpu_skip_reason())
		return
	var count := 500
	var claims_cpu: Array = []
	var claims_gpu: Array = []
	for j in 3:
		var c := PackedFloat32Array()
		for i in count:
			c.append(fmod(i * 0.01 * (j + 1), 0.3))
		claims_cpu.append(c)
		claims_gpu.append(c.duplicate())
	var paint := PackedFloat32Array()
	for i in count:
		paint.append(fmod(i * 0.007, 1.0))
	for i in count:
		var p := minf(paint[i], 1.0)
		if p <= 0.0:
			continue
		for j in 3:
			claims_cpu[j][i] *= 1.0 - p
		claims_cpu[1][i] += p
	t.check(GpuPaint.combine_claims(claims_gpu, paint, 1), "GPU control path taken")
	for j in 3:
		t.check(_max_diff(claims_cpu[j], claims_gpu[j]) < 1e-5, "control parity layer %d" % j)

func test_generator_gpu_pipeline_matches_cpu() -> void:
	if not has_rendering_device() or not GpuFieldEvaluator.is_available() or not GpuCompositor.is_available():
		t.skip(gpu_skip_reason())
		return
	var make := func(gpu: bool) -> TerrainGenerator:
		var g := make_generator()
		g.use_gpu_composition = gpu
		g.use_gpu_feature_evaluation = gpu
		g.use_gpu_paint = gpu
		g.use_multithreading = false
		var a := make_field(6.0, Vector2(30, 20), Vector3(-5, 1, 3))
		a.rotation.y = 0.4
		var b := make_field(3.0, Vector2(20, 20), Vector3(10, 0, -8))
		b.blend_mode = TerrainTypes.BlendMode.MAX
		var layer := TerrainPaintLayer.new()
		g.add_child(layer)
		build(g, [a, b])
		g.paint_stamps(layer, [stamp(BrushStamp.StrokeOp.RAISE, Vector3(2, 0, 2), 6.0, 1.0, 0.0, false)])
		return g
	var gpu_gen: TerrainGenerator = make.call(true)
	var cpu_gen: TerrainGenerator = make.call(false)
	t.check(gpu_gen.get_diagnostics()["stats"]["gpu_fields"] > 0, "GPU field kernels were used")
	t.check(_max_diff(gpu_gen.get_final_map().data, cpu_gen.get_final_map().data) < 1e-3, "GPU pipeline equals CPU pipeline")
