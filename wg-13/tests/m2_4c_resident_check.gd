extends SceneTree
# M2.4c step-2: FieldGpu macro-resident map ensure/has/evict.
func _init() -> void:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.initialize("res://shaders/field_height.glsl"):
		print("FAIL: init"); print("M2.4c resident RESULT: FAIL"); quit(1); return
	if not fc.has_method("macro_ensure_test") or not fc.has_method("macro_resident_count"):
		print("FAIL: hooks missing"); print("M2.4c resident RESULT: FAIL"); quit(1); return
	var c0: int = fc.macro_resident_count()
	fc.macro_ensure_test(0, 0, 177, 256.0, 8000.0)
	var c1: int = fc.macro_resident_count()
	fc.macro_ensure_test(0, 0, 177, 256.0, 8000.0)  # same region again
	var c2: int = fc.macro_resident_count()
	var ok := c0 == 0 and c1 == 1 and c2 == 1
	print("resident counts: ", c0, " ", c1, " ", c2)
	print("M2.4c resident RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
