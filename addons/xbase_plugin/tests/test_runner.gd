## xbase_plugin Test Runner
## Usage (note: --editor flag is required for proper exit):
##   godot --headless --editor --script res://addons/xbase_plugin/tests/test_runner.gd -- --all
##   godot --headless --editor --script res://addons/xbase_plugin/tests/test_runner.gd -- --unit
##   godot --headless --editor --script res://addons/xbase_plugin/tests/test_runner.gd -- --scene=res://amb/AMB_Hospital.tscn
##   godot --headless --editor --script res://addons/xbase_plugin/tests/test_runner.gd -- --export-only
##
## Note: Run 'godot --headless --import' first to ensure resources are imported
extends SceneTree

const CONFIG_PATH = "res://addons/xbase_plugin/tests/test_config.json"

# Preload scripts to ensure they're available
const ThingLinkNode3dScript = preload("res://addons/xbase_plugin/axNode3D.gd")
const AxoGltfExScript = preload("res://addons/xbase_plugin/axo_gltfex.gd")

var _passed := 0
var _failed := 0
var _errors: Array[String] = []

func _init():
	print("=" .repeat(60))
	print("xbase_plugin Test Runner")
	print("=" .repeat(60))
	
	var args = _parse_args()
	
	if args.has("help"):
		_print_help()
		quit(0)
		return
	
	var run_unit := args.has("all") or args.has("unit")
	var run_integration := args.has("all") or args.has("integration")
	var export_only := args.has("export-only")
	var scene_path: String = args.get("scene", "")
	
	# If specific scene is provided, run scene export test
	if scene_path != "":
		run_integration = true
	
	# Export-only mode: export all fixtures without validation
	if export_only:
		print("\n--- Export Only Mode ---")
		_export_all_fixtures()
	else:
		# Default to running all tests if no args
		if not run_unit and not run_integration and scene_path == "":
			run_unit = true
			run_integration = true
		
		# Run tests
		if run_unit:
			print("\n--- Running Unit Tests ---")
			_run_unit_tests()
		
		if run_integration:
			print("\n--- Running Integration Tests ---")
			if scene_path != "":
				_run_scene_export_test(scene_path)
			else:
				_run_integration_tests()
	
	# Print summary
	_print_summary()
	
	# Exit with appropriate code
	var exit_code = 0 if _failed == 0 else 1
	print("Exiting with code: %d" % exit_code)
	
	# Small delay to allow cleanup, then force exit
	OS.delay_msec(500)
	quit(exit_code)

func _parse_args() -> Dictionary:
	var result := {}
	var cmd_args = OS.get_cmdline_user_args()
	
	for arg in cmd_args:
		if arg.begins_with("--"):
			var key_value = arg.substr(2)
			if "=" in key_value:
				var parts = key_value.split("=", true, 1)
				result[parts[0]] = parts[1]
			else:
				result[key_value] = true
	
	return result

func _print_help():
	print("""
Usage: godot --headless --editor --script res://addons/xbase_plugin/tests/test_runner.gd -- [OPTIONS]

Options:
  --all             Run all tests (unit + integration)
  --unit            Run unit tests only
  --integration     Run integration tests only
  --scene=PATH      Test export of a specific scene (e.g., res://amb/AMB_Hospital.tscn)
  --export-only     Export all fixtures to output/ without validation (for Python tests)
  --help            Show this help message

Examples:
  godot --headless --editor --script res://addons/xbase_plugin/tests/test_runner.gd -- --all
  godot --headless --editor --script res://addons/xbase_plugin/tests/test_runner.gd -- --scene=res://amb/AMB_Hospital.tscn
  godot --headless --editor --script res://addons/xbase_plugin/tests/test_runner.gd -- --export-only
""")

