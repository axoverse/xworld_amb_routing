## Integration tests for scene export functionality
extends RefCounted

class_name TestSceneExport

const AxoGltfEx = preload("res://addons/xbase_plugin/axo_gltfex.gd")
const OUTPUT_DIR = "res://addons/xbase_plugin/tests/output/"

static func run_all() -> Dictionary:
	var results := {"passed": 0, "failed": 0, "errors": []}
	
	# Ensure output directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	
	_test_minimal_scene_export(results)
	_test_amb_hospital_export(results)
	_test_gltf_reimport(results)
	
	return results

static func _test_minimal_scene_export(results: Dictionary):
	var test_name = "Minimal scene export"
	var scene_path = "res://addons/xbase_plugin/tests/fixtures/minimal_thinglink_scene.tscn"
	
	if not ResourceLoader.exists(scene_path):
		results.errors.append("%s: Fixture scene not found" % test_name)
		results.failed += 1
		return
	
	var scene = load(scene_path)
	var instance = scene.instantiate()
	
	var passed = true
	
	# Verify root properties
	if instance.ThingInstanceLabel != "TestRoot":
		results.errors.append("%s: Wrong ThingInstanceLabel" % test_name)
		passed = false
	
	if instance.PhysicalType != "Building":
		results.errors.append("%s: Wrong PhysicalType" % test_name)
		passed = false
	
	# Export to GLTF
	var output_path = OUTPUT_DIR + "minimal_test.glb"
	var export_result = _export_scene(instance, output_path)
	
	if not export_result.success:
		results.errors.append("%s: Export failed - %s" % [test_name, export_result.error])
		passed = false
	else:
		print("  Exported minimal scene to: %s" % output_path)
	
	instance.queue_free()
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1

static func _test_amb_hospital_export(results: Dictionary):
	var test_name = "AMB_Hospital.tscn export"
	var scene_path = "res://amb/AMB_Hospital.tscn"
	
	if not ResourceLoader.exists(scene_path):
		results.errors.append("%s: Scene not found" % test_name)
		results.failed += 1
		return
	
	var scene = load(scene_path)
	var instance = scene.instantiate()
	
	var passed = true
	
	# Verify expected root properties
	if instance.get("ThingInstanceLabel") != "AMB_Hospital":
		results.errors.append("%s: Wrong ThingInstanceLabel, got '%s'" % [test_name, instance.get("ThingInstanceLabel")])
		passed = false
	
	if instance.get("PhysicalType") != "Site":
		results.errors.append("%s: Wrong PhysicalType, got '%s'" % [test_name, instance.get("PhysicalType")])
		passed = false
	
	if instance.get("AxoExport") != true:
		results.errors.append("%s: AxoExport should be true" % test_name)
		passed = false
	
	# Export to GLTF
	var output_path = OUTPUT_DIR + "AMB_Hospital_test.glb"
	var export_result = _export_scene(instance, output_path)
	
	if not export_result.success:
		results.errors.append("%s: Export failed - %s" % [test_name, export_result.error])
		passed = false
	else:
		print("  Exported AMB_Hospital to: %s (%d bytes)" % [output_path, export_result.size])
	
	instance.queue_free()
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1

static func _test_gltf_reimport(results: Dictionary):
	var test_name = "GLTF reimport validation"
	var gltf_path = OUTPUT_DIR + "minimal_test.glb"
	
	if not FileAccess.file_exists(gltf_path):
		results.errors.append("%s: GLTF file not found (run export test first)" % test_name)
		results.failed += 1
		return
	
	var passed = true
	
	# Try to reimport the GLTF
	var gltf_doc = GLTFDocument.new()
	var gltf_state = GLTFState.new()
	
	var import_error = gltf_doc.append_from_file(gltf_path, gltf_state)
	
	if import_error != OK:
		results.errors.append("%s: Failed to reimport GLTF, error: %d" % [test_name, import_error])
		passed = false
	else:
		var node_count = gltf_state.get_nodes().size()
		print("  Reimported GLTF with %d nodes" % node_count)
		
		if node_count == 0:
			results.errors.append("%s: Reimported GLTF has no nodes" % test_name)
			passed = false
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1

static func _export_scene(scene_instance: Node, output_path: String) -> Dictionary:
	var result := {"success": false, "error": "", "size": 0}
	
	var gltf_doc = GLTFDocument.new()
	var gltf_ext = AxoGltfEx.new()
	gltf_doc.register_gltf_document_extension(gltf_ext)
	
	var gltf_state = GLTFState.new()
	var append_error = gltf_doc.append_from_scene(scene_instance, gltf_state)
	
	if append_error != OK:
		result.error = "append_from_scene failed with error %d" % append_error
		return result
	
	var write_error = gltf_doc.write_to_filesystem(gltf_state, output_path)
	
	if write_error != OK:
		result.error = "write_to_filesystem failed with error %d" % write_error
		return result
	
	# Verify file was created
	if FileAccess.file_exists(output_path):
		var file = FileAccess.open(output_path, FileAccess.READ)
		result.size = file.get_length()
		file.close()
		result.success = true
	else:
		result.error = "File was not created"
	
	return result

