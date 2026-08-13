@tool
extends RefCounted
class_name SyncAmThingLink

## Syncs Axoverse Studio Asset Management metadata to ThingLink/Layer properties.
## Scans TSCN files for nodes with metadata/element_id and applies axNode3D script
## based on family_name mappings.

const AxNode3D_SCRIPT = preload("res://addons/xbase_plugin/axNode3D.gd")
const AXNODE3D_PATH = "res://addons/xbase_plugin/axNode3D.gd"
const LEVELS_DIR_TOKEN = "/levels/"
const MAIN_SCENE_NAME = "main.tscn"

# Ward room type codes extracted from room number segment 4
const WARD_ROOM_TYPES: Array = ["GWS", "HDU"]
const ROOM_UNIT_MESH_PATH = "res://shared/meshes/room_unit_mesh_0000.tres"
const AREA_MATERIAL_PATH = "res://shared/materials/area_material.tres"

# Bed family substrings (case-insensitive). Any family_name containing one of
# these is treated as PhysicalType "Bed" with ThingLink + Furniture layer enabled.
const BED_FAMILY_SUBSTRINGS: Array = ["bed"]

# ThingLink enablers: family_name -> PhysicalType
# These set useThingLink = true
# Note: bed families are also matched dynamically via BED_FAMILY_SUBSTRINGS
const THINGLINK_ENABLERS: Dictionary = {
}

# Layer enablers: family_name -> {layer, flags}
# These set useLayers = true
# Note: bed families are also matched dynamically via BED_FAMILY_SUBSTRINGS
const LAYER_ENABLERS: Dictionary = {
	"Basic Wall": {"layer": "Walls", "flags": 512},
	"Floor": {"layer": "Floor", "flags": 128},
}

# Group-based layer enablers: ancestor group name -> {layer, flags}
# Used when family_name doesn't match LAYER_ENABLERS (e.g. Doors with varied Revit names)
const GROUP_LAYER_ENABLERS: Dictionary = {
	"Doors": {"layer": "Doors", "flags": 1024},
	"Floors": {"layer": "Floor", "flags": 128},
}

# Statistics
var files_scanned: int = 0
var files_with_candidates: int = 0
var nodes_added: int = 0
var nodes_updated: int = 0
var nodes_removed: int = 0
var _log_entries: Array = []
var _verbose_logging_cache: Variant = null  # null = not checked yet
var override_existing: bool = false
var restrict_to_paths: Array = []  # If non-empty, only process these scene paths

## Main entry point - scans all TSCN files and syncs ThingLink properties
func execute() -> void:
	print("=== SyncAmThingLink Starting ===")
	_reset_stats()

	# Phase 1: Find candidate files using filesystem scan
	var candidate_files: Array = _scan_for_candidate_files()
	if not restrict_to_paths.is_empty():
		var filtered: Array = []
		for f in candidate_files:
			if f in restrict_to_paths:
				filtered.append(f)
		print("Filtered to %d open scenes (from %d candidates)" % [filtered.size(), candidate_files.size()])
		candidate_files = filtered
	print("Found %d candidate files with metadata/element_id" % candidate_files.size())

	# Phase 2: Process each candidate file via Godot API
	for file_path in candidate_files:
		_process_scene_file(file_path)

	_print_summary()
	print("=== SyncAmThingLink Complete ===")

func _reset_stats() -> void:
	files_scanned = 0
	files_with_candidates = 0
	nodes_added = 0
	nodes_updated = 0
	nodes_removed = 0
	_log_entries.clear()

## Phase 1: Filesystem scan to find TSCN files containing metadata/element_id
func _scan_for_candidate_files() -> Array:
	var candidates: Array = []
	var dir = DirAccess.open("res://")
	if dir:
		_scan_directory_recursive(dir, "", candidates)
	return candidates

func _scan_directory_recursive(dir: DirAccess, current_path: String, candidates: Array) -> void:
	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		# Skip hidden files and addons folder
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue

		var full_path = current_path + ("/" if current_path != "" else "") + file_name

		if dir.current_is_dir():
			# Skip non-content directories
			if file_name != "addons" and file_name != ".godot" and file_name != "build" and file_name != "shared":
				var sub_dir = DirAccess.open("res://" + full_path)
				if sub_dir:
					_scan_directory_recursive(sub_dir, full_path, candidates)
		elif file_name.ends_with(".tscn"):
			files_scanned += 1
			var full_res_path = "res://" + full_path
			if _file_has_element_id(full_res_path) or _is_level_scene(full_res_path) or _is_site_scene_candidate(full_res_path) or _file_has_level_instances(full_res_path):
				candidates.append(full_res_path)
				files_with_candidates += 1

		file_name = dir.get_next()

	dir.list_dir_end()