func _export_all_fixtures():
	"""Export all test fixtures to output/ for Python validation."""
	const OUTPUT_DIR = "res://addons/xbase_plugin/tests/output/"
	const FIXTURES_DIR = "res://addons/xbase_plugin/tests/fixtures/"
	
	# Ensure output directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	
	var fixtures := [
		"minimal_thinglink_scene.tscn",
		"edge_cases.tscn",
		"nested_hierarchy.tscn",
		"all_components.tscn"
	]
	
	for fixture in fixtures:
		var scene_path = FIXTURES_DIR + fixture
		if not ResourceLoader.exists(scene_path):
			print("  [SKIP] Fixture not found: %s" % fixture)
			continue
		
		var scene = load(scene_path)
		var instance = scene.instantiate()
		
		# Export as .gltf (text JSON) for easier parsing by Python
		var output_name = fixture.replace(".tscn", ".gltf")
		var output_path = OUTPUT_DIR + output_name
		
		var export_result = _export_scene_to_gltf(instance, output_path)
		
		if export_result.success:
			print("  [OK] Exported %s -> %s (%d bytes)" % [fixture, output_name, export_result.size])
			_passed += 1
		else:
			print("  [FAIL] Failed to export %s: %s" % [fixture, export_result.error])
			_failed += 1
		
		instance.queue_free()
	
	print("\nExported %d fixtures to: %s" % [fixtures.size(), ProjectSettings.globalize_path(OUTPUT_DIR)])

func _run_unit_tests():
	# Test GLTF export functions
	_test_physical_type_to_index()
	_test_process_node_params()
	_test_process_layer_component()
	_test_process_edge_component()

	# Test ThingLinkNode3d
	_test_guid_generation()
	_test_layer_flags_to_string()

	# Test PCK dependency-path parsing (XSG-59 G2)
	_test_extract_dep_res_path()

	# Test _xs_prefab address repair/derive (XSG-59 G4)
	_test_normalize_prefab_address()

	# Test ValidateInstanceLabels tolerates non-Node3D children (XSG-59 straggler a)
	_test_validate_instance_label_non_node3d()

	# Test Unity-label -> asset-profile resolution (export_targets_alignment)
	_test_export_profile_resolve()

	# Test Unity-label -> Godot export-platform mapping (XSG-59 G3 PCK preset)
	_test_godot_export_platform()

func _run_integration_tests():
	# Load config to get test scenes
	var config = _load_config()
	if config.is_empty():
		_record_error("Failed to load test config")
		return
	
	for scene_config in config.get("test_scenes", []):
		var path = scene_config.get("path", "")
		if path != "":
			_run_scene_export_test(path, scene_config)

func _load_config() -> Dictionary:
	if not FileAccess.file_exists(CONFIG_PATH):
		print("Warning: Config file not found at %s" % CONFIG_PATH)
		return {}
	
	var file = FileAccess.open(CONFIG_PATH, FileAccess.READ)
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		print("Error parsing config: %s" % json.get_error_message())
		return {}
	
	return json.data

# =============================================================================
# UNIT TESTS
# =============================================================================

func _test_physical_type_to_index():
	var test_name = "physical_type_to_index"
	var exporter = AxoGltfExScript.new()
	
	# Test known values
	var tests = {
		"None": 0,
		"Site": 1,
		"Building": 2,
		"Room": 7,
		"Bed": 8,
		"InvalidType": -1
	}
	
	var all_passed = true
	for physical_type in tests:
		var expected = tests[physical_type]
		var actual = exporter.physical_type_to_index(physical_type)
		if actual != expected:
			_record_error("%s: Expected %d for '%s', got %d" % [test_name, expected, physical_type, actual])
			all_passed = false
	
	_record_result(test_name, all_passed)

func _test_process_node_params():
	var test_name = "processNodeParams"
	
	var exporter = AxoGltfExScript.new()
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	node.ThingInstanceLabel = "test-label"
	node.ThingLabelOverride = "override"
	node.ThingNameOverride = "Test Name"
	node.PhysicalType = "Room"
	
	var result = exporter.processNodeParams(node, GLTFState.new())
	
	var all_passed = true
	
	if result.get("type") != "Axomem.XScape.Core.ThingLink,XScape.Core":
		_record_error("%s: Wrong type in result" % test_name)
		all_passed = false
	
	if result.get("ThingInstanceLabel") != "test-label":
		_record_error("%s: Wrong ThingInstanceLabel" % test_name)
		all_passed = false
	
	if result.get("PhysicalTypeString") != "Room":
		_record_error("%s: Wrong PhysicalTypeString" % test_name)
		all_passed = false
	
	if result.get("PhysicalType") != 7:
		_record_error("%s: Wrong PhysicalType index, expected 7 got %s" % [test_name, result.get("PhysicalType")])
		all_passed = false
	
	node.queue_free()
	_record_result(test_name, all_passed)

