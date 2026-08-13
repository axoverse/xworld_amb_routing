@tool
extends EditorPlugin

var axo_gltfex_pr                = preload("res://addons/xbase_plugin/axo_gltfex.gd")
var thinglinknode3d_pr = preload("res://addons/xbase_plugin/axNode3D.gd")
const AxoNode3d         = preload("res://addons/xbase_plugin/axNode3D.gd")
const SyncAmThingLink   = preload("res://addons/xbase_plugin/sync_am_thinglink.gd")
const ExportProfiles    = preload("res://addons/xbase_plugin/export_profiles.gd")
const ExportPresetPack  = preload("res://addons/xbase_plugin/export_preset_pack.gd")

var dock # A class member to hold the dock during the plugin life cycle.
var serializeButton
var addRoomButton
var exportScene
var loadFromServerButton
var syncAmThingLinkButton
var syncAmOverrideCheck
var syncOpenOnlyCheck
var exportSkipExistingCheck
var exportOpenOnlyCheck
var exportSkipGlbCheck
var exportDisableExtrasCheck
var exportAsPckCheck
var clearThingInstanceLabelsButton
var xb
var tb
@onready var max_elements: int = 0

var xScape_ProgramData_Dir: String = ""
var restrict_to_scenes: Array = []  # If non-empty, only export these scene paths (relative, e.g. "levels/EI008.0_LevelGroup.tscn")
# Headless override for the "Skip GLB" UI checkbox. Lets headless callers
# (e.g. xBaseHeadless.gd --skip-glb) request CSV-only export without
# instantiating the editor dock. Forces skip_glb=true when set; false
# leaves the existing UI/checkbox semantics untouched.
var headless_skip_glb: bool = false
# Headless override: emit a per-scene .pck alongside (or instead of) the GLB.
# Independent of skip_glb — both can be true (PCK-only), both false (GLB-only),
# or both produced together. Mirrors the rule the dock checkbox follows but
# without depending on dock UI being instantiated.
var headless_export_pck: bool = false
var _verbose_logging: bool = false

# Brotli sidecar emission state, scoped to a single XFabExporter() run.
# _brotli_setup_for_run() resets all three at the start of each export so the CLI
# is probed exactly once and the "unavailable" warning fires at most once per run;
# _emit_brotli_sidecar() reads them after each .pck / .glb is finalized.
var _brotli_enabled: bool = false     # cached value of the brotli_sidecars setting
var _brotli_available: bool = false   # brotli CLI answered the --version probe
var _brotli_warned: bool = false      # one-time warning latch (missing/failed CLI)
# Compression quality (0-11). q=6 matches q=11's ratio on large binary asset packs
# (~100MB GLBs) while staying ~1s vs q=11's ~135s per pack — measured on a dev box —
# and mirrors the nginx brotli module's default balance. q=11 was rejected as
# prohibitively slow for a default-on export step.
const BROTLI_QUALITY: int = 6

## Helper to log only when verbose logging is enabled
func _log_verbose(msg: String) -> void:
	if _verbose_logging:
		print(msg)

## Returns a file's size in bytes, or 0 if it can't be opened.
func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var sz: int = f.get_length()
	f.close()
	return sz

## Probes for the brotli CLI and caches per-run sidecar state. Called once at the
## start of each XFabExporter() run so availability is detected up front via a
## single `brotli --version` probe rather than per artifact. When the setting is
## on but the CLI is missing/unusable, warns exactly once here and disables
## sidecars for the run — the export itself is never affected.
func _brotli_setup_for_run() -> void:
	_brotli_available = false
	_brotli_warned = false
	_brotli_enabled = bool(ProjectSettings.get_setting("xbase_plugin/settings/brotli_sidecars", true))
	if not _brotli_enabled:
		return
	# OS.execute resolves a bare executable name via PATH (execvp on Unix,
	# CreateProcess on Windows), so "brotli" finds brotli / brotli.exe on PATH.
	# A 0 exit code means the CLI is usable; any non-zero (e.g. -1 could-not-start,
	# or 127 command-not-found) means it is unavailable and sidecars are skipped.
	var probe_out: Array = []
	var rc: int = OS.execute("brotli", ["--version"], probe_out, true)
	if rc == 0:
		_brotli_available = true
		var ver: String = str(probe_out[0]).strip_edges() if not probe_out.is_empty() else ""
		print("  Brotli sidecars ON — using %s (quality %d)" % [ver if ver != "" else "brotli", BROTLI_QUALITY])
	else:
		# Graceful degrade: warn ONCE, skip all sidecars, export continues.
		_brotli_warned = true
		push_warning("[xbase_plugin] brotli_sidecars is enabled but the 'brotli' CLI was not found on PATH (probe exit=%d). Skipping .br sidecars for this export — install the 'brotli' package to enable them." % rc)

## Emits a brotli-compressed `<artifact>.br` sidecar next to a freshly finalized
## .pck / .glb when sidecars are enabled and the CLI is available, logging the
## original + compressed sizes. Never fails the export: a brotli error warns once
## and disables sidecars for the remainder of the run, leaving artifacts intact.
func _emit_brotli_sidecar(artifact_path: String) -> void:
	if not _brotli_enabled or not _brotli_available:
		return
	if not FileAccess.file_exists(artifact_path):
		return
	var sidecar_path: String = artifact_path + ".br"
	# brotli -f (overwrite output) -k (keep source) -q N (quality) -o OUT IN
	var args: PackedStringArray = ["-f", "-k", "-q", str(BROTLI_QUALITY), "-o", sidecar_path, artifact_path]
	var out: Array = []
	var rc: int = OS.execute("brotli", args, out, true)
	if rc != 0 or not FileAccess.file_exists(sidecar_path):
		if not _brotli_warned:
			_brotli_warned = true
			push_warning("[xbase_plugin] brotli failed on %s (exit=%d) — skipping .br sidecars for the rest of this export." % [artifact_path, rc])
		# Stop retrying a broken CLI for every subsequent artifact this run.
		_brotli_available = false
		return
	var orig_size: int = _file_size(artifact_path)
	var comp_size: int = _file_size(sidecar_path)
	var pct: float = (100.0 * comp_size / orig_size) if orig_size > 0 else 0.0
	print("  Brotli sidecar: %s (%d -> %d bytes, %.1f%%)" % [sidecar_path, orig_size, comp_size, pct])

## Returns the default xScape data directory based on the current platform.
## - Windows: Uses %LOCALAPPDATA% (e.g., C:/Users/<user>/AppData/Local)
## - Linux/macOS: Uses XDG_DATA_HOME or ~/.local/share (XDG Base Directory spec)
func _get_default_xscape_data_dir() -> String:
	if OS.get_name() == "Windows":
		var pd: String = OS.get_environment("LOCALAPPDATA")
		if pd.is_empty():
			var home: String = OS.get_environment("USERPROFILE")
			if home.is_empty():
				home = "C:/Users/Default"
			pd = home + "/AppData/Local"
		# Convert backslashes to forward slashes for cross-platform compatibility
		pd = pd.replace("\\", "/")
		return pd
	else:
		# Linux/macOS - use XDG Base Directory specification
		var xdg_data: String = OS.get_environment("XDG_DATA_HOME")
		if xdg_data.is_empty():
			var home: String = OS.get_environment("HOME")
			if home.is_empty():
				home = "/tmp"  # Fallback
			xdg_data = home + "/.local/share"
		return xdg_data

## Returns the xScape data directory, using project setting if configured, otherwise auto-detect
## Note: This returns the BASE directory (e.g. C:/ProgramData). The code will append /xScape/Addressables/...
func _get_xscape_data_dir() -> String:
	var custom_dir: String = ProjectSettings.get_setting("xbase_plugin/settings/program_data_dir", "")
	if not custom_dir.is_empty():
		# Convert backslashes to forward slashes for cross-platform compatibility
		custom_dir = custom_dir.replace("\\", "/")
		# Strip trailing slash if present
		custom_dir = custom_dir.rstrip("/")
		# If user included xScape/Addressables in the path, strip it to avoid doubling
		if custom_dir.ends_with("/xScape/Addressables"):
			custom_dir = custom_dir.substr(0, custom_dir.length() - "/xScape/Addressables".length())
			push_warning("xbase_plugin: program_data_dir should not include '/xScape/Addressables' - it will be appended automatically. Stripping it.")
		elif custom_dir.ends_with("/xScape"):
			custom_dir = custom_dir.substr(0, custom_dir.length() - "/xScape".length())
			push_warning("xbase_plugin: program_data_dir should not include '/xScape' - it will be appended automatically. Stripping it.")
		return custom_dir
	return _get_default_xscape_data_dir()