## Quick check if file contains metadata/element_id using line matching
func _file_has_element_id(file_path: String) -> bool:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return false

	while not file.eof_reached():
		var line = file.get_line()
		if line.contains("metadata/element_id"):
			file.close()
			return true

	file.close()
	return false

## Phase 2: Load scene and process all nodes
func _process_scene_file(scene_path: String) -> void:
	print("Processing: %s" % scene_path)

	# Load the scene
	var packed_scene = ResourceLoader.load(scene_path) as PackedScene
	if not packed_scene:
		push_error("Failed to load scene: %s" % scene_path)
		return

	# Instantiate to get node tree
	var scene_root = packed_scene.instantiate()
	if not scene_root:
		push_error("Failed to instantiate scene: %s" % scene_path)
		return

	# Apply ThingLink settings to level/master roots even if they lack AM metadata
	var modified = false
	modified = _maybe_configure_level_root(scene_root, scene_path) or modified
	modified = _maybe_configure_site_root(scene_root, scene_path) or modified

	# Process all nodes recursively
	modified = _process_node_recursive(scene_root) or modified

	# Ward block creation + bed assignment only on level scenes (not combined egh.tscn)
	if _is_level_scene(scene_path):
		modified = _create_ward_blocks(scene_root) or modified
		modified = _assign_beds_to_rooms(scene_root) or modified

	# Final pass: compute ThingInstanceLabel from ThingLabelOverride chain
	var label_count = AxNode3D.recalculate_instance_labels(scene_root)
	if label_count > 0:
		modified = true
		_log("Recalculated %d instance labels" % label_count)

	# If modified, save the scene
	if modified:
		var new_packed_scene = PackedScene.new()
		var result = new_packed_scene.pack(scene_root)
		if result == OK:
			var save_result = ResourceSaver.save(new_packed_scene, scene_path)
			if save_result == OK:
				_log("Saved: %s" % scene_path)
			else:
				push_error("Failed to save scene: %s (error %d)" % [scene_path, save_result])
		else:
			push_error("Failed to pack scene: %s (error %d)" % [scene_path, result])

	# Clean up
	scene_root.queue_free()

## Process a node and all its children, returns true if any modifications were made
func _process_node_recursive(node: Node) -> bool:
	var modified = false

	# Check if this node has element_id metadata (from Asset Management)
	if node.has_meta("element_id"):
		modified = _process_node_with_metadata(node) or modified

	# Process children
	for child in node.get_children():
		modified = _process_node_recursive(child) or modified

	return modified

## Process a single node that has Asset Management metadata
func _process_node_with_metadata(node: Node) -> bool:
	# AxNode3D extends Node3D - skip non-Node3D nodes (e.g. Control) to avoid type mismatch
	if not node is Node3D:
		return false

	var family_name = ""
	if node.has_meta("family_name"):
		family_name = node.get_meta("family_name")

	# Determine what properties should be set
	var is_bed = _is_bed_family(family_name)
	var is_room = node.has_meta("type_name") and str(node.get_meta("type_name")) == "Room"
	var group_layer = _get_group_layer_config(node) if not LAYER_ENABLERS.has(family_name) and not is_bed else {}
	var should_use_thinglink = THINGLINK_ENABLERS.has(family_name) or is_bed or is_room
	var should_use_layers = LAYER_ENABLERS.has(family_name) or is_bed or is_room or not group_layer.is_empty()
	var physical_type = THINGLINK_ENABLERS.get(family_name, "Bed" if is_bed else ("Room" if is_room else ""))
	var layer_config = LAYER_ENABLERS.get(family_name,
		{"layer": "Furniture", "flags": 2048} if is_bed else
		({"layer": "Colorizer", "flags": 16} if is_room else group_layer))

	var has_script = _node_has_axnode3d_script(node)
	var modified = false

	if should_use_thinglink or should_use_layers:
		# Need the script
		if not has_script:
			# Add script
			node.set_script(AxNode3D_SCRIPT)
			_ensure_guid(node)
			nodes_added += 1
			modified = true
			_log("Added script to: %s (family: %s)" % [node.name, family_name])

		# Now configure properties (skip if script already exists and override is off)
		var props_changed = false
		var allow_override = override_existing or not has_script
		if not allow_override:
			return modified

		# ThingLink properties
		if should_use_thinglink:
			if node.get("useThingLink") != true:
				node.set("useThingLink", true)
				props_changed = true
			if physical_type != "" and node.get("PhysicalType") != physical_type:
				node.set("PhysicalType", physical_type)
				props_changed = true
			# ThingLabelOverride → thinginstancelabel: deterministic friendly name vs GUID.
			# Beds don't have metadata/number like rooms; use "Bed-{element_id}" instead.
			var label = _derive_bed_label(node) if is_bed else _derive_thing_label(node)
			if label != "" and node.get("ThingLabelOverride") != label:
				node.set("ThingLabelOverride", label)
				props_changed = true
		else:
			if node.get("useThingLink") != false:
				node.set("useThingLink", false)
				props_changed = true

		# Layer properties
		if should_use_layers:
			if node.get("useLayers") != true:
				node.set("useLayers", true)
				props_changed = true
			if layer_config.has("layer") and node.get("Layers") != layer_config.layer:
				node.set("Layers", layer_config.layer)
				props_changed = true
			if layer_config.has("flags") and node.get("LayerFlags") != layer_config.flags:
				node.set("LayerFlags", layer_config.flags)
				props_changed = true
		else:
			if node.get("useLayers") != false:
				node.set("useLayers", false)
				props_changed = true

		if props_changed and not modified:
			nodes_updated += 1
			modified = true
			_log("Updated properties on: %s (family: %s)" % [node.name, family_name])
		elif props_changed:
			# Already counted as added
			pass

	elif has_script:
		if override_existing:
			# Skip nodes handled by later phases (ward rooms, beds)
			var is_room_node = node.has_meta("type_name") and str(node.get_meta("type_name")) == "Room"
			if not is_bed and not is_room_node:
				# Neither ThingLink nor Layers needed, but has script - remove it
				node.set_script(null)
				nodes_removed += 1
				modified = true
				_log("Removed script from: %s (family: %s)" % [node.name, family_name])

	return modified