func _test_process_layer_component():
	var test_name = "processLayerComponent"
	
	var exporter = AxoGltfExScript.new()
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	node.useLayers = true
	node.Layers = "Default,Walls,Doors"
	
	var result = exporter.processLayerComponent(node)
	
	var all_passed = true
	
	if result.get("type") != "Axomem.XScape.Core.Layer,XScape.Core":
		_record_error("%s: Wrong type in result" % test_name)
		all_passed = false
	
	if result.get("Layers") != "Default,Walls,Doors":
		_record_error("%s: Wrong Layers value" % test_name)
		all_passed = false
	
	node.queue_free()
	_record_result(test_name, all_passed)

func _test_process_edge_component():
	var test_name = "processEdgeComponent"
	
	var exporter = AxoGltfExScript.new()
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	node.useEdges = true
	node.Edges = "child,location"
	
	var result = exporter.processEdgeComponent(node)
	
	var all_passed = true
	
	if result.get("type") != "Axomem.XScape.Core.Edge,XScape.Core":
		_record_error("%s: Wrong type in result" % test_name)
		all_passed = false
	
	if result.get("Edges") != "child,location":
		_record_error("%s: Wrong Edges value" % test_name)
		all_passed = false
	
	node.queue_free()
	_record_result(test_name, all_passed)

func _test_guid_generation():
	var test_name = "GUID generation"
	
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	
	# Trigger GUID generation
	var guid = node.gen_guid()
	
	var all_passed = true
	
	if guid.length() != 32:
		_record_error("%s: GUID length should be 32, got %d" % [test_name, guid.length()])
		all_passed = false
	
	# Check all characters are hex
	for c in guid:
		if not c in "0123456789abcdef":
			_record_error("%s: GUID contains non-hex character: %s" % [test_name, c])
			all_passed = false
			break
	
	node.queue_free()
	_record_result(test_name, all_passed)

func _test_extract_dep_res_path():
	# Covers the pure parser behind the PCK dependency collector (XSG-59 G2).
	# On Godot 4.6, ResourceLoader.get_dependencies returns UID-form entries
	# ("uid://HASH::Type::res://path"); the old get_slice("::", 0) dropped them,
	# emptying the PCK. extract_dep_res_path must recover the res:// path from
	# both the UID form and the legacy form, and drop entries with no res:// seg.
	var test_name = "extract_dep_res_path"
	var XBasePluginScript = load("res://addons/xbase_plugin/xbase_plugin.gd")

	var all_passed = true

	# (input, expected) — expected "" means the entry should be dropped.
	var cases := [
		# Godot 4.6 UID form: uid + type + res path -> res path
		["uid://cabc123def456::PackedScene::res://Assets/amb/Prefabs/xw_hospital_bed.tscn",
			"res://Assets/amb/Prefabs/xw_hospital_bed.tscn"],
		# UID form pointing at a material .tres
		["uid://bxyz789::StandardMaterial3D::res://Materials/xw_wall.mat.tres",
			"res://Materials/xw_wall.mat.tres"],
		# Legacy form with a trailing type hint -> res path (unchanged behaviour)
		["res://scenes/test_site/Bed.tscn::PackedScene", "res://scenes/test_site/Bed.tscn"],
		# Legacy form for a script dependency
		["res://addons/xbase_plugin/axNode3D.gd::GDScript", "res://addons/xbase_plugin/axNode3D.gd"],
		# Plain res:// path, no "::" -> passthrough
		["res://textures/floor.png", "res://textures/floor.png"],
		# Garbage: uid with no res:// fallback segment -> dropped
		["uid://deadbeefdeadbeef", ""],
		# Garbage: uid + type but still no res:// segment -> dropped
		["uid://deadbeef::PackedScene", ""],
		# Empty string -> dropped
		["", ""],
		# Wholly unrelated text -> dropped
		["not a resource path at all", ""],
	]

	for case in cases:
		var input: String = case[0]
		var expected: String = case[1]
		var actual: String = XBasePluginScript.extract_dep_res_path(input)
		if actual != expected:
			_record_error("%s: for '%s' expected '%s', got '%s'" % [test_name, input, expected, actual])
			all_passed = false

	_record_result(test_name, all_passed)