func _enter_tree():
	# Add custom project settings if they don't exist
	var settings: Dictionary = {
		"xbase_plugin/settings/version": {
			"type": TYPE_STRING,
			"initial_value": "1.0.0",
			"hint": PROPERTY_HINT_NONE,
			"hint_string": "Content version used for export paths and bundle identifiers."
		},
		"xbase_plugin/settings/company_name": {
			"type": TYPE_STRING,
			"initial_value": "DefaultCompany",
			"hint": PROPERTY_HINT_NONE,
			"hint_string": "Content company name used in export paths and metadata."
		},
		"xbase_plugin/settings/project_name": {
			"type": TYPE_STRING,
			"initial_value": "DefaultProject",
			"hint": PROPERTY_HINT_NONE,
			"hint_string": "Content project name used in export paths and metadata."
		},
		"xbase_plugin/settings/program_data_dir": {
			"type": TYPE_STRING,
			"initial_value": "",  # Empty = auto-detect based on platform
			"hint": PROPERTY_HINT_DIR,
			"hint_string": "Override base data directory (auto-detect if empty)."
		},
		"xbase_plugin/settings/verbose_logging": {
			"type": TYPE_BOOL,
			"initial_value": false,
			"hint": PROPERTY_HINT_NONE,
			"hint_string": "Enable verbose logging for plugin tools."
		},
		"xbase_plugin/settings/brotli_sidecars": {
			"type": TYPE_BOOL,
			"initial_value": true,
			"hint": PROPERTY_HINT_NONE,
			"hint_string": "Emit brotli (.br) sidecars next to exported .pck/.glb artifacts. Requires the 'brotli' CLI on PATH; degrades gracefully (warns once, skips) if unavailable."
		}
	}
	
	# Add all settings
	for setting_name in settings:
		if !ProjectSettings.has_setting(setting_name):
			var setting = settings[setting_name]
			ProjectSettings.set_setting(setting_name, setting.initial_value)
			ProjectSettings.set_initial_value(setting_name, setting.initial_value)
			ProjectSettings.add_property_info({
				"name": setting_name,
				"type": setting.type,
				"hint": setting.hint,
				"hint_string": setting.hint_string
			})
	
	# Make sure settings are saved
	ProjectSettings.save()

	# Now that settings are registered, get the data directory (uses setting if configured)
	xScape_ProgramData_Dir = _get_xscape_data_dir()
	_verbose_logging = ProjectSettings.get_setting("xbase_plugin/settings/verbose_logging", false)

	# Initialization of the plugin goes here.
	# Here we create custom nodes for user - 
	# can be good place for adding mirror types Node3D, Mesh etc with attached ThingLink script
	#add_custom_type("MyButton", "Button", preload("res://addons/xbase_plugin/my_button.gd"), preload("res://addons/xbase_plugin/icon.svg"))
	#add_custom_type("xbGroupNode3d", "Node3D", preload("res://addons/xbase_plugin/xbGroupNode3d.gd"), preload("res://addons/xbase_plugin/icon.svg"))

	# Load the dock scene and instantiate it.
	dock = preload("res://addons/xbase_plugin/xBasePluginScene.tscn").instantiate()
	# Get reference to the button
		
	add_control_to_dock(DOCK_SLOT_LEFT_UL, dock)

	exportScene = dock.find_child("exportSceneToGLB") # button caption: Export Addressables
	exportScene.button_up.connect(XFabExporter)
	exportSkipExistingCheck = dock.find_child("exportSkipExistingCheck")
	exportOpenOnlyCheck = dock.find_child("exportOpenOnlyCheck")
	exportSkipGlbCheck = dock.find_child("exportSkipGlbCheck")
	exportDisableExtrasCheck = dock.find_child("exportDisableExtrasCheck")
	exportAsPckCheck = dock.find_child("exportAsPckCheck")

	addRoomButton = dock.find_child("addRoomButton")  # button caption: Add ThingLink to Node
	addRoomButton.button_up.connect(add_thinglink_data_to_node_button_pressed)
	#addRoomButton.button_up.connect(add_node_button_pressed)
	
	serializeButton = dock.find_child("serializeButton")
	serializeButton.button_up.connect(serialized_button_pressed)
	print ( serializeButton.name)
	

	loadFromServerButton = dock.find_child("loadFromServerButton")
	loadFromServerButton.button_up.connect(load_from_server_pressed)

	clearThingInstanceLabelsButton = dock.find_child("clearThingInstanceLabelsButton")
	clearThingInstanceLabelsButton.button_up.connect(clear_thing_instance_labels_pressed)

	syncAmThingLinkButton = dock.find_child("syncAmThingLinkButton")
	syncAmThingLinkButton.button_up.connect(sync_am_thinglink_pressed)
	syncOpenOnlyCheck = dock.find_child("syncOpenOnlyCheck")
	syncAmOverrideCheck = dock.find_child("syncAmOverrideCheck")
	#var add_node_button = dock

	#add_node_button.pressed.connect(self.add_node_button_pressed)


func _exit_tree():
	# Clean-up of the plugin goes here.
	# Always remember to remove it from the engine when deactivated.
	remove_custom_type("MyButton")
	
	# Erase the control from the memory.
	remove_control_from_docks(dock)
	dock.free()
	
	


func print_node_info_recursive(node, indent_level,  file_out: FileAccess ): ## Old export of ThingLink Data - replaced by GLTF extras
	if(max_elements > 1000):
		return
	max_elements = max_elements + 1
	if indent_level>10:
		return
	# Print information about this node
	var indent: String = " ".repeat(indent_level*4)
	print_verbose(" ".repeat(indent_level*4-2) + "{")
	#print(indent + '"Node": "' + node.name + '",')
	#print(indent + '"Type": "' + node.get_class() + '",' )

	# Print position if the node has a position property
	if node is AxoNode3d:
		var tn : AxoNode3d = node
		file_out.store_csv_line([tn.name,"ThingLinkType",tn.ParentOverride_name,tn.ThingLabelOverride,tn.ThingNameOverride,tn.PhysicalType,tn.ThingInstanceLabel,tn.ObjectInstanceGuid],",")
		# print(indent + "Name:" + tn.name + "ThingLink:"  + str(tn.ThingLink))
	else:
		file_out.store_csv_line([node.name,node.get_class(),"","","","","",""],",")
		print_verbose(indent + "Name:" + node.name + " Type:" + node.get_class())
		
	
	if node is Node3D:
		
		var n3d: Node3D = node as Node3D
		if n3d.is_visible_in_tree() == false:
			return
		var instance_name: String = n3d.scene_file_path
		
		var node_pure: Node = n3d as Node
		

	# Recursively print information for all children
		var allc: Array[Node] = node.get_children(false)
		for child in allc:
			print_node_info_recursive(child, indent_level + 1, file_out)
	print_verbose(" ".repeat(indent_level*4-2) + "},")
		
func print_node_info():
	var target_export_dir: String = xScape_ProgramData_Dir + "/xScape/Addressables/axomem.io/xworld_gltftest"
	print_verbose("Printing node information:" + 	target_export_dir)
	#todo in Addressabless create .json
	max_elements = 0
	var editor_interface: EditorInterface = get_editor_interface()
	var scene_root: Node                  = editor_interface.get_edited_scene_root()

	# Recursively print information for all children
	if scene_root:
		var jsonobj: JSON = JSON.new()
		var file_out_path: String = editor_interface.get_current_path() + "/../xb_exported_scene.txt"
		file_out_path = target_export_dir + "/xb_exported_scene.txt"
		print_verbose("Saving to file:" + file_out_path)
		#var save_file = FileAccess.open("user://savegame.save", FileAccess.WRITE)
		var save_file: FileAccess = FileAccess.open(file_out_path, FileAccess.WRITE)
		print_verbose("    file opened")
		save_file.store_csv_line(["Name","Type","ParentOverride","ThingLabelOverride","ThingNameOverride","PhysicalType","ThingInstanceLabel","ObjectInstanceGuid"],",")
		print_verbose("    csv line written")
		print_node_info_recursive(scene_root, 1, save_file)
		print_verbose("    node info written")
		save_file.close()
		print_verbose("    file closed")
	else:
		push_warning("No scene root found.")
		
		
func is_prefab(n: Node3D): ## returns true if node contains
	var is_instanced_scene: bool = true # n3d.filename != ""
	var instance_name: String    = n.scene_file_path

	if( instance_name.is_empty() ):
		is_instanced_scene = false
	elif(instance_name.begins_with("res://models/Axomem") ):
		is_instanced_scene = true
	elif(instance_name.begins_with("res://models/AMB/AMB") ):
		is_instanced_scene = true
	elif(instance_name.begins_with("res://models") ):
		is_instanced_scene = false
	else:
		is_instanced_scene = true
		
	return is_instanced_scene
	