func _maybe_configure_level_root(scene_root: Node, scene_path: String) -> bool:
	if not _is_level_scene(scene_path):
		return false

	var level_name = _get_level_display_name(scene_root, scene_path)
	return _ensure_thinglink_node(scene_root, "Level", level_name, "level root")

func _maybe_configure_site_root(scene_root: Node, scene_path: String) -> bool:
	if not _is_site_scene_candidate(scene_path):
		return false

	var site_name = _get_primary_export_name()
	return _ensure_thinglink_node(scene_root, "Site", site_name, "master root")

func _ensure_thinglink_node(node: Node, physical_type: String, thing_name: String, context: String) -> bool:
	var modified = false
	var has_script = _node_has_axnode3d_script(node)

	if not has_script:
		node.set_script(AxNode3D_SCRIPT)
		_ensure_guid(node)
		nodes_added += 1
		modified = true
		_log("Added script to %s: %s" % [context, node.name])

	var props_changed = false
	var allow_override = override_existing or not has_script
	if not allow_override:
		return modified
	if node.get("useThingLink") != true:
		node.set("useThingLink", true)
		props_changed = true
	if node.get("PhysicalType") != physical_type:
		node.set("PhysicalType", physical_type)
		props_changed = true
	if node.get("AxoExport") != true:
		node.set("AxoExport", true)
		props_changed = true
	if physical_type == "Level":
		if node.get("useBoundsHelper") != true:
			node.set("useBoundsHelper", true)
			props_changed = true
	if thing_name != "" and node.get("ThingNameOverride") != thing_name:
		node.set("ThingNameOverride", thing_name)
		props_changed = true
	# ThingLabelOverride → thinginstancelabel in XScape: deterministic,
	# human-friendly identifier (URL-safe, no spaces) instead of a GUID.
	var thing_label = _to_url_safe(thing_name) if thing_name != "" else ""
	if thing_label != "" and node.get("ThingLabelOverride") != thing_label:
		node.set("ThingLabelOverride", thing_label)
		props_changed = true

	if props_changed and not modified:
		nodes_updated += 1
		modified = true
		_log("Updated ThingLink on %s: %s" % [context, node.name])
	elif props_changed:
		pass

	return modified

func _get_level_display_name(scene_root: Node, scene_path: String) -> String:
	if scene_root.has_meta("level_name"):
		return str(scene_root.get_meta("level_name"))
	if scene_root.has_meta("level"):
		return str(scene_root.get_meta("level"))
	if scene_root.name != "":
		return scene_root.name
	return scene_path.get_file().get_basename()

func _get_primary_export_name() -> String:
	var project_name = str(ProjectSettings.get_setting("xbase_plugin/settings/project_name", ""))
	if project_name == "":
		project_name = str(ProjectSettings.get_setting("application/config/name", ""))
	if project_name == "":
		project_name = "Site"
	return project_name