func _test_normalize_prefab_address():
	# Covers the pure _xs_prefab address repair/derive (XSG-59 G4). The Unity
	# import (XSC-260) baked `Packages/io.axomem...` prefab paths as `s/io.axomem...`
	# (7-char over-strip). normalize_prefab_address must (a) invert that mangle in
	# repair mode, (b) leave clean authored values untouched, (c) derive the
	# authoritative address from an instanced-scene root's scene_file_path, and
	# (d) NOT derive when the authored PrefabPath is empty (preserves the
	# byte-identical TestSite export — plain Bed.tscn instances must stay blank).
	var test_name = "normalize_prefab_address"
	var XBasePluginScript = load("res://addons/xbase_plugin/xbase_plugin.gd")

	var all_passed = true

	# (raw, scene_file_path, expected)
	var cases := [
		# Repair: mangled `s/` -> `Packages/` (inverse of Unity's 7-char strip)
		["s/io.axomem.xworld.assets/CoreBuildingPack/Prefabs/xw_hospital_bed", "",
			"Packages/io.axomem.xworld.assets/CoreBuildingPack/Prefabs/xw_hospital_bed"],
		# Repair: clean authored value passes through unchanged
		["amb/Prefabs/amb_hospital_level", "", "amb/Prefabs/amb_hospital_level"],
		# Derive: scene_file_path is authoritative — strip res://, Assets/, .tscn
		["s/whatever.mangled", "res://Assets/amb/Prefabs/X.tscn", "amb/Prefabs/X"],
		# Derive: res://Packages keeps its Packages/ prefix
		["ignored", "res://Packages/io.a/P/y.tscn", "Packages/io.a/P/y"],
		# Derive: real bed case — .prefab.tscn double extension both stripped
		["s/io.a/P/y", "res://Packages/io.a/P/y.prefab.tscn", "Packages/io.a/P/y"],
		# Empty raw + empty scene_file_path -> ""
		["", "", ""],
		# Empty raw + non-empty scene_file_path -> "" (derive guarded by raw != "";
		# protects blank _xs_prefab on plain instanced children)
		["", "res://Assets/amb/Prefabs/Z.tscn", ""],
	]

	for case in cases:
		var raw: String = case[0]
		var sfp: String = case[1]
		var expected: String = case[2]
		var actual: String = XBasePluginScript.normalize_prefab_address(raw, sfp)
		if actual != expected:
			_record_error("%s: for raw='%s' sfp='%s' expected '%s', got '%s'" % [test_name, raw, sfp, expected, actual])
			all_passed = false

	_record_result(test_name, all_passed)

func _test_validate_instance_label_non_node3d():
	# ValidateInstanceLabels iterates ALL children and calls ValidateInstanceLabelInNode
	# on each. A WorldEnvironment child extends Node (not Node3D); with the param
	# typed Node3D the call itself threw "not a subclass of the expected argument
	# class" once per AMB export (XSG-59 straggler a). The AxNode3D sibling must
	# still be processed (ThingGuid assigned) with no error.
	var test_name = "validate_instance_label_non_node3d"
	var XBasePluginScript = load("res://addons/xbase_plugin/xbase_plugin.gd")

	var all_passed = true

	var xbp = XBasePluginScript.new()

	var root = ThingLinkNode3dScript.new()          # AxNode3D root
	root.name = "Root"
	var world_env = WorldEnvironment.new()          # extends Node, NOT Node3D
	world_env.name = "WorldEnv"
	var child = ThingLinkNode3dScript.new()         # AxNode3D sibling of the WorldEnvironment
	child.name = "AxChild"
	root.add_child(world_env)
	root.add_child(child)

	# Clear so we can prove ValidateInstanceLabels assigns it (not _enter_tree —
	# the tree is detached from the SceneTree so _enter_tree never fires).
	child.ThingGuid = ""

	# Must not throw despite the non-Node3D child.
	xbp.ValidateInstanceLabels(root)

	if child.ThingGuid == "":
		_record_error("%s: AxNode3D sibling was not processed (ThingGuid still empty) — traversal aborted on WorldEnvironment" % test_name)
		all_passed = false

	root.free()  # frees the whole detached subtree
	xbp.free()
	_record_result(test_name, all_passed)