func get_parent_for(node: Node, last_parent: AxoNode3d): ## walks up to find parent ThingLink node
	if node == null:
		return last_parent

	if node is AxoNode3d:
		var tn: AxoNode3d = node
		if tn.ParentOverride != null:
			return tn.ParentOverride

	var current: Node = node.get_parent()
	while current != null:
		if current is AxoNode3d:
			return current
		current = current.get_parent()

	return last_parent
	
	
func addq(inp: String) -> String: ## adds quotes to string - so from ABC DEF makes "ABC DEF"
	var outstr: String = '"'+"%s"%[inp]+'"'
	return outstr
	
## generating one CSV line, handles single ThingLink node.
## export_type is the value written into the `_xs_prefab_type` column —
## "pck" when --export-pck/headless_export_pck is set, else "xfabglx".
func XFab_export_node(node, indent_level, file_out: FileAccess, last_parent: AxoNode3d, root_node: Node3D, export_type: String, parent_global_pos: Vector3 = Vector3.ZERO, scene_path: String = ""):
	if indent_level>1000:
		return false

	var current_global_pos: Vector3 = parent_global_pos
	if node is Node3D:
		var n3d: Node3D = node as Node3D
		current_global_pos += n3d.position  # Add local position to parent's global position
	
	var partOfInstanceLabel: String = "";
	var label = node.name;
	var prefabRoot: String = "";
	if( indent_level == 1):
		label = node.name;
		
	# `_prefab_path` GATES whether this scene has a prefab-root identity (the root,
	# or a direct child, carries a PrefabPath). It is kept solely for that guard —
	# and to preserve byte-parity of the historical empty/non-empty decision
	# (XSG-59 G4). The authored PrefabPath may be the Unity-mangled `s/io.axomem...`;
	# derive from the source node's scene_file_path when it is an instanced-scene root.
	var _prefab_path: String = ""
	if root_node is AxoNode3d:
		_prefab_path = normalize_prefab_address((root_node as AxoNode3d).PrefabPath, root_node.scene_file_path)
	if _prefab_path == "":
		for _child in root_node.get_children(false):
			if _child is AxoNode3d and (_child as AxoNode3d).PrefabPath != "":
				_prefab_path = normalize_prefab_address((_child as AxoNode3d).PrefabPath, _child.scene_file_path)
				break
	if _prefab_path != "":
		# The prefab-root thing's LABEL is what the server derives from the
		# addressable ADDRESS as `_xs_pf_<address>` (XScapeSystem.cpp:226/235), where
		# address is the catalog address = scene_path without ".tscn". The
		# `_xs_prefab_root_link#edge::_xs_prefabs` edge resolves only if this column
		# carries that exact label — so build it from the ADDRESS, not the normalized
		# prefab path (which strips `Assets/` and diverges for AMB). For TestSite the
		# address equals the derived prefab base, so this stays byte-identical there.
		prefabRoot = "_xs_pf_%s" % [scene_path.replace(".tscn", "")]

	# Only export nodes with useThingLink enabled (matches Unity: skip non-ThingLink nodes).
	# Nodes with only useLayers (Doors, Floors, Walls) have AxNode3D but no ThingLink data.
	if node is AxoNode3d and (node as AxoNode3d).useThingLink:
		var tn : AxoNode3d = node
		if( indent_level != 1 ):
			last_parent = get_parent_for(tn, last_parent)
			if( last_parent == null):
				push_error("Error: last parent is null for node: %s"%[tn.name])
				return false
			partOfInstanceLabel = last_parent.ThingInstanceLabel;
		# Always use ThingInstanceLabel as CSV label so children's partOf
		# references match. In Unity root ThingInstanceLabel == o.name, but
		# with ThingLabelOverride they can differ (e.g. url-safe lowercase).
		if tn.ThingInstanceLabel != "":
			label = tn.ThingInstanceLabel

		var thingName:String
		if( tn.ThingNameOverride != "" ):
			thingName = tn.ThingNameOverride ;
		else:
			if( !label.ends_with("==") ):
				thingName = label ;
			else:
				thingName = tn.name;
		var active: String = "0"
		if(tn.visible):
			active = "1"

		var transform_str:String     = addq(str(current_global_pos))
		# Repair/derive the `_xs_prefab` address (XSG-59 G4). See normalize_prefab_address.
		var local_prefabPath: String = normalize_prefab_address(tn.PrefabPath, tn.scene_file_path)


		var local_prefabGUID: String = tn.ThingGuid
		var values_str: String       = "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s"%[
			addq(label),
			addq(thingName),
			active,
			addq(partOfInstanceLabel),
			addq(tn.PhysicalType),
			addq(local_prefabPath),
			addq(prefabRoot),
			addq(prefabRoot),
			transform_str,
			local_prefabGUID,
			addq(export_type)
		];
		print_verbose("XFab_export_node to write to file %s"%[node.name])

		file_out.store_line(values_str)
		max_elements = max_elements + 1
		if max_elements > 100000:
			push_error("XFab_export_node: ThingLink row limit (100000) reached — aborting")
			return false


	# Recursively print information for all children
	var allc = node.get_children(false)
	for child in allc:
		XFab_export_node(child, indent_level + 1, file_out, last_parent, root_node, export_type, current_global_pos, scene_path)
	
	return true
func ensure_directory_exists2(path: String, cut_file_part: bool = false) -> void:
	# Fail early if backslashes are passed - use forward slashes everywhere
	if path.contains("\\"):
		push_error("Path contains backslashes - use forward slashes for cross-platform compatibility: " + path)
		return
	
	# Split the path into parts
	var parts: PackedStringArray = path.split("/")
	# Linux/macOS absolute paths start with "/" — splitting yields an empty
	# leading segment which the loop skips, dropping the leading slash and
	# turning the path into a relative one. Preserve it explicitly here.
	var current_path: String     = "/" if path.begins_with("/") else ""

	# Calculate how many parts to process
	var parts_to_process: int = parts.size()
	if cut_file_part:
		parts_to_process -= 1  # Skip the last part if it's a filename

	# Iterate through path parts to create directories
	for i in range(parts_to_process):
		if parts[i].is_empty():
			continue

		if i == 0 and parts[i].ends_with(":"):  # Handle Windows drive letter
			current_path = parts[i] + "/"
			continue
			
		current_path += parts[i] + "/"
		
		# Create directory if it doesn't exist
		if not DirAccess.dir_exists_absolute(current_path):
			var err: int = DirAccess.make_dir_absolute(current_path)
			if err != OK:
				push_error("Failed to create directory: " + current_path + " Error: " + str(err))
				return

## Hidden nodes without TimeState; warns on export.
func _collect_non_timestate_hidden_nodes(node: Node, results: Array) -> void:
	if node is Node3D and not (node as Node3D).visible:
		var has_timestate := false
		if node is AxoNode3d:
			var ax := node as AxoNode3d
			has_timestate = ax.useTimeState or ax.useTimeStateManager
		if not has_timestate:
			results.append(node.name)
	for child in node.get_children():
		_collect_non_timestate_hidden_nodes(child, results)