func _is_level_scene(scene_path: String) -> bool:
	return scene_path.contains(LEVELS_DIR_TOKEN)

func _is_site_scene_candidate(scene_path: String) -> bool:
	if _is_level_scene(scene_path):
		return false
	if scene_path.ends_with("/" + MAIN_SCENE_NAME):
		return false
	if not scene_path.ends_with(".tscn"):
		return false
	return true

## Derives a ThingLabelOverride from node metadata, made URL-safe (no spaces).
## ThingLabelOverride becomes the thinginstancelabel in XScape, providing a
## deterministic, human-friendly identifier instead of a GUID.
## Prefers metadata/number, falls back to metadata/element_id.
## If the room number is incomplete (e.g. "RM-L1-A0-AMEP-" with empty last
## segment), appends element_id for uniqueness since many rooms share the
## same incomplete number pattern.
func _derive_thing_label(node: Node) -> String:
	if node.has_meta("number"):
		var val = str(node.get_meta("number"))
		if val != "":
			var safe = _to_url_safe(val)
			# Incomplete room numbers end with trailing underscore (from trailing
			# hyphen). Append element_id to disambiguate.
			if safe.ends_with("_") and node.has_meta("element_id"):
				var eid = str(node.get_meta("element_id"))
				if eid != "":
					safe = safe + _to_url_safe(eid)
			return safe
	if node.has_meta("element_id"):
		var val = str(node.get_meta("element_id"))
		if val != "":
			return _to_url_safe(val)
	return ""

## Derives ThingLabelOverride for bed nodes. Beds don't carry a metadata/number
## like rooms do, so we use "Bed-{element_id}" to build a deterministic label.
func _derive_bed_label(node: Node) -> String:
	if node.has_meta("element_id"):
		var val = str(node.get_meta("element_id"))
		if val != "":
			return "bed_" + _to_url_safe(val)
	return ""

