extends SceneTree
# M2.4c step-2 SPIKE gate: prove an R32F texture can be created on FieldGpu's local
# RenderingDevice, sampled with a linear sampler in a compute dispatch, and read back.
func _init() -> void:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.has_method("macro_roundtrip_probe"):
		print("FAIL: FieldCompute / macro_roundtrip_probe missing")
		print("M2.4c roundtrip RESULT: FAIL"); quit(1); return
	var got: PackedFloat32Array = fc.macro_roundtrip_probe()
	var want := [10.0, 20.0, 30.0, 40.0]
	var ok := got.size() == 4
	if ok:
		for i in range(4):
			if absf(got[i] - want[i]) > 0.01: ok = false
	if ok: print("PASS: texture round-trip exact at texel centers ", got)
	else: print("FAIL: round-trip mismatch got=", got, " want=", want)
	print("M2.4c roundtrip RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