func XFabExporter_geometry(build_target, scene_path: String, scene_root):

	var project_name = ProjectSettings.get_setting("application/config/name")
	var version = ProjectSettings.get_setting("application/config/version")
	var axo_project_name = ProjectSettings.get_setting("xbase_plugin/settings/project_name")
	var axo_company_name = ProjectSettings.get_setting("xbase_plugin/settings/company_name")
	var axo_version = ProjectSettings.get_setting("xbase_plugin/settings/version")
	if axo_version == null or str(axo_version).strip_edges() == "":
		axo_version = "0.0.0"

	var target_export_dir: String = "%s/xScape/Addressables/%s/%s/%s/%s" % [xScape_ProgramData_Dir, axo_company_name, axo_project_name, axo_version, build_target]
	var csv_path: String          = scene_path.replace(".tscn", ".glb") # changing scene extension to csv
	var thinglink_path: String    = "%s/%s" % [target_export_dir, csv_path]
	
	if scene_root:
		var gltf_scene_root_node = scene_root
		var gltf_path: String    = thinglink_path
		print("XFabExporter_geometry %s exporting to %s" % [scene_root.name, gltf_path])
		ensure_directory_exists2(gltf_path, true)

		var disable_extras: bool = exportDisableExtrasCheck != null and exportDisableExtrasCheck.button_pressed

		var gltf_document_save := GLTFDocument.new()
		gltf_document_save.visibility_mode = GLTFDocument.VISIBILITY_MODE_INCLUDE_OPTIONAL
		var axo_ext = axo_gltfex_pr.new()
		if not disable_extras:
			gltf_document_save.register_gltf_document_extension(axo_ext)
		else:
			print("  Extras DISABLED — exporting raw GLB without ThingLink/Layer/Edge components")

		# Hidden non-TimeState nodes default to visible in Unity/Blender.
		var hidden_nodes: Array = []
		_collect_non_timestate_hidden_nodes(gltf_scene_root_node, hidden_nodes)
		if not hidden_nodes.is_empty():
			push_warning(
				"[xbase_plugin] VISIBILITY_MODE_INCLUDE_OPTIONAL: %d hidden node(s) have no TimeState component and will appear VISIBLE in Unity/Blender: %s" % [
					hidden_nodes.size(), ", ".join(hidden_nodes)
				]
			)

		var t0 = Time.get_ticks_msec()
		var gltf_state_save := GLTFState.new()
		gltf_state_save.create_animations = false  # Building scenes have no animations
		gltf_document_save.append_from_scene(gltf_scene_root_node, gltf_state_save)
		var t1 = Time.get_ticks_msec()

		# Log payload stats to help identify hidden costs
		print("  GLTFState payload: nodes=%d, meshes=%d, materials=%d, textures=%d, images=%d, animations=%d" % [
			gltf_state_save.get_nodes().size(),
			gltf_state_save.get_meshes().size(),
			gltf_state_save.get_materials().size(),
			gltf_state_save.get_textures().size(),
			gltf_state_save.get_images().size(),
			gltf_state_save.get_animations().size()])

		gltf_document_save.write_to_filesystem(gltf_state_save, gltf_path)

		# sha256 sidecar — parity with the PCK sidecar in XFabExporter_pck:
		# runtime clients (WebPackLoader via glb_loader.load_and_instantiate_async)
		# verify downloaded bytes against this before mounting; also embedded in
		# catalog_default.json as glb_sha256.
		var glb_sha: String = FileAccess.get_sha256(gltf_path)
		var glb_sha_file := FileAccess.open(gltf_path + ".sha256", FileAccess.WRITE)
		if glb_sha_file:
			glb_sha_file.store_string(glb_sha)
			glb_sha_file.close()
		else:
			push_warning("XFabExporter_geometry: could not write sha256 sidecar for %s" % gltf_path)

		var t2 = Time.get_ticks_msec()
		print("  Export timing: append_from_scene=%dms, write_to_filesystem=%dms, total=%dms, extras=%s, sha256=%s.." % [t1 - t0, t2 - t1, t2 - t0, "off" if disable_extras else "on", glb_sha.substr(0, 12)])
		# Brotli sidecar next to the finalized .glb (parity with the .sha256 above).
		_emit_brotli_sidecar(gltf_path)
	else:
		push_error("XFabExporter_geometry What is this scene_root? %s"%[scene_root.name])

## Extracts the `res://` path from a single ResourceLoader.get_dependencies() entry.
##
## Pure/static so it can be unit-tested in isolation (see tests/test_runner.gd
## _test_extract_dep_res_path). get_dependencies() returns entries in one of two
## shapes depending on how the referencing scene stored the ext_resource:
##   * legacy form     "res://path/to/dep.tres::TypeHint"   (slice 0 is the path)
##   * Godot 4.6 UID   "uid://HASH::TypeHint::res://path/to/dep.tres"
## The old code did `get_slice("::", 0)` which took the `uid://HASH` prefix for
## the UID form, so `begins_with("res://")` failed and the dependency (and its
## whole subtree) was silently dropped — producing a broken 1-file PCK for any
## scene whose deps are stored as UIDs. We instead scan every `::`-delimited
## segment and return the first that starts with `res://`, which handles BOTH
## shapes (and a bare `res://path` with no `::`). Returns "" when there is no
## `res://` segment (e.g. an unresolvable `uid://HASH::Type`), so the caller
## drops it exactly as before — there is no disk path to pack in that case.
static func extract_dep_res_path(dep: String) -> String:
	for segment in dep.split("::"):
		if segment.begins_with("res://"):
			return segment
	return ""

## Repairs / derives the `_xs_prefab` address written to the ThingLink CSV.
##
## Pure/static so it can be unit-tested in isolation (see tests/test_runner.gd
## _test_normalize_prefab_address). Fixes XSG-59 G4, whose root cause is the
## Unity-side XSC-260 bug: ThingLink.GetRelativePrefabPath does
## `prefabPath.Substring("/Assets".Length)` (7 chars) unconditionally, so
## `Packages/io.axomem...` lost its 7-char `Package` prefix and was baked into
## the imported .tscn as `s/io.axomem...`. Two branches:
##
##  * DERIVE (raw != "" AND scene_file_path != ""): the node is the root of an
##    instanced sub-scene, so its on-disk path is the authoritative address.
##    Strip `res://`, a leading `Assets/` (Unity addresses are relative to the
##    project Assets root), and the `.prefab`/`.tscn` extensions. `res://Packages/...`
##    keeps its `Packages/` prefix. This reproduces the clean authored value for
##    correctly-imported Assets prefabs AND corrects the mangled Packages ones.
##    We DO NOT derive when raw == "" — an empty PrefabPath means "not a
##    prefab-root address holder"; deriving there would populate `_xs_prefab`
##    on plain instanced children (e.g. TestSite Bed.tscn units) that must stay
##    blank, breaking the byte-identical TestSite export.
##
##  * REPAIR (no scene_file_path, or empty raw): repair the authored value in
##    place. Prepend `Package` to any `s/...` value (exact inverse of the 7-char
##    over-strip). Also drop a trailing `.prefab`/`.tscn` if the authored value
##    carried one. Otherwise return unchanged (clean `amb/Prefabs/...` values
##    pass through untouched).
static func normalize_prefab_address(raw: String, scene_file_path: String) -> String:
	if raw != "" and scene_file_path != "":
		var p: String = scene_file_path.trim_prefix("res://").trim_prefix("Assets/")
		p = p.trim_suffix(".tscn").trim_suffix(".prefab")
		return p
	var out: String = raw
	if out.begins_with("s/"):
		out = "Package" + out
	out = out.trim_suffix(".tscn").trim_suffix(".prefab")
	return out

## Recursively collects all resource dependencies for a scene file.
func _collect_scene_dependencies(res_path: String, collected: Dictionary) -> void:
	if collected.has(res_path):
		return
	collected[res_path] = true
	var deps: PackedStringArray = ResourceLoader.get_dependencies(res_path)
	for dep in deps:
		# Robustly pull the `res://` path out of the dependency entry (handles
		# both the legacy "res://path::Type" and the Godot 4.6 UID
		# "uid://HASH::Type::res://path" forms). See extract_dep_res_path.
		var clean_dep: String = extract_dep_res_path(dep)
		if clean_dep != "":
			_collect_scene_dependencies(clean_dep, collected)

## Exports a scene (and everything Godot's exporter resolves for it) as a .pck.
##
## Production is delegated to Godot's NATIVE export-pack via a subprocess (see
## export_preset_pack.gd) rather than a manual PCKPacker: only the native path
## ships the imported binaries (`.godot/imported/*.ctex`) and `.import` remaps,
## so texture-bearing scenes no longer render FLAT once the pack is mounted
## (XSG-59 G3). The exclude_filter in that preset strips runtime scripts from
## the pack (supply-chain RESTRICT — see docs/pck_supply_chain.md); the guard
## log below enumerates exactly what gets stripped.
##
## Contract unchanged: `-> void`, push_error() on failure (XFabExporter does
## not increment export_errors for pck; the site/consumer gates catch a missing
## pck). We do NOT silently fall back to PCKPacker — a silent fallback would
## resurrect the flat-texture bug.
func XFabExporter_pck(build_target: String, scene_path: String) -> void:
	var axo_company_name = ProjectSettings.get_setting("xbase_plugin/settings/company_name")
	var axo_project_name = ProjectSettings.get_setting("xbase_plugin/settings/project_name")
	var axo_version = ProjectSettings.get_setting("xbase_plugin/settings/version")
	if axo_version == null or str(axo_version).strip_edges() == "":
		axo_version = "0.0.0"

	var target_export_dir: String = "%s/xScape/Addressables/%s/%s/%s/%s" % [xScape_ProgramData_Dir, axo_company_name, axo_project_name, axo_version, build_target]
	var pck_rel_path: String = scene_path.replace(".tscn", ".pck")
	var pck_path: String = "%s/%s" % [target_export_dir, pck_rel_path]

	print("XFabExporter_pck exporting %s to %s" % [scene_path, pck_path])
	ensure_directory_exists2(pck_path, true)

	var t0 = Time.get_ticks_msec()
	var res_path: String = "res://" + scene_path

	# Supply-chain AUDIT TRAIL: scripts SHIP in packs (owner decision — binary
	# scenes require their script deps present; see export_preset_pack.gd and
	# docs/pck_supply_chain.md). Log every script dep so each pack's executable
	# content is visible in export output until XSG-60's selective
	# stripping/gating lands. _collect_scene_dependencies is retained for
	# exactly this guard (and its unit test).
	var collected: Dictionary = {}
	_collect_scene_dependencies(res_path, collected)
	var script_deps: Array[String] = []
	for dep in collected:
		if dep.ends_with(".gd") or dep.ends_with(".cs"):
			script_deps.append(dep)
	if not script_deps.is_empty():
		print("XFabExporter_pck: pack ships %d script dep(s) (unsupported/at-your-own-risk, see docs/pck_supply_chain.md): %s" %
				[script_deps.size(), ", ".join(script_deps)])

	# Resolve the Godot export platform for this label. Unknown labels fail
	# loud but we keep exporting on "Web" — import remapping (the reason this
	# path exists) is platform-agnostic for our scene payloads.
	var platform: String = ExportProfiles.godot_export_platform(build_target)
	if platform == "":
		push_warning("XFabExporter_pck: unknown build target '%s' — falling back to Web platform" % build_target)
		platform = "Web"

	var project_dir_abs: String = ProjectSettings.globalize_path("res://").simplify_path()
	var err: int = ExportPresetPack.export_scene_pack(res_path, platform, pck_path, project_dir_abs)
	if err != OK:
		push_error("XFabExporter_pck: export-pack failed for %s (error %d)" % [scene_path, err])
		return

	# sha256 sidecar — runtime clients (WebPackLoader) verify downloaded bytes
	# against this before mounting; also embedded in catalog_default.json.
	var sha: String = FileAccess.get_sha256(pck_path)
	var sha_file := FileAccess.open(pck_path + ".sha256", FileAccess.WRITE)
	if sha_file:
		sha_file.store_string(sha)
		sha_file.close()
	else:
		push_warning("XFabExporter_pck: could not write sha256 sidecar for %s" % pck_path)

	var t1 = Time.get_ticks_msec()
	print("  PCK exported: %dms, sha256=%s.., path=%s" % [t1 - t0, sha.substr(0, 12), pck_path])
	# Brotli sidecar next to the finalized .pck (parity with the .sha256 above).
	# Only reached on export_scene_pack success (the err!=OK path returned early).
	_emit_brotli_sidecar(pck_path)

