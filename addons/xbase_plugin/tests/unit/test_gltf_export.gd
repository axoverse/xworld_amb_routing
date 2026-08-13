## Unit tests for axo_gltfex.gd GLTF export functionality
extends RefCounted

class_name TestGltfExport

const AxoGltfEx = preload("res://addons/xbase_plugin/axo_gltfex.gd")
const ThingLinkNode3dScript = preload("res://addons/xbase_plugin/axNode3D.gd")
const PHYSICAL_TYPES_JSON_PATH = "res://addons/xbase_plugin/share/data/physical_types.json"

static func _load_physical_types_from_json() -> Array:
	if FileAccess.file_exists(PHYSICAL_TYPES_JSON_PATH):
		var file = FileAccess.open(PHYSICAL_TYPES_JSON_PATH, FileAccess.READ)
		var json = JSON.new()
		var error = json.parse(file.get_as_text())
		file.close()
		if error == OK:
			return json.data
	return []

static func run_all() -> Dictionary:
	var results := {"passed": 0, "failed": 0, "errors": []}
	
	_test_physical_type_to_index(results)
	_test_physical_type_all_values(results)
	_test_process_node_params(results)
	_test_process_layer_component(results)
	_test_process_layer_component_empty(results)
	_test_process_edge_component(results)
	_test_process_pivot_override(results)
	
	return results

static func _test_physical_type_to_index(results: Dictionary):
	var test_name = "physical_type_to_index basic"
	var exporter = AxoGltfEx.new()
	
	var tests = {
		"None": 0,
		"Site": 1,
		"Building": 2,
		"Wing": 3,
		"Ward": 4,
		"Level": 5,
		"Corridor": 6,
		"Room": 7,
		"Bed": 8,
	}
	
	var passed = true
	for physical_type in tests:
		var expected = tests[physical_type]
		var actual = exporter.physical_type_to_index(physical_type)
		if actual != expected:
			results.errors.append("%s: Expected %d for '%s', got %d" % [test_name, expected, physical_type, actual])
			passed = false
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1

static func _test_physical_type_all_values(results: Dictionary):
	var test_name = "physical_type_to_index all values"
	var exporter = AxoGltfEx.new()
	
	# Load from shared JSON file
	var all_types = _load_physical_types_from_json()
	if all_types.is_empty():
		results.errors.append("%s: Failed to load physical_types.json" % test_name)
		results.failed += 1
		return
	
	var passed = true
	for i in range(all_types.size()):
		var actual = exporter.physical_type_to_index(all_types[i])
		if actual != i:
			results.errors.append("%s: Expected index %d for '%s', got %d" % [test_name, i, all_types[i], actual])
			passed = false
	
	# Test invalid type returns -1
	var invalid_result = exporter.physical_type_to_index("InvalidType")
	if invalid_result != -1:
		results.errors.append("%s: Expected -1 for invalid type, got %d" % [test_name, invalid_result])
		passed = false
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1

static func _test_process_node_params(results: Dictionary):
	var test_name = "processNodeParams"
	var exporter = AxoGltfEx.new()
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	node.ThingInstanceLabel = "hospital-room-101"
	node.ThingLabelOverride = "R101"
	node.ThingNameOverride = "Room 101"
	node.PhysicalType = "Room"
	
	var result = exporter.processNodeParams(node, GLTFState.new())
	
	var passed = true
	
	if result.get("type") != "Axomem.XScape.Core.ThingLink,XScape.Core":
		results.errors.append("%s: Wrong type" % test_name)
		passed = false
	
	if result.get("ThingInstanceLabel") != "hospital-room-101":
		results.errors.append("%s: Wrong ThingInstanceLabel" % test_name)
		passed = false
	
	if result.get("ThingLabelOverride") != "R101":
		results.errors.append("%s: Wrong ThingLabelOverride" % test_name)
		passed = false
	
	if result.get("ThingNameOverride") != "Room 101":
		results.errors.append("%s: Wrong ThingNameOverride" % test_name)
		passed = false
	
	if result.get("PhysicalTypeString") != "Room":
		results.errors.append("%s: Wrong PhysicalTypeString" % test_name)
		passed = false
	
	if result.get("PhysicalType") != 7:
		results.errors.append("%s: Wrong PhysicalType index" % test_name)
		passed = false
	
	node.free()
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1

static func _test_process_layer_component(results: Dictionary):
	var test_name = "processLayerComponent with layers"
	var exporter = AxoGltfEx.new()
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	node.useLayers = true
	node.Layers = "Default,Walls,Furniture"
	
	var result = exporter.processLayerComponent(node)
	
	var passed = true
	
	if result.get("type") != "Axomem.XScape.Core.Layer,XScape.Core":
		results.errors.append("%s: Wrong type" % test_name)
		passed = false
	
	if result.get("Layers") != "Default,Walls,Furniture":
		results.errors.append("%s: Wrong Layers" % test_name)
		passed = false
	
	if result.get("Validation") != "OK":
		results.errors.append("%s: Missing Validation" % test_name)
		passed = false
	
	node.free()
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1

static func _test_process_layer_component_empty(results: Dictionary):
	var test_name = "processLayerComponent empty when disabled"
	var exporter = AxoGltfEx.new()
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	node.useLayers = false
	
	var result = exporter.processLayerComponent(node)
	
	var passed = result.is_empty()
	
	if not passed:
		results.errors.append("%s: Expected empty dict when useLayers=false" % test_name)
		results.failed += 1
	else:
		results.passed += 1
	
	node.free()

static func _test_process_edge_component(results: Dictionary):
	var test_name = "processEdgeComponent"
	var exporter = AxoGltfEx.new()
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	node.useEdges = true
	node.Edges = "child,sibling,location"
	
	var result = exporter.processEdgeComponent(node)
	
	var passed = true
	
	if result.get("type") != "Axomem.XScape.Core.Edge,XScape.Core":
		results.errors.append("%s: Wrong type" % test_name)
		passed = false
	
	if result.get("Edges") != "child,sibling,location":
		results.errors.append("%s: Wrong Edges" % test_name)
		passed = false
	
	node.free()
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1

static func _test_process_pivot_override(results: Dictionary):
	var test_name = "processPivotOverrideComponent"
	var exporter = AxoGltfEx.new()
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	node.usePivotOverride = true
	node.PivotRotation = Vector3(0, 90, 0)
	node.CamDistanceMultiplier = 2.5
	
	var result = exporter.processPivotOverrideComponent(node)
	
	var passed = true
	
	if result.get("type") != "Axomem.XScape.Core.PivotOverride,XScape.Core":
		results.errors.append("%s: Wrong type" % test_name)
		passed = false
	
	var rotation = result.get("Rotation", {})
	if rotation.get("y") != 90:
		results.errors.append("%s: Wrong rotation Y" % test_name)
		passed = false
	
	if result.get("CamDistanceMultiplier") != 2.5:
		results.errors.append("%s: Wrong CamDistanceMultiplier" % test_name)
		passed = false
	
	node.free()
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1

