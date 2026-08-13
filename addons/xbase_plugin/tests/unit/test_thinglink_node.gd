## Unit tests for ThingLinkNode3d (axNode3D.gd)
extends RefCounted

class_name TestThingLinkNode

const ThingLinkNode3dScript = preload("res://addons/xbase_plugin/axNode3D.gd")

static func run_all() -> Dictionary:
	var results := {"passed": 0, "failed": 0, "errors": []}
	
	_test_guid_generation(results)
	_test_guid_length(results)
	_test_guid_hex_chars(results)
	_test_layer_flags_default(results)
	_test_layer_flags_multiple(results)
	_test_edge_flags_conversion(results)
	_test_physical_type_to_index(results)
	
	return results

static func _test_guid_generation(results: Dictionary):
	var test_name = "GUID generation uniqueness"
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	var guid1 = node.gen_guid()
	var guid2 = node.gen_guid()
	
	var passed = guid1 != guid2
	
	if not passed:
		results.errors.append("%s: Two generated GUIDs should be different" % test_name)
		results.failed += 1
	else:
		results.passed += 1
	
	node.free()

static func _test_guid_length(results: Dictionary):
	var test_name = "GUID length"
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	var guid = node.gen_guid()
	var passed = guid.length() == 32
	
	if not passed:
		results.errors.append("%s: GUID length should be 32, got %d" % [test_name, guid.length()])
		results.failed += 1
	else:
		results.passed += 1
	
	node.free()

static func _test_guid_hex_chars(results: Dictionary):
	var test_name = "GUID hex characters"
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	var guid = node.gen_guid()
	var passed = true
	
	for c in guid:
		if not c in "0123456789abcdef":
			results.errors.append("%s: GUID contains non-hex char: %s" % [test_name, c])
			passed = false
			break
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1
	
	node.free()

static func _test_layer_flags_default(results: Dictionary):
	var test_name = "Layer flags Default"
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	node.useLayers = true
	
	# Set Default flag (bit 0)
	node.LayerFlags = 1
	
	var passed = node.Layers == "Default"
	
	if not passed:
		results.errors.append("%s: Expected 'Default', got '%s'" % [test_name, node.Layers])
		results.failed += 1
	else:
		results.passed += 1
	
	node.free()

static func _test_layer_flags_multiple(results: Dictionary):
	var test_name = "Layer flags multiple"
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	node.useLayers = true
	
	# Layer names:
	# 0: Default, 1: Always, 2: Never, 3: System, 4: Colorizer, 5: Reserved1,
	# 6: Exterior, 7: Floor, 8: Foundations, 9: Walls, 10: Doors, 11: Furniture
	
	# Set Default (bit 0) + Walls (bit 9) + Doors (bit 10)
	node.LayerFlags = 1 + 512 + 1024  # = 1537
	
	var passed = true
	var layers = node.Layers.split(",")
	
	if not "Default" in layers:
		results.errors.append("%s: Missing 'Default' in '%s'" % [test_name, node.Layers])
		passed = false
	
	if not "Walls" in layers:
		results.errors.append("%s: Missing 'Walls' in '%s'" % [test_name, node.Layers])
		passed = false
	
	if not "Doors" in layers:
		results.errors.append("%s: Missing 'Doors' in '%s'" % [test_name, node.Layers])
		passed = false
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1
	
	node.free()

static func _test_edge_flags_conversion(results: Dictionary):
	var test_name = "Edge flags conversion"
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	node.useEdges = true
	
	# Edge names:
	# 0: none, 1: any, 2: type, 3: subtype, 4: child, 5: sibling, 6: member, ...
	# 11: location
	
	# Set child (bit 4) + location (bit 11)
	node.EdgeFlags = 16 + 2048  # = 2064
	
	var passed = true
	var edges = node.Edges.split(",")
	
	if not "child" in edges:
		results.errors.append("%s: Missing 'child' in '%s'" % [test_name, node.Edges])
		passed = false
	
	if not "location" in edges:
		results.errors.append("%s: Missing 'location' in '%s'" % [test_name, node.Edges])
		passed = false
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1
	
	node.free()

static func _test_physical_type_to_index(results: Dictionary):
	var test_name = "physical_type_to_index in node"
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	var passed = true
	
	# Test a few key values
	if node.physical_type_to_index("Site") != 1:
		results.errors.append("%s: Wrong index for Site" % test_name)
		passed = false
	
	if node.physical_type_to_index("Room") != 7:
		results.errors.append("%s: Wrong index for Room" % test_name)
		passed = false
	
	if node.physical_type_to_index("Bed") != 8:
		results.errors.append("%s: Wrong index for Bed" % test_name)
		passed = false
	
	if passed:
		results.passed += 1
	else:
		results.failed += 1
	
	node.free()