func create_xwab_json(build_target: String, exportable_scenes: Dictionary, export_type: String) -> void:
	# Create JSON data structure
	var axo_company_name = ProjectSettings.get_setting("xbase_plugin/settings/company_name")
	var axo_project_name = ProjectSettings.get_setting("xbase_plugin/settings/project_name")
	var axo_version = ProjectSettings.get_setting("xbase_plugin/settings/version")
	if axo_version == null or str(axo_version).strip_edges() == "":
		axo_version = "0.0.0"

	var json_data: Dictionary = {
		"Company": axo_company_name,
		"Product": axo_project_name,
		"Version": axo_version,
		"RelativeBundleRoot": "%s/%s/%s" % [axo_company_name, axo_project_name, axo_version],
		"CatalogPath": "{Axomem.XScape.Core.Addressables.RemoteLoadPrefix}/%s/%s/%s/%s/catalog_default.json" % [axo_company_name, axo_project_name, axo_version, build_target],
		"Addresses": [],
		"Format": export_type
	}
	
	# Add scene addresses
	for scene_path in exportable_scenes:
		json_data.Addresses.append({
			"Address": scene_path.replace(".tscn", ""),
			"Guid": exportable_scenes[scene_path]
		})
	
	# Save JSON to file
	var json_string: String   = JSON.stringify(json_data, "  ")
	var json_filename: String = "xwab__%s__%s.json" % [axo_company_name.replace(" ", "_"), axo_project_name.replace(" ", "_")]

	var json_path: String = xScape_ProgramData_Dir + "/xScape/Addressables/" + json_filename
	
	var file: FileAccess = FileAccess.open(json_path, FileAccess.WRITE)
	if file:
		file.store_string(json_string)
		file.close()
		print("create_xwab_json XWAB file created at: " + json_path)
	else:
		push_error("Failed to create XWAB JSON file at: " + json_path)

## Writes catalog_default.json for the build target. Beyond the legacy
## {"format": ...} stub, each exported address gets an entry with its
## artifact filenames, sha256 and size so runtime clients can build download
## URLs and verify bytes (Godot WebPackLoader). Unity's loader ignores the
## extra keys — its catalogs are the binary Addressables ones — so the richer
## shape is backwards-compatible on the shared CDN layout.
func create_catalog_file(build_target: String, export_type: String, exportable_scenes: Dictionary = {}) -> void:

	var target_dir := "%s/xScape/Addressables/%s/%s/%s/%s" % [
		xScape_ProgramData_Dir,
		ProjectSettings.get_setting("xbase_plugin/settings/company_name"),
		ProjectSettings.get_setting("xbase_plugin/settings/project_name"),
		ProjectSettings.get_setting("xbase_plugin/settings/version"),
		build_target
	]
	var catalog_path := "%s/catalog_default.json" % target_dir

	var addresses: Array = []
	for scene_path in exportable_scenes:
		var address: String = scene_path.replace(".tscn", "")
		var entry: Dictionary = {"address": address}
		var pck_rel: String = scene_path.replace(".tscn", ".pck")
		var pck_abs: String = "%s/%s" % [target_dir, pck_rel]
		if FileAccess.file_exists(pck_abs):
			entry["pck"] = pck_rel
			entry["sha256"] = FileAccess.get_sha256(pck_abs)
			var pf := FileAccess.open(pck_abs, FileAccess.READ)
			if pf:
				entry["size"] = pf.get_length()
				pf.close()
		var glb_rel: String = scene_path.replace(".tscn", ".glb")
		var glb_abs: String = "%s/%s" % [target_dir, glb_rel]
		if FileAccess.file_exists(glb_abs):
			entry["glb"] = glb_rel
			entry["glb_sha256"] = FileAccess.get_sha256(glb_abs)
			var gf := FileAccess.open(glb_abs, FileAccess.READ)
			if gf:
				entry["glb_size"] = gf.get_length()
				gf.close()
		addresses.append(entry)

	var catalog: Dictionary = {
		"format": export_type,
		"build_target": build_target,
		"profile": ExportProfiles.resolve(build_target),
		"addresses": addresses,
	}

	var file := FileAccess.open(catalog_path, FileAccess.WRITE)
	if file:
		if not file.store_string(JSON.stringify(catalog, "  ")):
			push_error("Failed to write to file: %s" % catalog_path)
		file.close()
		print("create_catalog_file Catalog file created at: %s (%d address entries)" % [catalog_path, addresses.size()])
	else:
		push_error("Failed to create Catalog JSON file at: " + catalog_path)
	