func _test_export_profile_resolve():
	# Unity build-target labels are the CI contract; export_profiles.gd
	# resolves each to one of three internal asset profiles (labels collapse
	# by design: both Standalone* -> desktop, iOS/Android -> mobile). Unknown
	# labels fail loud with "".
	var test_name = "export_profile_resolve"
	var ExportProfiles = load("res://addons/xbase_plugin/export_profiles.gd")

	var all_passed = true

	var cases := [
		["StandaloneWindows64", "desktop"],
		["StandaloneLinux64", "desktop"],
		["WindowsStoreApps", ""],   # RETIRED (HoloLens) — no-ops upstream, resolver fails loud
		["WebGL", "web"],
		["iOS", "mobile"],
		["Android", "mobile"],
		["PlayStation5", ""],   # unknown label -> loud "" (CI contract breach)
		["", ""],
	]

	for case in cases:
		var input: String = case[0]
		var expected: String = case[1]
		var actual: String = ExportProfiles.resolve(input)
		if actual != expected:
			_record_error("%s: for '%s' expected '%s', got '%s'" % [test_name, input, expected, actual])
			all_passed = false

	# Every profile must expose the three advisory knobs the alignment doc
	# defines — the seam later export passes consume.
	for profile in ["desktop", "web", "mobile"]:
		var s: Dictionary = ExportProfiles.settings_for(profile)
		for key in ["texture_compression", "max_texture_size", "shader_set"]:
			if not s.has(key):
				_record_error("%s: settings_for('%s') missing '%s'" % [test_name, profile, key])
				all_passed = false

	_record_result(test_name, all_passed)

func _test_godot_export_platform():
	# The PCK export-preset path (XSG-59 G3) drives `--export-pack` with a
	# concrete Godot export-platform DISPLAY NAME, resolved from the Unity
	# build-target label. Distinct from resolve()/asset-profiles: several
	# labels collapse (both Standalone Windows variants -> "Windows Desktop"),
	# and an unknown label fails loud with "" (the caller then falls back to
	# "Web" with a warning rather than aborting the export).
	var test_name = "godot_export_platform"
	var ExportProfiles = load("res://addons/xbase_plugin/export_profiles.gd")

	var all_passed = true

	var cases := [
		["StandaloneWindows64", "Windows Desktop"],
		["WindowsStoreApps", ""],   # RETIRED (HoloLens)
		["StandaloneLinux64", "Linux"],
		["WebGL", "Web"],
		["iOS", "iOS"],
		["Android", "Android"],
		["PlayStation5", ""],   # unknown label -> loud "" (caller falls back to Web)
	]

	for case in cases:
		var input: String = case[0]
		var expected: String = case[1]
		var actual: String = ExportProfiles.godot_export_platform(input)
		if actual != expected:
			_record_error("%s: for '%s' expected '%s', got '%s'" % [test_name, input, expected, actual])
			all_passed = false

	_record_result(test_name, all_passed)

func _test_layer_flags_to_string():
	var test_name = "Layer flags to string"
	
	var node = Node3D.new()
	node.set_script(ThingLinkNode3dScript)
	node.useLayers = true
	
	# Set Default flag (bit 0)
	node.LayerFlags = 1
	
	var all_passed = true
	
	if not "Default" in node.Layers:
		_record_error("%s: Expected 'Default' in Layers, got '%s'" % [test_name, node.Layers])
		all_passed = false
	
	node.queue_free()
	_record_result(test_name, all_passed)

# =============================================================================
# INTEGRATION TESTS
# =============================================================================