## Makes a string URL-safe: replaces spaces/hyphens with underscores, strips
## anything that isn't alphanumeric or underscore. Underscores are preferred so
## double-clicking selects the whole label in most editors/browsers.
func _to_url_safe(text: String) -> String:
	var result = text.replace(" ", "_").replace("-", "_").to_lower()
	var safe = ""
	for i in range(result.length()):
		var c = result[i]
		if c == "_" or (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			safe += c
	return safe

## Returns GROUP_LAYER_ENABLERS config if an ancestor group name matches, else empty dict
func _get_group_layer_config(node: Node) -> Dictionary:
	var parent = node.get_parent()
	while parent:
		var pname: String = parent.name
		if GROUP_LAYER_ENABLERS.has(pname):
			return GROUP_LAYER_ENABLERS[pname]
		parent = parent.get_parent()
	return {}

## Returns true if family_name matches a bed family (case-insensitive substring match)
func _is_bed_family(family_name: String) -> bool:
	if family_name == "":
		return false
	var lower = family_name.to_lower()
	for pattern in BED_FAMILY_SUBSTRINGS:
		if lower.contains(pattern):
			return true
	return false

func _node_has_axnode3d_script(node: Node) -> bool:
	var script = node.get_script()
	if script == null:
		return false
	if script == AxNode3D_SCRIPT:
		return true
	if script is Script and script.resource_path == AXNODE3D_PATH:
		return true
	return false

## Ensures a ThingGuid is generated immediately after script attachment.
## In headless mode _enter_tree() never fires, so we generate the GUID here.
func _ensure_guid(node: Node) -> void:
	if node.get("ThingGuid") == null:
		return
	if node.get("ThingGuid") == "":
		node.set("ThingGuid", node.gen_guid())

func _file_has_level_instances(file_path: String) -> bool:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return false

	while not file.eof_reached():
		var line = file.get_line()
		if line.contains("instance=ExtResource") and line.contains("levels/"):
			file.close()
			return true

	file.close()
	return false

func _log(message: String) -> void:
	_log_entries.append(message)
	_log_verbose("  " + message)

func _log_verbose(msg: Variant, msg2: Variant = "", msg3: Variant = "", msg4: Variant = "") -> void:
	if _verbose_logging_cache == null:
		_verbose_logging_cache = ProjectSettings.get_setting("xbase_plugin/settings/verbose_logging", false)
	if _verbose_logging_cache:
		if msg4 != "":
			print(msg, msg2, msg3, msg4)
		elif msg3 != "":
			print(msg, msg2, msg3)
		elif msg2 != "":
			print(msg, msg2)
		else:
			print(msg)

func _print_summary() -> void:
	print("")
	print("=== Summary ===")
	print("Files scanned: %d" % files_scanned)
	print("Files with AM metadata: %d" % files_with_candidates)
	print("Nodes added (script added): %d" % nodes_added)
	print("Nodes updated (properties changed): %d" % nodes_updated)
	print("Nodes removed (script removed): %d" % nodes_removed)
	print("Total changes: %d" % (nodes_added + nodes_updated + nodes_removed))

## ─── Ward Block Creation ───────────────────────────────────────────────

## Parses room number "RM-L6-A1-AGWS-01107"
## Returns { "block": "A1", "room_type": "GWS", "level": "L6" } or empty dict
func _parse_room_number(room_number: String) -> Dictionary:
	var parts = room_number.split("-")
	if parts.size() < 5 or parts[0] != "RM":
		return {}
	var code_segment = parts[3]  # e.g. "AGWS"
	if code_segment.length() < 2:
		return {}
	return {
		"level": parts[1],          # "L6"
		"block": parts[2],          # "A1"
		"room_type": code_segment.substr(1),  # "GWS"
	}

## Collects rooms into ward groups by scanning for room number metadata
## Ward ID includes level to prevent cross-level grouping (e.g. "L6_A1")
func _collect_ward_rooms(node: Node, ward_rooms: Dictionary) -> void:
	if node.has_meta("number"):
		var room_number = str(node.get_meta("number"))
		var parsed = _parse_room_number(room_number)
		if not parsed.is_empty() and parsed.room_type in WARD_ROOM_TYPES:
			var ward_id = parsed.level + "_" + parsed.block  # e.g. "L6_A1"
			if not ward_rooms.has(ward_id):
				ward_rooms[ward_id] = []
			ward_rooms[ward_id].append(node)
	for child in node.get_children():
		_collect_ward_rooms(child, ward_rooms)

## Creates ward grouping nodes that enclose their member rooms
func _create_ward_blocks(scene_root: Node) -> bool:
	# Step 1: Collect ward membership from room nodes
	var ward_rooms: Dictionary = {}  # ward_id -> [room_nodes]
	_collect_ward_rooms(scene_root, ward_rooms)
	if ward_rooms.is_empty():
		return false

	# Step 2: Find or create Wards group node (preserve existing to keep GUIDs)
	# Wards must appear before Rooms in the tree so CSV order is correct
	# (wards above rooms, rooms above beds)
	var wards_node = scene_root.find_child("Wards", false)
	if not wards_node:
		wards_node = Node3D.new()
		wards_node.name = "Wards"
		scene_root.add_child(wards_node)
		wards_node.owner = scene_root
	scene_root.move_child(wards_node, 0)

	# Remove stale ward nodes (ward IDs no longer present in room scan)
	for child in wards_node.get_children():
		var child_name = child.name as String
		if child_name.begins_with("Ward"):
			var stale_ward_id = child_name.substr(4)  # Strip "Ward" prefix
			if not ward_rooms.has(stale_ward_id):
				wards_node.remove_child(child)
				child.queue_free()
				nodes_removed += 1
				_log("Removed stale ward: %s" % child_name)

	# Step 3: Load room unit mesh and material for ward geometry
	var room_unit_mesh: ArrayMesh = null
	if ResourceLoader.exists(ROOM_UNIT_MESH_PATH):
		room_unit_mesh = load(ROOM_UNIT_MESH_PATH) as ArrayMesh
	var area_material: Material = null
	if ResourceLoader.exists(AREA_MATERIAL_PATH):
		area_material = load(AREA_MATERIAL_PATH) as Material

	var modified = false
	for ward_id in ward_rooms:
		var rooms = ward_rooms[ward_id]
		var ward_node = wards_node.find_child("Ward" + ward_id, false)
		var ward_created = false
		if not ward_node:
			ward_node = MeshInstance3D.new()
			ward_node.name = "Ward" + ward_id
			if room_unit_mesh:
				ward_node.mesh = room_unit_mesh
			if area_material:
				ward_node.material_override = area_material
			wards_node.add_child(ward_node)
			ward_node.owner = scene_root
			ward_created = true

		# Add AxNode3D script to ward node (always ensure script is present)
		var ward_had_script = _node_has_axnode3d_script(ward_node)
		if not ward_had_script:
			ward_node.set_script(AxNode3D_SCRIPT)
			_ensure_guid(ward_node)
			nodes_added += 1
			modified = true

		# Gate property updates: always on new wards/scripts, otherwise respect override_existing
		var ward_allow_override = override_existing or not ward_had_script
		if ward_allow_override:
			var ward_props_changed = false
			if ward_node.get("useThingLink") != true:
				ward_node.set("useThingLink", true)
				ward_props_changed = true
			if ward_node.get("PhysicalType") != "Ward":
				ward_node.set("PhysicalType", "Ward")
				ward_props_changed = true
			# ward_id is "L6_A1", display as "Ward L6 A1"
			var ward_display_name = "Ward " + ward_id.replace("_", " ")
			if ward_node.get("ThingNameOverride") != ward_display_name:
				ward_node.set("ThingNameOverride", ward_display_name)
				ward_props_changed = true
			# ThingLabelOverride → thinginstancelabel: URL-safe ward identifier
			var ward_label = _to_url_safe(ward_display_name)
			if ward_node.get("ThingLabelOverride") != ward_label:
				ward_node.set("ThingLabelOverride", ward_label)
				ward_props_changed = true
			# Layer: Colorizer for xScape area shading
			if ward_node.get("useLayers") != true:
				ward_node.set("useLayers", true)
				ward_props_changed = true
			if ward_node.get("Layers") != "Colorizer":
				ward_node.set("Layers", "Colorizer")
				ward_props_changed = true
			if ward_node.get("LayerFlags") != 16:
				ward_node.set("LayerFlags", 16)
				ward_props_changed = true
			if ward_props_changed:
				if ward_had_script:
					nodes_updated += 1
				modified = true

		# Set ParentOverride on member rooms
		for room_node in rooms:
			var room_had_script = _node_has_axnode3d_script(room_node)
			if not room_had_script:
				room_node.set_script(AxNode3D_SCRIPT)
				_ensure_guid(room_node)
				nodes_added += 1
				modified = true
			var room_allow_override = override_existing or not room_had_script
			if room_allow_override:
				var room_props_changed = false
				if room_node.get("useThingLink") != true:
					room_node.set("useThingLink", true)
					room_props_changed = true
				if room_node.get("PhysicalType") != "Room":
					room_node.set("PhysicalType", "Room")
					room_props_changed = true
				var room_label = _derive_thing_label(room_node)
				if room_label != "" and room_node.get("ThingLabelOverride") != room_label:
					room_node.set("ThingLabelOverride", room_label)
					room_props_changed = true
				if room_node.get("ParentOverride") != ward_node:
					room_node.set("ParentOverride", ward_node)
					room_props_changed = true
				# Layer: Colorizer for xScape area shading
				if room_node.get("useLayers") != true:
					room_node.set("useLayers", true)
					room_props_changed = true
				if room_node.get("Layers") != "Colorizer":
					room_node.set("Layers", "Colorizer")
					room_props_changed = true
				if room_node.get("LayerFlags") != 16:
					room_node.set("LayerFlags", 16)
					room_props_changed = true
				if room_props_changed:
					if room_had_script:
						nodes_updated += 1
					modified = true

		# Step 4: Compute bounding box from room transforms
		_update_ward_transform(ward_node, rooms)
		if ward_created:
			_log("Created ward: Ward%s with %d rooms" % [ward_id, rooms.size()])

	return modified

## Computes the AABB enclosing all room meshes and sets ward transform
func _update_ward_transform(ward_node: Node3D, rooms: Array) -> void:
	if rooms.is_empty():
		return
	var aabb = AABB()
	var first = true
	for room in rooms:
		if room is Node3D:
			var room_aabb = _get_node_world_aabb(room)
			if first:
				aabb = room_aabb
				first = false
			else:
				aabb = aabb.merge(room_aabb)

	if first:
		return  # No valid rooms

	# Set ward transform: position at AABB origin, scale to AABB size
	ward_node.global_transform = Transform3D(
		Basis.IDENTITY.scaled(aabb.size),
		aabb.position
	)

## Gets the world-space AABB for a node with unit cube mesh (transform encodes pos+scale)
func _get_node_world_aabb(node: Node3D) -> AABB:
	var t = node.transform
	# Unit cube goes from (0,0,0) to (1,1,1), so transformed corners are:
	var origin = t.origin
	var end_pt = t * Vector3.ONE
	var min_pos = Vector3(min(origin.x, end_pt.x), min(origin.y, end_pt.y), min(origin.z, end_pt.z))
	var max_pos = Vector3(max(origin.x, end_pt.x), max(origin.y, end_pt.y), max(origin.z, end_pt.z))
	return AABB(min_pos, max_pos - min_pos)

## ─── Bed-to-Room Spatial Assignment ──────────────────────────────────────

## Assigns beds to rooms using spatial containment test.
## For rooms with custom meshes, projects triangles onto XZ plane for accurate
## point-in-polygon testing (handles L-shapes etc). Falls back to AABB for
## unit-mesh rooms where the transform encodes position + scale.
func _assign_beds_to_rooms(scene_root: Node) -> bool:
	# Collect all rooms with their spatial data
	var room_entries: Array = []  # [{node, aabb, triangles_xz (optional)}]
	_collect_all_rooms(scene_root, room_entries)
	var mesh_rooms = 0
	var aabb_rooms = 0
	for e in room_entries:
		if e.has("triangles_xz"):
			mesh_rooms += 1
		else:
			aabb_rooms += 1
	_log_verbose("Bed assignment: collected %d rooms (%d with mesh triangles, %d AABB-only)" % [room_entries.size(), mesh_rooms, aabb_rooms])
	if room_entries.is_empty():
		_log_verbose("Bed assignment: no rooms found - skipping")
		return false

	# Collect all bed nodes
	var beds: Array = []
	_collect_beds(scene_root, beds)
	_log_verbose("Bed assignment: collected %d beds" % beds.size())
	if beds.is_empty():
		_log_verbose("Bed assignment: no beds found - skipping")
		return false

	# Log sample rooms for debugging
	var sample_count = mini(5, room_entries.size())
	for i in range(sample_count):
		var e = room_entries[i]
		var method = "mesh(%d tris)" % e.triangles_xz.size() if e.has("triangles_xz") else "aabb"
		_log_verbose("  Room[%d]: %s pos=%s aabb=%s method=%s" % [i, e.node.name, e.node.transform.origin, e.aabb, method])

	# Log sample bed positions for debugging
	sample_count = mini(5, beds.size())
	for i in range(sample_count):
		_log_verbose("  Bed[%d]: %s pos=%s" % [i, beds[i].name, beds[i].transform.origin])

	# For each bed, find the containing room
	var modified = false
	var assigned_count = 0
	var unassigned_count = 0
	for bed_node in beds:
		var bed_pos: Vector3 = bed_node.transform.origin
		var best_room: Node = null
		var best_volume: float = INF
		for entry in room_entries:
			# Quick AABB rejection first
			var aabb: AABB = entry.aabb
			if not aabb.has_point(bed_pos):
				continue
			# Precise test: mesh triangles on XZ plane, or AABB pass-through
			if entry.has("triangles_xz"):
				if not _point_in_room_xz(bed_pos.x, bed_pos.z, entry.triangles_xz):
					continue
			# If bed matches multiple rooms, pick smallest volume
			var vol = aabb.get_volume()
			if vol < best_volume:
				best_volume = vol
				best_room = entry.node

		if best_room:
			var bed_had_script = _node_has_axnode3d_script(bed_node)
			if not bed_had_script:
				bed_node.set_script(AxNode3D_SCRIPT)
				_ensure_guid(bed_node)
				nodes_added += 1
				modified = true
			var bed_allow_override = override_existing or not bed_had_script
			if bed_allow_override:
				var bed_props_changed = false
				if bed_node.get("useThingLink") != true:
					bed_node.set("useThingLink", true)
					bed_props_changed = true
				if bed_node.get("PhysicalType") != "Bed":
					bed_node.set("PhysicalType", "Bed")
					bed_props_changed = true
				# Beds don't have metadata/number like rooms; use "Bed-{element_id}"
				var bed_label = _derive_bed_label(bed_node)
				if bed_label != "" and bed_node.get("ThingLabelOverride") != bed_label:
					bed_node.set("ThingLabelOverride", bed_label)
					bed_props_changed = true
				if bed_node.get("ParentOverride") != best_room:
					bed_node.set("ParentOverride", best_room)
					bed_props_changed = true
				if bed_props_changed:
					if bed_had_script:
						nodes_updated += 1
					modified = true
			assigned_count += 1
			_log_verbose("  Bed '%s' at %s -> Room '%s'" % [bed_node.name, bed_pos, best_room.name])
		else:
			unassigned_count += 1
			if unassigned_count <= 10:
				_log_verbose("  Bed '%s' at %s -> NO ROOM match" % [bed_node.name, bed_pos])

	if unassigned_count > 10:
		_log_verbose("  ... and %d more unassigned beds" % (unassigned_count - 10))

	if assigned_count > 0:
		_log("Assigned %d beds to rooms (from %d beds, %d rooms, %d unassigned)" % [assigned_count, beds.size(), room_entries.size(), unassigned_count])
	else:
		_log("No beds assigned to rooms (%d beds, %d rooms - no spatial matches)" % [beds.size(), room_entries.size()])

	return modified

## Collects all room nodes with spatial data for containment testing.
## For MeshInstance3D rooms with custom meshes, extracts triangles projected onto
## the XZ plane (world-space) for accurate point-in-polygon testing.
## For unit-mesh rooms, uses AABB derived from transform.
func _collect_all_rooms(node: Node, room_entries: Array) -> void:
	if node is Node3D and node.has_meta("type_name") and str(node.get_meta("type_name")) == "Room":
		var entry: Dictionary = {
			"node": node,
			"aabb": _get_node_world_aabb(node)
		}
		# Try to extract mesh triangles for precise spatial testing
		if node is MeshInstance3D and node.mesh:
			var triangles_xz = _extract_xz_triangles(node)
			if not triangles_xz.is_empty():
				entry["triangles_xz"] = triangles_xz
				# Recompute AABB from actual mesh bounds (more accurate than transform-only)
				entry["aabb"] = _get_mesh_world_aabb(node)
		for child in node.get_children():
			if child is MeshInstance3D and child.mesh and not entry.has("triangles_xz"):
				var triangles_xz = _extract_xz_triangles(child)
				if not triangles_xz.is_empty():
					entry["triangles_xz"] = triangles_xz
					entry["aabb"] = _get_mesh_world_aabb(child)
					break
		room_entries.append(entry)
	for child in node.get_children():
		_collect_all_rooms(child, room_entries)

## Extracts mesh face triangles projected onto the XZ plane in world space.
## Returns array of [Vector2, Vector2, Vector2] triangles.
func _extract_xz_triangles(mesh_node: MeshInstance3D) -> Array:
	var faces: PackedVector3Array = mesh_node.mesh.get_faces()
	if faces.is_empty():
		return []
	var t = mesh_node.transform
	var triangles: Array = []
	for i in range(0, faces.size(), 3):
		# Transform vertices to world space, then project onto XZ
		var a = t * faces[i]
		var b = t * faces[i + 1]
		var c = t * faces[i + 2]
		triangles.append([
			Vector2(a.x, a.z),
			Vector2(b.x, b.z),
			Vector2(c.x, c.z)
		])
	return triangles

## Gets the world-space AABB from actual mesh bounds (not just transform)
func _get_mesh_world_aabb(mesh_node: MeshInstance3D) -> AABB:
	var mesh_aabb: AABB = mesh_node.mesh.get_aabb()
	var t = mesh_node.transform
	# Transform all 8 corners of the local AABB to world space
	var corners: Array = []
	for ix in [0, 1]:
		for iy in [0, 1]:
			for iz in [0, 1]:
				var local_pt = Vector3(
					mesh_aabb.position.x + mesh_aabb.size.x * ix,
					mesh_aabb.position.y + mesh_aabb.size.y * iy,
					mesh_aabb.position.z + mesh_aabb.size.z * iz
				)
				corners.append(t * local_pt)
	var min_pos = corners[0]
	var max_pos = corners[0]
	for corner in corners:
		min_pos = Vector3(min(min_pos.x, corner.x), min(min_pos.y, corner.y), min(min_pos.z, corner.z))
		max_pos = Vector3(max(max_pos.x, corner.x), max(max_pos.y, corner.y), max(max_pos.z, corner.z))
	return AABB(min_pos, max_pos - min_pos)

## Tests if a point (px, pz) falls inside any of the room's XZ-projected triangles
func _point_in_room_xz(px: float, pz: float, triangles_xz: Array) -> bool:
	for tri in triangles_xz:
		if _point_in_triangle_2d(px, pz, tri[0].x, tri[0].y, tri[1].x, tri[1].y, tri[2].x, tri[2].y):
			return true
	return false

## Point-in-triangle test using 2D barycentric sign method (same as occupancy grid)
func _point_in_triangle_2d(px: float, pz: float,
		ax: float, az: float,
		bx: float, bz: float,
		cx: float, cz: float) -> bool:
	var d1 := _sign_2d(px, pz, ax, az, bx, bz)
	var d2 := _sign_2d(px, pz, bx, bz, cx, cz)
	var d3 := _sign_2d(px, pz, cx, cz, ax, az)
	var has_neg := (d1 < 0.0) or (d2 < 0.0) or (d3 < 0.0)
	var has_pos := (d1 > 0.0) or (d2 > 0.0) or (d3 > 0.0)
	return not (has_neg and has_pos)

func _sign_2d(px: float, pz: float,
		ax: float, az: float,
		bx: float, bz: float) -> float:
	return (px - bx) * (az - bz) - (ax - bx) * (pz - bz)

## Collects all bed nodes (nodes whose family_name is a bed type)
func _collect_beds(node: Node, beds: Array) -> void:
	if node is Node3D and node.has_meta("family_name"):
		if _is_bed_family(str(node.get_meta("family_name"))):
			beds.append(node)
	for child in node.get_children():
		_collect_beds(child, beds)