## Returns the number of scenes that failed export (0 = all OK).
func XFabExporter() -> int:
	var build_target: String = get_build_target_from_command_line()
	if build_target.is_empty():
		# Retired target (see RetiredPlatformIds) — clean no-op, zero artifacts.
		print("XFabExporter: retired build target — nothing to export (no-op).")
		return 0
	# Labels are the CI contract; the profile is what asset decisions key off
	# (see export_profiles.gd + xScape docs/export_targets_alignment.md).
	var asset_profile: String = ExportProfiles.resolve(build_target)
	print("XFabExporter starting for build target %s (asset profile: %s)" % [build_target, asset_profile])
	# Probe brotli once up front; per-artifact sidecars are emitted after each
	# .glb / .pck is finalized (alongside the sha256 sidecars).
	_brotli_setup_for_run()
	var export_errors: int = 0
	
	var exportable_scenes: Dictionary = get_exportable_scenes()

	# Filter to specific scenes if restrict_to_scenes is set (headless --scene flag)
	if not restrict_to_scenes.is_empty():
		var filtered: Dictionary = {}
		for scene_path in exportable_scenes:
			if scene_path in restrict_to_scenes or ("res://" + scene_path) in restrict_to_scenes:
				filtered[scene_path] = exportable_scenes[scene_path]
		print("Filtered to %d scenes (from %d exportable)" % [filtered.size(), exportable_scenes.size()])
		exportable_scenes = filtered

	# Filter to only open scenes if checkbox is checked
	var export_open_only: bool = exportOpenOnlyCheck != null and exportOpenOnlyCheck.button_pressed
	if export_open_only:
		var open_scenes: PackedStringArray = EditorInterface.get_open_scenes()
		var filtered: Dictionary = {}
		for scene_path in exportable_scenes:
			var res_path: String = "res://" + scene_path
			if res_path in open_scenes:
				filtered[scene_path] = exportable_scenes[scene_path]
		print("Filtering to %d open scenes (from %d exportable)" % [filtered.size(), exportable_scenes.size()])
		exportable_scenes = filtered

	for scene_path in exportable_scenes:
		print("  Exportable scene: " + scene_path)
	
	var axo_company_name_chk = ProjectSettings.get_setting("xbase_plugin/settings/company_name")
	var axo_project_name_chk = ProjectSettings.get_setting("xbase_plugin/settings/project_name")
	var axo_version_chk = ProjectSettings.get_setting("xbase_plugin/settings/version")
	if axo_version_chk == null or str(axo_version_chk).strip_edges() == "":
		axo_version_chk = "0.0.0"

	var skip_existing: bool = exportSkipExistingCheck != null and exportSkipExistingCheck.button_pressed
	# headless_skip_glb / headless_export_pck take precedence so headless
	# runners can drive both flags regardless of UI state (the dock isn't
	# built in headless). GLB and PCK are independent — emit either, both,
	# or neither (CSV-only).
	var skip_glb: bool = headless_skip_glb \
		or (exportSkipGlbCheck != null and exportSkipGlbCheck.button_pressed)
	var export_pck: bool = headless_export_pck \
		or (exportAsPckCheck != null and exportAsPckCheck.button_pressed)
	if skip_glb:
		print("Skip GLB mode — no GLB geometry written")
	if export_pck:
		print("PCK export ON — emitting scene .pck per scene")

	# CSV `_xs_prefab_type` and the xwab/catalog Format fields advertise the
	# runtime-load format. PCK takes precedence when both PCK and GLB are
	# emitted, since the PCK path is the runtime client loader.
	var export_type: String = "pck" if export_pck else "xfabglx"

	for scene_path in exportable_scenes:
		# Skip already-exported scenes if checkbox is checked. With independent
		# GLB/PCK flags, "already exported" means whichever artifact would
		# otherwise be produced this run is already on disk. Prefer the GLB as
		# the canonical marker when both are produced.
		if skip_existing:
			var check_ext: String
			if not skip_glb:
				check_ext = ".glb"
			elif export_pck:
				check_ext = ".pck"
			else:
				check_ext = ""  # CSV-only run; never skip
			if check_ext != "":
				var check_path: String = "%s/xScape/Addressables/%s/%s/%s/%s/%s" % [
					xScape_ProgramData_Dir, axo_company_name_chk, axo_project_name_chk,
					axo_version_chk, build_target, scene_path.replace(".tscn", check_ext)]
				if FileAccess.file_exists(check_path):
					print("  Skipping (already exported): " + scene_path)
					continue

		print("Processing exportable scene: " + scene_path)

		# Load the scene resource — CACHE_MODE_REPLACE forces re-read from disk
		# so that changes saved by sync_am_thinglink are picked up immediately.
		# Synchronous load on purpose: load_threaded_request(use_sub_threads=true)
		# intermittently corrupted RIDs on large scenes ("Attempting to initialize
		# the wrong RID"), crashing later in scene_instance.free() — and the old
		# code blocked on load_threaded_get immediately anyway, so threading
		# bought nothing.
		var scene: Resource = ResourceLoader.load("res://"+scene_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if scene:
			#
			var scene_instance = scene.instantiate() # Instantiate the scene
			if scene_instance:
				var root_node = scene_instance
				if(root_node is AxoNode3d):
					var tn: AxoNode3d = root_node as AxoNode3d
					exportable_scenes[scene_path] = tn.ThingGuid
				XFabExporter_file(build_target, scene_path, root_node, export_type)

				# Validate instance labels before export — abort this scene if stale
				var label_errors = AxNode3D.validate_instance_labels(root_node)
				if label_errors > 0:
					push_error("Export aborted for '%s': %d ThingInstanceLabel errors. Run RecalculateInstanceLabels and save before exporting." % [scene_path, label_errors])
					export_errors += 1
					scene_instance.free()
					continue

				# GLB + PCK are independent — emit whichever flags request.
				if not skip_glb:
					XFabExporter_geometry(build_target, scene_path, root_node)
				if export_pck:
					XFabExporter_pck(build_target, scene_path)

				# Immediate free, not queue_free(): the headless runner
				# (xBaseHeadless.gd) does all work in _init() and quit()s before
				# the main loop ever processes a frame, so queued frees never
				# run — every instance leaks and Godot crashes at exit trying
				# to tear down the dangling physics state.
				scene_instance.free() # Clean up
			else:
				push_error("Failed to load scene: res://" + scene_path)
		else:
			push_error("Failed to load scene: " + scene_path)

	create_xwab_json(build_target, exportable_scenes, export_type)
	create_catalog_file(build_target, export_type, exportable_scenes)
	if export_errors > 0:
		push_error("XFabExporter completed with %d scene(s) failed for build target %s" % [export_errors, build_target])
	else:
		print("XFabExporter completed successfully for build target %s" % build_target)
	return export_errors

# Modified to accept scene_instance parameter.
# export_type is passed through to XFab_export_node for the
# `_xs_prefab_type` CSV column ("pck" or "xfabglx").
func XFabExporter_file(build_target: String, scene_path: String, inp_scene_root: Node, export_type: String):
	print("XFabExporter_file Starting with build target %s" % build_target)
	var project_name = ProjectSettings.get_setting("application/config/name")
	var version = ProjectSettings.get_setting("application/config/version")
	var axo_project_name = ProjectSettings.get_setting("xbase_plugin/settings/project_name")
	var axo_company_name = ProjectSettings.get_setting("xbase_plugin/settings/company_name")
	var axo_version = ProjectSettings.get_setting("xbase_plugin/settings/version")
	if axo_version == null or str(axo_version).strip_edges() == "":
		axo_version = "0.0.0"

	print("XFabExporter_file: Project name: %s, version: %s, axo_project_name: %s, axo_version: %s, build_target: %s"%[project_name, version, axo_project_name, axo_version, build_target])
	print("XFabExporter_file: Scene path: %s"%[inp_scene_root.scene_file_path])

	var target_export_dir: String = "%s/xScape/Addressables/%s/%s/%s/%s/ThingLink" % [xScape_ProgramData_Dir, axo_company_name, axo_project_name, axo_version, build_target]

	print("Creating output directory: %s"%[target_export_dir])
	ensure_directory_exists2(target_export_dir, false)

	print("Printing node information:" + 	target_export_dir)
	#todo in Addressabless create .json
	max_elements = 0
	var editor_interface: EditorInterface = get_editor_interface()
	# var scene_root = editor_interface.get_edited_scene_root()
	print("ThingLink csv...")
	var csv_path: String       = scene_path.replace(".tscn", "/tl_things.csv") # changing scene extension to csv
	var thinglink_path: String = "%s/%s" % [target_export_dir, csv_path]
	ensure_directory_exists2(thinglink_path, true)
	print("ThingLink path: %s" % [thinglink_path])

	# Recursively print information for all children
	if inp_scene_root:

		ValidateInstanceLabels(inp_scene_root, true)

		var file_out_path: String = thinglink_path
		print_verbose("Saving to file:" + file_out_path)
		var save_file: FileAccess = FileAccess.open(file_out_path, FileAccess.WRITE)
		if !save_file:
			push_error("Failed to open file for writing: " + file_out_path)
			return
		
		print_verbose("    file opened")
		save_file.store_csv_line(["label","name","active","partOf#edge::Location","physicalType#edge::valueset-location-physical-type","_xs_prefab","_xs_prefab_root_link#edge::_xs_prefabs","_xs_prefab_root","transform_position","glbs_guid","_xs_prefab_type"],",")
		print_verbose("    csv line written")
		
		if XFab_export_node(inp_scene_root, 1, save_file, null, inp_scene_root, export_type, Vector3.ZERO, scene_path):
			print_verbose("    XFab_export_node completed successfully")
		else:
			push_error("    XFab_export_node encountered errors")
		
		save_file.close()
		print_verbose("    file closed")

		# --- Edge instances CSV ---
		# Emit the edges file as `tl1_edges.csv` (the server's edge-file naming
		# convention). The xbase server's activate_prefab_from_addressable
		# (XScapeSystem.cpp:256-272) feeds the FIRST `tl_*`/`tl0*` .csv the directory
		# iterator yields to the THINGS loader, and only `tl1*` .csv files to the
		# EDGES loader. A `tl_edges.csv` matches the `tl_` things prefix and — on
		# filesystems where it sorts before `tl_things.csv` — gets loaded AS things
		# and throws. `tl1_edges.csv` routes to the edges loader and never shadows
		# the things file. We also still only write the file when there is at least
		# one row (XSG-59 G8), so a 0-edge scene leaves no stray edge file.
		var edge_rows: Array = []
		_collect_edge_instances(inp_scene_root, edge_rows)
		if edge_rows.is_empty():
			print("  No edge instances found in scene (tl1_edges.csv skipped)")
		else:
			var edge_csv_path: String = scene_path.replace(".tscn", "/tl1_edges.csv")
			var edge_file_path: String = "%s/%s" % [target_export_dir, edge_csv_path]
			ensure_directory_exists2(edge_file_path, true)

			var edge_file: FileAccess = FileAccess.open(edge_file_path, FileAccess.WRITE)
			if edge_file:
				edge_file.store_line("edge,vertex1_label,vertex2_label")
				for edge_row in edge_rows:
					edge_file.store_line(edge_row)
				edge_file.close()
				print("  Exported %d edge instances to: %s" % [edge_rows.size(), edge_file_path])
			else:
				push_error("Failed to open edge file for writing: " + edge_file_path)
	else:
		push_warning("XFabExporter_file No scene root found.")


# Appends `"edge","v1","v2",value` rows for every edge instance in the subtree
# to `rows_out` (does NOT touch any file — the caller decides whether to write,
# so a scene with 0 edges leaves no header-only tl_edges.csv behind; XSG-59 G8).
# Returns the number of rows appended.
func _collect_edge_instances(node: Node, rows_out: Array) -> int:
	var count: int = 0
	if node is AxoNode3d and (node as AxoNode3d).useEdgeInstances:
		var ax: AxoNode3d = node as AxoNode3d
		var edge_count: int = mini(ax.EdgeVertex1.size(), ax.EdgeVertex2.size())
		for i in range(edge_count):
			var v1 = node.get_node_or_null(ax.EdgeVertex1[i])
			var v2 = node.get_node_or_null(ax.EdgeVertex2[i])
			var edge_type: String = ax.EdgeInstanceTypes[i] if i < ax.EdgeInstanceTypes.size() else ax.Edges if ax.Edges.length() > 0 else "None"
			var edge_value: int = ax.EdgeInstanceValues[i] if i < ax.EdgeInstanceValues.size() else 0
			if v1 == null or not (v1 is AxoNode3d):
				push_error("Edge on '%s' [%d]: Vertex1 does not resolve to AxNode3D" % [node.name, i])
			elif not (v1 as AxoNode3d).useThingLink:
				push_error("Edge on '%s' [%d]: Vertex1 '%s' does not have useThingLink" % [node.name, i, v1.name])
			elif v2 == null or not (v2 is AxoNode3d):
				push_error("Edge on '%s' [%d]: Vertex2 does not resolve to AxNode3D" % [node.name, i])
			elif not (v2 as AxoNode3d).useThingLink:
				push_error("Edge on '%s' [%d]: Vertex2 '%s' does not have useThingLink" % [node.name, i, v2.name])
			else:
				var v1_label: String = (v1 as AxoNode3d).ThingInstanceLabel
				var v2_label: String = (v2 as AxoNode3d).ThingInstanceLabel
				rows_out.append('"%s","%s","%s",%d' % [edge_type, v1_label, v2_label, edge_value])
				count += 1
	for child in node.get_children(false):
		count += _collect_edge_instances(child, rows_out)
	return count


func ValidateInstanceLabels(scene_root: Node3D, resetLabel:bool = false) -> void: ## Sets labels in nested nodes, on each node SetInstanceLabel() is called
	if( scene_root is AxoNode3d):
		var tn: AxoNode3d = scene_root as AxoNode3d
		if tn.ThingGuid.is_empty():
			tn.ThingGuid = make_guid()
			
	for child in scene_root.get_children():
		ValidateInstanceLabelInNode(child, scene_root, resetLabel)

# this is for single node
func ValidateInstanceLabelInNode(single_node: Node, scene_root: Node3D, resetLabel:bool = false) -> bool: ## Sets labels in nested nodes, on each node SetInstanceLabel() is called
	# A scene root can hold non-Node3D children (e.g. WorldEnvironment, which
	# extends Node, not Node3D). Those carry no ThingLink data, so return "clean"
	# without touching any Node3D-only state. The param was previously typed
	# Node3D, so passing a WorldEnvironment threw "not a subclass of the expected
	# argument class" once per AMB scene export (XSG-59 straggler a). Matching the
	# prior traversal, we skip the whole (non-Node3D) subtree.
	if not (single_node is Node3D):
		return true
	# iterate over all children
	   # if child is not ThingLink - skip (but do we don't goo deeper ?)
	var clean: bool = true;
	if( single_node is AxoNode3d && single_node.visible == true): #if (!o.activeSelf) return; +  if (!o.TryGetComponent<ThingLink>(out var thingLink)) return;
		var tn: AxoNode3d = single_node as AxoNode3d
		if tn.ThingGuid.is_empty():
			tn.ThingGuid = make_guid()
		var tnparent: Node = tn.get_parent()
		if ( tnparent == null ): # if (o.transform.parent == null)
			if( tn.ThingInstanceLabel == tn.name && resetLabel == false):
				pass # if (thingLink.ThingInstanceLabel == o.name && resetLabel == false) return;
			else:
				tn.ThingInstanceLabel = tn.name #thingLink.ThingInstanceLabel = o.name;
				clean = false # clean = false;
		else: # in other words if( tnparent != null )
			if( tn.ThingInstanceLabel != "" && resetLabel == false): # if (thingLink.ThingInstanceLabel != "" && resetLabel == false) return;
				pass
			else:
				clean = SetInstanceLabel(scene_root, tn) # clean = SetInstanceLabel(go, thingLink);
	else:
		pass

	# run this method for all children
	for child in single_node.get_children():
		ValidateInstanceLabelInNode(child, scene_root, resetLabel)
	
	return clean

func make_guid() -> String:
	var random = RandomNumberGenerator.new()
	random.randomize()
	var guid:String = ""
	for i in range(32):
		guid += "%x"%[random.randi() % 16]
	_log_verbose("Generating GUID for node named: %s. GUID: %s"%[self.name,guid])
	return guid

func SetInstanceLabel(scene_root: Node3D, thing_link: AxoNode3d) -> bool: 
	var dbgmsg: String = "Node Instance label: "+ thing_link.name + ":"
	var is_clean: bool = true 
	if thing_link.ThingLabelOverride == "": 
		if thing_link.ThingInstanceLabel == "": 
			thing_link.ThingInstanceLabel = make_guid() # base64_encode(UtilityFunctions.uuid_generate())  #this seem not used
			print_verbose("Set new Instance Label for %s: %s" % [thing_link.name, thing_link.ThingInstanceLabel]) 
			is_clean = false 
	else: 
		var target_string: String = "" 
		if thing_link.ThingLabelOverride.begins_with("&"):  #if (thingLink.ThingLabelOverride.StartsWith("&"))
			var parent_tl: AxoNode3d = null 
			if thing_link.ParentOverride == null: 
				var tmp: Node = thing_link.get_parent()
				if tmp is AxoNode3d:
					parent_tl = tmp as AxoNode3d
					dbgmsg+="case1:"
			else:
				parent_tl = thing_link.ParentOverride 
				dbgmsg+="case2:"
			
			var err: String = "" 
			if parent_tl == null: 
				err = "Unable to find any parent thingLinks for %s when using '&' in Label name %s." % [thing_link.name, thing_link.ThingLabelOverride] 
			elif parent_tl.ThingInstanceLabel.ends_with("=="): 
				err = "Unable to use parent thingLink instance label for '%s' when using '&' prefix for Label name because parent ThingLink instance '%s' label looks like a generated GUID: %s." % [thing_link.name, parent_tl.name, parent_tl.ThingInstanceLabel] 
			
			if err != "": 
				var path: String = "pff not-implemented"
				var msg: String  = "While exporting %s in path '%s', the following error occurred: %s Check hierarchy and/or run Recalculate Instance Label again" % [thing_link.name, path, err] 
				push_error(msg) 
				return false 
				
			var umpesandIdx: int   = thing_link.ThingLabelOverride.find( "&" ) + 1
			var label_part: String = thing_link.ThingLabelOverride.substr(umpesandIdx, -1)
			label_part = label_part.rstrip("'")
			target_string = parent_tl.ThingInstanceLabel + label_part 
			dbgmsg+="=1="+target_string
			
		else: 
			target_string = thing_link.ThingLabelOverride 
			dbgmsg+="=2="+target_string
		
		if thing_link.ThingInstanceLabel != target_string: 
			thing_link.ThingInstanceLabel = target_string 
			is_clean = false 
			dbgmsg+="=3="+target_string
				
	_log_verbose(dbgmsg)
	return is_clean

# SERIALIZE BUTTON
func serialized_button_pressed():
	print_verbose("serialized_button_pressed");
	#print ( sb.ge) 
	var editor_interface: EditorInterface = get_editor_interface()
	var scene_root: Node                  = editor_interface.get_edited_scene_root()
	print_node_info()

# SERIALIZE BUTTON
func load_from_server_pressed():
	print_verbose("load_from_server_pressed");
	#print ( sb.ge)
	var editor_interface: EditorInterface = get_editor_interface()
	var scene_root: Node                  = editor_interface.get_edited_scene_root()
	#print_node_info()

# SYNC AM AXNODE3D BUTTON
# CLEAR THING INSTANCE LABELS BUTTON
func clear_thing_instance_labels_pressed():
	print("Clear ThingInstance Labels button pressed")
	var editor_interface: EditorInterface = get_editor_interface()
	var scene_root: Node = editor_interface.get_edited_scene_root()
	if scene_root == null:
		push_warning("No scene open — nothing to clear.")
		return
	var count = _clear_thing_instance_labels_recursive(scene_root)
	print("Cleared ThingInstanceLabel and ThingGuid on %d nodes" % count)

func _clear_thing_instance_labels_recursive(node: Node) -> int:
	var count = 0
	if node is AxoNode3d and (node as AxoNode3d).useThingLink:
		var tl: AxoNode3d = node as AxoNode3d
		if tl.ThingInstanceLabel != "" or tl.ThingGuid != "":
			tl.ThingInstanceLabel = ""
			tl.ThingGuid = ""
			count += 1
	for child in node.get_children():
		count += _clear_thing_instance_labels_recursive(child)
	return count

func sync_am_thinglink_pressed():
	print("Sync AM AxNode3D button pressed")
	var sync = SyncAmThingLink.new()
	if syncAmOverrideCheck:
		sync.override_existing = syncAmOverrideCheck.button_pressed
	# Filter to open scenes only if checkbox is checked
	if syncOpenOnlyCheck and syncOpenOnlyCheck.button_pressed:
		var open_scenes: PackedStringArray = EditorInterface.get_open_scenes()
		sync.restrict_to_paths = Array(open_scenes)
		print("Filtering sync to %d open scenes" % open_scenes.size())
	sync.execute()
	# Refresh the filesystem to show changes
	var editor_interface: EditorInterface = get_editor_interface()
	editor_interface.get_resource_filesystem().scan()
	print("Sync complete - filesystem refreshed")

func add_thinglink_data_to_node_button_pressed():  # button caption: Add ThingLink to Node
	print_verbose("xbpressed")
	var editor_interface: EditorInterface = get_editor_interface()
	var scene_root: Node                  = editor_interface.get_edited_scene_root()
	if scene_root:
		var sel_nodes_array: Array[Node] = editor_interface.get_selection().get_selected_nodes()
		if( sel_nodes_array.size() > 0):
			var sel_node = sel_nodes_array.front()
			if(sel_node is AxoNode3d):
				print("Selected node already contains ThingLink data")
				var tn: AxoNode3d = sel_node as AxoNode3d
				if tn.ThingGuid.is_empty():
					tn.ThingGuid = make_guid()
			else:
				sel_node.set_script(AxoNode3d)
				var tn: AxoNode3d = sel_node as AxoNode3d
				if tn.ThingGuid.is_empty():
					tn.ThingGuid = make_guid()				
				
				
				
		else:
			print("No selected nodes !")
		
func add_node_button_pressed():
	print_verbose("xbpressed")
	
	var editor_interface: EditorInterface = get_editor_interface()
	var scene_root: Node                  = editor_interface.get_edited_scene_root()

	if scene_root:
		# Load and instance your scene
		var new_node: Node = load("res://room.tscn").instantiate()

		# Add the new node to the current scene
		scene_root.add_child(new_node)
		new_node.owner = scene_root  # This makes the node visible in the scene tree

		# Optionally, select the new node in the editor
		editor_interface.get_selection().clear()
		editor_interface.get_selection().add_node(new_node)

		# Mark the scene as changed
		scene_root.set_meta("__editor_plugin_changed__", true)
		
# func Load_XBase():
	#TODO add state and add thingbase only if it doesn't exists yet
	# xb = xBase.new()
	# xb.start_xbase()
	
	# tb = xb.add_thingbase("tb_from_plugin","thingbase::templates::Schema;thingbase::templates::XScape") # TODO : enable "thingbase::templates::Schema;thingbase::templates::XScape"
	#print(xb.get_size())
	# var t1 = tb.add_thing("th1")
	# var t2 = tb.add_thing("th2")
	
	# tb.testAddingThings()
#TODO - add auto load of xBase - or XBGlobal
# https://docs.godotengine.org/en/latest/tutorials/plugins/editor/making_plugins.html#registering-autoloads-singletons-in-plugins

# now I guess we need to download data from a place and 


#import data onto the scene
#export shapes

func get_exportable_scenes() -> Dictionary:
	var exportable_scenes: Dictionary = {}
	var dir: DirAccess                = DirAccess.open("res://")
	if dir:
		_scan_for_tscn_files(dir, "", exportable_scenes)
	return exportable_scenes

func _scan_for_tscn_files(dir: DirAccess, current_path: String, exportable_scenes: Dictionary) -> void:
	# Scan all files and directories in current path
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	
	while file_name != "":
		var full_path: String = current_path + ("/" if current_path != "" else "") + file_name
		
		if dir.current_is_dir():
			# Skip hidden folders, .git, and addons
			if file_name.begins_with(".") or file_name == ".git" or full_path.begins_with("addons/"):
				file_name = dir.get_next()
				continue
			# Skip xbase_plugin tests/fixtures and outputs
			if full_path.begins_with("addons/xbase_plugin/tests"):
				file_name = dir.get_next()
				continue
			# Recursively scan subdirectories
			var sub_dir: DirAccess = DirAccess.open("res://" + full_path)
			if sub_dir:
				_scan_for_tscn_files(sub_dir, full_path, exportable_scenes)
		elif file_name.ends_with(".tscn"):
			# Skip hidden files and addons
			if file_name.begins_with(".") or full_path.begins_with("addons/"):
				file_name = dir.get_next()
				continue
			# Skip xbase_plugin tests/fixtures and outputs
			if full_path.begins_with("addons/xbase_plugin/tests"):
				file_name = dir.get_next()
				continue
			# Check if scene is exportable
			if _is_scene_exportable("res://" + full_path):
				# Use the path as both key and value in the dictionary
				exportable_scenes[full_path] = "0"
		
		file_name = dir.get_next()
	
	dir.list_dir_end()

func _is_scene_exportable(scene_path: String) -> bool:
	var file: FileAccess = FileAccess.open(scene_path, FileAccess.READ)
	if not file:
		return false

	# First pass: check that the file references axNode3D.gd at all
	# (declared in [ext_resource] headers, not in the [node] block itself)
	var has_axnode3d_resource: bool = false
	while not file.eof_reached():
		var line: String = file.get_line()
		if line.contains("axNode3D.gd"):
			has_axnode3d_resource = true
			break
		if line.begins_with("[node"):
			break  # Past the resource declarations
	if not has_axnode3d_resource:
		return false

	# Second pass: check root node block for AxoExport = true
	file.seek(0)
	var found_first_node: bool    = false
	var checking_for_export: bool = false

	while not file.eof_reached():
		var line: String = file.get_line().strip_edges()

		if line.begins_with("[node"):
			if not found_first_node:
				found_first_node = true
				checking_for_export = true
			else:
				# Reached second node — stop checking root block
				if checking_for_export:
					return false
		elif checking_for_export and line.contains("AxoExport = true"):
			return true

	return false

# Unity uses shortcuts on command line - these are the official BuildTargets
const PlatformIds: Dictionary = {
	"Win64": "StandaloneWindows64",
	"WebGL": "WebGL",
	"Android": "Android",
	"iOS": "iOS",
	"Linux64": "StandaloneLinux64"
}

# Retired build targets (owner decision 2026-07-17): recognised so lingering
# CI invocations NO-OP cleanly (warning + zero artifacts, exit 0) instead of
# erroring like a typo'd id would — downstream steps expecting artifacts
# surface what still depends on them.
const RetiredPlatformIds: Dictionary = {
	"WindowsStoreApps": "HoloLens - no longer supported",
}

func get_build_target_from_command_line() -> String:
	var cmd_args: PackedStringArray = OS.get_cmdline_args()
	for arg in cmd_args:
		if arg.begins_with("--buildTarget="):
			var id = arg.get_slice("=", 1)
			if PlatformIds.has(id):
				var mapped_target = PlatformIds[id]
				print("Command-line buildTarget ID: %s => Mapped Build Target: %s" % [id, mapped_target])
				return mapped_target
			elif RetiredPlatformIds.has(id):
				push_warning("buildTarget '%s' is RETIRED (%s) — export will no-op." % [id, RetiredPlatformIds[id]])
				return ""
			else:
				push_error("Unknown buildTarget '%s'. Defaulting to 'WebGL'." % id)
				return "WebGL"
	print("No --buildTarget= specified on command line. Defaulting to 'WebGL'.")
	return "WebGL"