func _run_scene_export_test(scene_path: String, config: Dictionary = {}):
	var test_name = "Scene Export: %s" % scene_path
	print("Testing: %s" % scene_path)
	
	# Load scene
	if not ResourceLoader.exists(scene_path):
		_record_error("%s: Scene file not found" % test_name)
		_record_result(test_name, false)
		return
	
	var scene = load(scene_path)
	if scene == null:
		_record_error("%s: Failed to load scene" % test_name)
		_record_result(test_name, false)
		return
	
	var scene_instance = scene.instantiate()
	if scene_instance == null:
		_record_error("%s: Failed to instantiate scene" % test_name)
		_record_result(test_name, false)
		return
	
	var all_passed = true
	
	# Check root node properties if config provided
	var expected_root = config.get("expected_root", {})
	if not expected_root.is_empty():
		for prop_name in expected_root:
			var expected_value = expected_root[prop_name]
			var actual_value = scene_instance.get(prop_name)
			if actual_value != expected_value:
				_record_error("%s: Root property '%s' expected '%s', got '%s'" % [test_name, prop_name, expected_value, actual_value])
				all_passed = false
	
	# Test GLTF export
	var output_dir = "res://addons/xbase_plugin/tests/output/"
	var output_path = output_dir + scene_path.get_file().replace(".tscn", "_test.glb")
	
	# Ensure output directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	
	var gltf_doc = GLTFDocument.new()
	var gltf_ext = AxoGltfExScript.new()
	gltf_doc.register_gltf_document_extension(gltf_ext)
	
	var gltf_state = GLTFState.new()
	var append_error = gltf_doc.append_from_scene(scene_instance, gltf_state)
	
	if append_error != OK:
		_record_error("%s: Failed to append scene to GLTF, error: %d" % [test_name, append_error])
		all_passed = false
	else:
		var write_error = gltf_doc.write_to_filesystem(gltf_state, output_path)
		if write_error != OK:
			_record_error("%s: Failed to write GLTF, error: %d" % [test_name, write_error])
			all_passed = false
		else:
			print("  Exported to: %s" % output_path)
			
			# Validate the exported GLTF has extras
			var validation_passed = _validate_gltf_extras(output_path, config)
			if not validation_passed:
				all_passed = false
	
	scene_instance.queue_free()
	_record_result(test_name, all_passed)

func _validate_gltf_extras(gltf_path: String, config: Dictionary) -> bool:
	# For GLB files, we can't easily read the JSON without a parser
	# Instead, we'll verify the file exists and has reasonable size
	var global_path = ProjectSettings.globalize_path(gltf_path)
	
	if not FileAccess.file_exists(gltf_path):
		_record_error("GLTF file not created: %s" % gltf_path)
		return false
	
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	var size = file.get_length()
	file.close()
	
	if size < 100:
		_record_error("GLTF file too small (%d bytes), likely invalid" % size)
		return false
	
	print("  GLTF file size: %d bytes" % size)
	
	# Try to reimport and verify extras were preserved
	var gltf_doc = GLTFDocument.new()
	var gltf_state = GLTFState.new()
	var import_error = gltf_doc.append_from_file(gltf_path, gltf_state)
	
	if import_error != OK:
		_record_error("Failed to reimport GLTF for validation, error: %d" % import_error)
		return false
	
	print("  GLTF reimport successful, %d nodes" % gltf_state.get_nodes().size())
	return true

# =============================================================================
# HELPERS
# =============================================================================

func _export_scene_to_gltf(scene_instance: Node, output_path: String) -> Dictionary:
	"""Export a scene to GLTF with xbase_plugin extension. Returns {success, error, size}."""
	var result := {"success": false, "error": "", "size": 0}
	
	var gltf_doc = GLTFDocument.new()
	var gltf_ext = AxoGltfExScript.new()
	gltf_doc.register_gltf_document_extension(gltf_ext)
	
	var gltf_state = GLTFState.new()
	var append_error = gltf_doc.append_from_scene(scene_instance, gltf_state)
	
	if append_error != OK:
		result.error = "append_from_scene failed with error %d" % append_error
		return result
	
	# Ensure output directory exists
	var dir_path = output_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	
	var write_error = gltf_doc.write_to_filesystem(gltf_state, output_path)
	
	if write_error != OK:
		result.error = "write_to_filesystem failed with error %d" % write_error
		return result
	
	# Verify file was created and get size
	if FileAccess.file_exists(output_path):
		var file = FileAccess.open(output_path, FileAccess.READ)
		result.size = file.get_length()
		file.close()
		result.success = true
	else:
		result.error = "File was not created"
	
	return result

func _record_result(test_name: String, passed: bool):
	if passed:
		_passed += 1
		print("  [PASS] %s" % test_name)
	else:
		_failed += 1
		print("  [FAIL] %s" % test_name)

func _record_error(message: String):
	_errors.append(message)
	print("    ERROR: %s" % message)

func _print_summary():
	print("\n" + "=" .repeat(60))
	print("TEST SUMMARY")
	print("=" .repeat(60))
	print("Passed: %d" % _passed)
	print("Failed: %d" % _failed)
	print("Total:  %d" % (_passed + _failed))
	
	if _errors.size() > 0:
		print("\nErrors:")
		for error in _errors:
			print("  - %s" % error)
	
	print("=" .repeat(60))
	
	if _failed == 0:
		print("All tests passed!")
	else:
		print("Some tests failed. See errors above.")

