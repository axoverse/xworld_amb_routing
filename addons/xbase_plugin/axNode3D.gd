@tool
extends Node3D
class_name AxNode3D

const PHYSICAL_TYPES_JSON_PATH = "res://addons/xbase_plugin/share/data/physical_types.json"

static var _physical_types_cache: Array = []

# Load physical types from shared JSON file (static for reuse)
static func _load_physical_types() -> Array:
	if _physical_types_cache.is_empty():
		if FileAccess.file_exists(PHYSICAL_TYPES_JSON_PATH):
			var file = FileAccess.open(PHYSICAL_TYPES_JSON_PATH, FileAccess.READ)
			var json = JSON.new()
			var error = json.parse(file.get_as_text())
			file.close()
			if error == OK:
				_physical_types_cache = json.data
			else:
				push_error("Failed to parse physical_types.json: %s" % json.get_error_message())
		else:
			push_error("Physical types JSON not found: %s" % PHYSICAL_TYPES_JSON_PATH)
	return _physical_types_cache

## Set true to top node to mark scene as being exported
@export var useThingLink : bool = false:
	set(value):
		useThingLink = value
		notify_property_list_changed()

@export var usePivotOverride : bool = false:
	set(value):
		usePivotOverride = value
		notify_property_list_changed()

@export var useTransformLock : bool = false:
	set(value):
		useTransformLock = value
		notify_property_list_changed()

@export var useBoundsHelper : bool = false:
	set(value):
		useBoundsHelper = value
		notify_property_list_changed()
		_refresh_bounds_gizmo()

# --- BoundsHelper parity (mirrors Unity BoundsHelper.cs) -----------------
# Unity stored bounds in a separate MonoBehaviour with two modes: dynamic
# (walk child MeshFilter AABBs) or static (pre-baked StaticBounds). On the
# Godot port useBoundsHelper above is the layout-participation gate, and
# the two fields below carry the static-bounds payload. Bake via the
# "Bake bounds (walk children)" button — typical authoring path is bake
# in the editor, then leave UseStaticBounds = true for stable runtime
# values that don't race with mesh realisation.

@export_group("Bounds (parity with Unity BoundsHelper)")
@export var UseStaticBounds : bool = false:
	set(value):
		UseStaticBounds = value
		_refresh_bounds_gizmo()
## Pre-baked AABB in this node's LOCAL space. Set by Bake button or via
## `compute_local_mesh_aabb()`. Mirrored into metadata "_static_bounds_local"
## so the C++ walker (XScapeView::compute_prefab_world_aabb) can read it.
@export var StaticBounds : AABB = AABB():
	set(value):
		StaticBounds = value
		set_meta("_static_bounds_local", value)
		_refresh_bounds_gizmo()

@export_tool_button("Bake bounds (walk children)", "Reload") var _bake_bounds_btn = _on_bake_bounds

func _on_bake_bounds() -> void:
	if not is_inside_tree():
		push_warning("[AxNode3D] %s not in tree — cannot bake bounds yet" % name)
		return
	var b := compute_local_mesh_aabb()
	StaticBounds = b
	UseStaticBounds = true
	useBoundsHelper = true
	print("[AxNode3D] %s baked: pos=%s size=%s" % [name, str(b.position), str(b.size)])

## Walks VisualInstance3D descendants and returns the union AABB in THIS
## node's local space. Honours the useBoundsHelper gate on descendant
## AxNode3Ds (mirrors Unity Layouts.cs TryGetComponent<BoundsHelper>
## filter — decorative subtrees opt out by leaving useBoundsHelper=false).
func compute_local_mesh_aabb() -> AABB:
	if not is_inside_tree():
		return AABB()
	var inv: Transform3D = global_transform.affine_inverse()
	var out: AABB = AABB()
	var seeded: bool = false
	var stack: Array = [self]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		# Skip non-root AxNode3D subtrees that opt out. Duck-typed via get():
		# plain Node3D returns NIL, AxNode3D returns BOOL. Avoids needing
		# `is AxNode3D` here — class_name is not yet bound when this script
		# is parsed in isolation (e.g. by `--check-only`).
		if cur != self:
			var v: Variant = cur.get("useBoundsHelper")
			if typeof(v) == TYPE_BOOL and not v:
				continue
		if cur is VisualInstance3D:
			var vi: VisualInstance3D = cur as VisualInstance3D
			var local: AABB = vi.get_aabb()
			if local.size != Vector3.ZERO:
				var world: AABB = vi.global_transform * local
				var in_self: AABB = inv * world
				if not seeded:
					out = in_self
					seeded = true
				else:
					out = out.merge(in_self)
		for child in cur.get_children():
			stack.push_back(child)
	return out

# Wireframe gizmo — mirrors Unity BoundsHelper.OnDrawGizmosSelected, but
# always-on (not selection-gated, since Godot has no per-node gizmo
# without a full Node3DGizmoPlugin). Child marker node, owner=null so
# the gizmo never serialises into .tscn.
const _BOUNDS_GIZMO_NAME := "_BoundsHelperGizmo"

func _refresh_bounds_gizmo() -> void:
	if not is_inside_tree():
		return
	var existing := get_node_or_null(_BOUNDS_GIZMO_NAME)
	if existing != null:
		existing.queue_free()
	if not useBoundsHelper:
		return
	# Editor-only by default. At runtime the LG bbox drawn by xscape_view
	# (RenderingServer instance) already visualises bounds for the active LG
	# — adding 185 per-AxNode3D wireframes on top would be unreadable. The
	# env var override lets diagnostic scenes (inspect_testsite) opt in if
	# they need the per-node view at runtime.
	if not Engine.is_editor_hint() and OS.get_environment("XBASE_SHOW_BOUNDS_GIZMOS") != "1":
		return
	var bounds: AABB
	if UseStaticBounds and StaticBounds.size != Vector3.ZERO:
		bounds = StaticBounds
	else:
		bounds = compute_local_mesh_aabb()
	if bounds.size == Vector3.ZERO:
		return
	var mi := MeshInstance3D.new()
	mi.name = _BOUNDS_GIZMO_NAME
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.1, 0.95)  # yellow — matches LG bbox
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.disable_receive_shadows = true
	mi.mesh = im
	mi.cast_shadow = MeshInstance3D.SHADOW_CASTING_SETTING_OFF
	var mn: Vector3 = bounds.position
	var mx: Vector3 = mn + bounds.size
	var v := [
		Vector3(mn.x, mn.y, mn.z), Vector3(mx.x, mn.y, mn.z),
		Vector3(mx.x, mx.y, mn.z), Vector3(mn.x, mx.y, mn.z),
		Vector3(mn.x, mn.y, mx.z), Vector3(mx.x, mn.y, mx.z),
		Vector3(mx.x, mx.y, mx.z), Vector3(mn.x, mx.y, mx.z),
	]
	var edges := [
		[0,1],[1,2],[2,3],[3,0],
		[4,5],[5,6],[6,7],[7,4],
		[0,4],[1,5],[2,6],[3,7],
	]
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for e in edges:
		im.surface_add_vertex(v[e[0]])
		im.surface_add_vertex(v[e[1]])
	im.surface_end()
	add_child(mi)
	# owner stays null — gizmo is transient, not part of the saved scene.

@export var useEdges : bool = false:
	set(value):
		useEdges = value
		notify_property_list_changed()

@export var useLayers : bool = false:
	set(value):
		useLayers = value
		notify_property_list_changed()

@export var useLabel3D : bool = false:
	set(value):
		useLabel3D = value
		notify_property_list_changed()

@export var isRoutingWaypoint : bool = false:
	set(value):
		isRoutingWaypoint = value
		notify_property_list_changed()

@export var useTimeStateManager : bool = false:
	set(value):
		useTimeStateManager = value
		notify_property_list_changed()

@export var useEdgeInstances : bool = false:
	set(value):
		useEdgeInstances = value
		notify_property_list_changed()

@export var useTimeState : bool = false:
	set(value):
		useTimeState = value
		notify_property_list_changed()

		
@export_group("Export related")
@export var AxoExport: bool = false:
	set(value):
		AxoExport = value
		notify_property_list_changed()
## Recomputes ThingInstanceLabel for this node and all descendants.
## ThingInstanceLabel is the deterministic instance identifier used by XScape.
## It is derived from ThingLabelOverride: '&' prefix concatenates with parent
## label for hierarchical paths; otherwise the label is used directly.
@export_tool_button("Recalculate Instance Labels", "Reload") var _recalc_btn = _on_recalculate_instance_labels

func _on_recalculate_instance_labels() -> void:
	var count = AxNode3D.recalculate_instance_labels(self)
	print("RecalculateInstanceLabels: updated %d nodes from %s" % [count, name])

@export_group("ThingLink properties")
## "Alternative parent - otherwise uses one in hierarchy
@export var ParentOverride: AxNode3D
@export var ParentOverride_name: String; # GameObject in Unity
#    [Tooltip("Override label - the main ID. Use '+' to concat from parent label")]
@export var ThingLabelOverride:String = ""
#    [Tooltip("Override name, otherwise uses label")]
@export var      ThingNameOverride:String;
#    public PhysicalTypes PhysicalType;
@export_enum(
	"None","Site","Building","Wing","Ward","Level","Corridor","Room","Bed",
		"Vehicle","House","Cabinet","Road","Area","Jurisdiction",
		"UtilityItem","Bathroom","WaterTap","WaterOutlet","Sink","Drain","Toilet","Shower","Urinal",
		"HvacSupplyAirVent","HvacReturnAirIntake","HvacExhaustAirIntake","HvacAhu","HvacFcu",
		"Other", "Furniture",
		"MeetingRoom","Desk","Cluster","Zone","District","Locality","Shelf","Rack","Table","Elevator","Hall","Apartment",
		"Folder","File","Disk","Drive","Computer","Container","Seat","Gate","Terminal","Aisle","Unit",
		"LabelL0", "LabelL1", "LabelL2", "LabelL3", "LabelL4",
		"Hanger", "Warehouse", "Port", "Component", 
		"RoomGroup", "HvacArea", "SanitationArea") var PhysicalType: String

#@export var ThingInstanceLabel:String;
#@export var ObjectInstanceGuid:String;
#@export var PrefabPath:String;
	
# Define the exported properties with setters
@export var ThingInstanceLabel: String:
	set(value):
		ThingInstanceLabel = value
		_update_gltf_extras("ThingInstanceLabel", value)

## Will be exported to extras is equal to ThingGuid, read only
@export var ObjectInstanceGuid: String:
	set(value):
		ObjectInstanceGuid = ThingGuid
		_update_gltf_extras("ObjectInstanceGuid", value)
	get():
		return ThingGuid

## Contains path to scene file - tscn
@export var PrefabPath: String:
	set(value):
		PrefabPath = value
		_update_gltf_extras("PrefabPath", value)
		
		
@export var ThingGuid: String

@export_group("Pivot Override")
@export var PivotRotation: Vector3
@export var CamDistanceMultiplier:float = 1

@export_group("Transform Lock")
@export_enum("None", "Zero") var LockX: String
@export_enum("None", "Zero", "FalseCeiling", "Ceiling") var LockY: String
@export_enum("None", "Zero")  var LockZ: String
@export var Messages: String

@export_group("Edges Group")
@export var Edges: String = ""

@export_flags(
"None", "Any", "Type", "Subtype", "Child", "Sibling", "Member", "Owned", "Dependent",
"Instance", "Subject", "Location", "Reference", "Element", "Valuetype", "External"
) var EdgeFlags: int = 1:
	set(value):
		var selected_edges = []
		var edge_names = [
			"None", "Any", "Type", "Subtype", "Child", "Sibling", "Member", "Owned", "Dependent", "Instance", "Subject", "Location", "Reference", "Element", "Valuetype", "External"
		]
		for i in range(edge_names.size()):
			if value & (1 << i):
				selected_edges.append(edge_names[i])
		Edges = ",".join(selected_edges)
		EdgeFlags = value

@export_group("Layer properties")
@export var Layers: String = "Default"

@export_flags(
	"Default", "Always", "Never", "System", "Colorizer", "Reserved1", 
	"Exterior", "Floor", "Foundations", "Walls", "Doors", "Furniture", "Sanitary", "Equipment", "Environment",  
	"Hvac", "Plumbing", "Power", "Network", "Fire", "Security", "Maintenance",
	"LabelL0", "LabelL1", "LabelL2", "LabelL3", "LabelL4"
) var LayerFlags: int = 1:
	set(value):
		var selected_layers = []
		var layer_names = [
			"Default", "Always", "Never", "System", "Colorizer", "Reserved1", 
			"Exterior", "Floor", "Foundations", "Walls", "Doors", "Furniture", "Sanitary", "Equipment", "Environment",  
			"Hvac", "Plumbing", "Power", "Network", "Fire", "Security", "Maintenance",
			"LabelL0", "LabelL1", "LabelL2", "LabelL3", "LabelL4"
		]
		for i in range(layer_names.size()):
			if value & (1 << i):
				selected_layers.append(layer_names[i])
		Layers = ",".join(selected_layers)
		LayerFlags = value

@export_group("Label3D")
@export var LabelText: String = ""
@export var LabelFontSize: float = 4.0
@export var LabelOffset: Vector3 = Vector3(0, 1.5, 0)

@export_group("TimeStateManager")
@export var SceneDateTime: String = ""

@export_group("Edge Instances")
@export var EdgeVertex1: Array[NodePath] = []
@export var EdgeVertex2: Array[NodePath] = []
@export var EdgeInstanceTypes: PackedStringArray = []
@export var EdgeInstanceValues: PackedInt64Array = []

@export_group("TimeState")
@export var TimeStateNotes: String = ""
@export var TimeStateChangesJson: String = ""

var _label3d: Label3D


const properties_thinglink : Array[StringName] = [&"ParentOverride", &"ParentOverride_name", &"ThingInstanceLabel", &"ObjectInstanceGuid", &"PrefabPath", &"ThingGuid"]
const group_thinglink : StringName = "ThingLink properties"

func _validate_property(property : Dictionary) -> void:
	# ------------ EXPORT RELATED GROUP (only on root/AxoExport nodes) ------------
	if property.name == &"_recalc_btn":
		if AxoExport:
			property.usage |= PROPERTY_USAGE_EDITOR
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR

	if property.name in properties_thinglink:
		if useThingLink:
			property.usage |= PROPERTY_USAGE_EDITOR
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR
	
	if property.name == group_thinglink:
		if useThingLink:
			property.usage |= PROPERTY_USAGE_GROUP
		else:
			property.usage &= ~PROPERTY_USAGE_GROUP
			
			
# ------------ PIVOT OVERRIDE GROUP ------------
	if property.name == &"Pivot Override":
		if usePivotOverride:
			property.usage |= PROPERTY_USAGE_GROUP
		else:
			property.usage &= ~PROPERTY_USAGE_GROUP

	if property.name in [&"PivotRotation",&"CamDistanceMultiplier"]:
		if usePivotOverride:
			property.usage |= PROPERTY_USAGE_EDITOR
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR

	# ------------ EDGES GROUP ------------
	if property.name == &"Edges Group":
		if useEdges:
			property.usage |= PROPERTY_USAGE_GROUP
		else:
			property.usage &= ~PROPERTY_USAGE_GROUP

	if property.name in [&"Edges", &"EdgeFlags"]:
		if useEdges:
			property.usage |= PROPERTY_USAGE_EDITOR
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR

	# ------------ LAYER GROUP ------------
	if property.name == &"Layer properties":
		if useLayers:
			property.usage |= PROPERTY_USAGE_GROUP
		else:
			property.usage &= ~PROPERTY_USAGE_GROUP

	if property.name in [&"Layers", &"LayerFlags"]:
		if useLayers:
			property.usage |= PROPERTY_USAGE_EDITOR
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR

	# ------------ TRANSFORM LOCK GROUP ------------
	if property.name == &"Transform Lock":
		if useTransformLock:
			property.usage |= PROPERTY_USAGE_GROUP
		else:
			property.usage &= ~PROPERTY_USAGE_GROUP

	if property.name in [&"LockX", &"LockY", &"LockZ", &"Messages"]:
		if useTransformLock:
			property.usage |= PROPERTY_USAGE_EDITOR
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR

	# ------------ LABEL3D GROUP ------------
	if property.name == &"Label3D":
		if useLabel3D:
			property.usage |= PROPERTY_USAGE_GROUP
		else:
			property.usage &= ~PROPERTY_USAGE_GROUP

	if property.name in [&"LabelText", &"LabelFontSize", &"LabelOffset"]:
		if useLabel3D:
			property.usage |= PROPERTY_USAGE_EDITOR
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR

	# ------------ TIME STATE MANAGER GROUP ------------
	if property.name == &"TimeStateManager":
		if useTimeStateManager:
			property.usage |= PROPERTY_USAGE_GROUP
		else:
			property.usage &= ~PROPERTY_USAGE_GROUP

	if property.name in [&"SceneDateTime"]:
		if useTimeStateManager:
			property.usage |= PROPERTY_USAGE_EDITOR
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR

	# ------------ TIME STATE GROUP ------------
	if property.name == &"TimeState":
		if useTimeState:
			property.usage |= PROPERTY_USAGE_GROUP
		else:
			property.usage &= ~PROPERTY_USAGE_GROUP

	if property.name in [&"TimeStateNotes", &"TimeStateChangesJson"]:
		if useTimeState:
			property.usage |= PROPERTY_USAGE_EDITOR
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR

	# ------------ EDGE INSTANCES GROUP ------------
	if property.name == &"Edge Instances":
		if useEdgeInstances:
			property.usage |= PROPERTY_USAGE_GROUP
		else:
			property.usage &= ~PROPERTY_USAGE_GROUP

	if property.name in [&"EdgeVertex1", &"EdgeVertex2", &"EdgeInstanceTypes", &"EdgeInstanceValues"]:
		if useEdgeInstances:
			property.usage |= PROPERTY_USAGE_EDITOR
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR


func gen_guid() -> String:
	var random = RandomNumberGenerator.new()
	random.randomize()
	var guid:String = ""
	for i in range(32):
		guid += "%x"%[random.randi() % 16]
	if ProjectSettings.get_setting("xbase_plugin/settings/verbose_logging", false):
		print("Generating GUID for node named: %s. GUID: %s"%[self.name,guid])
	return guid

## Recalculates ThingInstanceLabel for all AxNode3D descendants of root.
## Must be called top-down so parent labels resolve before children.
## Logic (ported from Unity XFabExporter.SetInstanceLabel):
##   - Root node: ThingInstanceLabel = ThingLabelOverride, or node name
##   - '&' prefix: concatenate parent's ThingInstanceLabel + rest of label
##     (builds hierarchical paths, e.g. parent "ward_l6_a1" + "&_room1" → "ward_l6_a1_room1")
##   - Non-empty ThingLabelOverride: use directly as ThingInstanceLabel
##   - Empty ThingLabelOverride + empty ThingInstanceLabel: generate GUID fallback
## Returns the number of nodes whose ThingInstanceLabel was changed.
static func recalculate_instance_labels(root: Node) -> int:
	var seen: Dictionary = {}  # label -> node name (first occurrence)
	var count = _recalc_labels_recursive(root, true, 0, seen)
	# Check for duplicate instance labels
	# (seen stores label -> first node name; duplicates are warned inline)
	return count

## Validates that all ThingInstanceLabels are already correct (read-only check).
## Returns the number of nodes whose ThingInstanceLabel would need to change.
## Use before export: if result > 0, labels are stale and export should abort.
## Also checks for duplicates and empty labels on useThingLink nodes.
static func validate_instance_labels(root: Node) -> int:
	var errors = 0
	var seen: Dictionary = {}  # label -> node path
	errors = _validate_labels_recursive(root, true, errors, seen)
	return errors

static func _validate_labels_recursive(node: Node, is_root: bool, errors: int, seen: Dictionary) -> int:
	if node is AxNode3D and (node as AxNode3D).useThingLink:
		var tl: AxNode3D = node as AxNode3D
		var expected = _compute_instance_label(tl, is_root)
		if tl.ThingInstanceLabel != expected:
			push_error("ValidateInstanceLabels: stale label on '%s' — current '%s', expected '%s'. Run RecalculateInstanceLabels first." % [_safe_path(tl), tl.ThingInstanceLabel, expected])
			errors += 1
		if tl.ThingInstanceLabel == "":
			push_error("ValidateInstanceLabels: empty ThingInstanceLabel on '%s'. Run RecalculateInstanceLabels first." % _safe_path(tl))
			errors += 1
		elif seen.has(tl.ThingInstanceLabel):
			# Duplicates are Revit data quality issues (e.g. rooms with same number
			# in different groups) — warn but don't block the export
			push_warning("ValidateInstanceLabels: duplicate ThingInstanceLabel '%s' on '%s' (first seen on '%s')" % [tl.ThingInstanceLabel, _safe_path(tl), seen[tl.ThingInstanceLabel]])
		else:
			seen[tl.ThingInstanceLabel] = _safe_path(tl)
	for child in node.get_children():
		errors = _validate_labels_recursive(child, false, errors, seen)
	return errors

## Recursive helper — is_root is true for the starting node only.
## seen tracks label -> first node name for duplicate detection.
static func _recalc_labels_recursive(node: Node, is_root: bool, count: int, seen: Dictionary) -> int:
	if node is AxNode3D and (node as AxNode3D).useThingLink:
		var tl: AxNode3D = node as AxNode3D
		var new_label = _compute_instance_label(tl, is_root)
		if tl.ThingInstanceLabel != new_label:
			tl.ThingInstanceLabel = new_label
			count += 1
		# Duplicate detection — warn if two nodes resolve to the same label
		if new_label != "":
			if seen.has(new_label):
				push_warning("RecalculateInstanceLabels: duplicate ThingInstanceLabel '%s' on '%s' (first seen on '%s')" % [new_label, _safe_path(tl), seen[new_label]])
			else:
				seen[new_label] = _safe_path(tl)
	for child in node.get_children():
		count = _recalc_labels_recursive(child, false, count, seen)
	return count

## Computes ThingInstanceLabel for a single node.
static func _compute_instance_label(tl: AxNode3D, is_root: bool) -> String:
	if is_root:
		# Root: use label override, fall back to node name
		if tl.ThingLabelOverride != "":
			return tl.ThingLabelOverride
		return tl.name

	if tl.ThingLabelOverride == "":
		# No label override — keep existing or generate GUID fallback
		if tl.ThingInstanceLabel != "":
			return tl.ThingInstanceLabel
		return _generate_guid_label()

	if tl.ThingLabelOverride.begins_with("&"):
		# Concatenate with parent's ThingInstanceLabel
		var label_part: String = tl.ThingLabelOverride.substr(1).rstrip("'")
		var parent_tl = _find_parent_thinglink(tl)
		if parent_tl == null or parent_tl.ThingInstanceLabel.is_empty():
			push_warning("RecalculateInstanceLabels: '%s' uses '&' prefix but no parent ThingLink found" % _safe_path(tl))
			return label_part
		return parent_tl.ThingInstanceLabel + label_part

	# Plain label — use directly
	return tl.ThingLabelOverride

## Walks up the tree to find the nearest parent AxNode3D with useThingLink,
## respecting ParentOverride if set.
static func _find_parent_thinglink(tl: AxNode3D) -> AxNode3D:
	if tl.ParentOverride != null and tl.ParentOverride.useThingLink:
		return tl.ParentOverride
	var parent = tl.get_parent()
	while parent:
		if parent is AxNode3D and (parent as AxNode3D).useThingLink:
			return parent as AxNode3D
		parent = parent.get_parent()
	return null

static func _generate_guid_label() -> String:
	var random = RandomNumberGenerator.new()
	random.randomize()
	var guid = ""
	for i in range(16):
		guid += "%x" % [random.randi() % 16]
	return guid

## Safe node path — works even when the node isn't in the scene tree
## (e.g. during headless export where scenes are instantiated but not added).
static func _safe_path(node: Node) -> String:
	if node.is_inside_tree():
		return str(node.get_path())
	# Build path manually by walking up parents
	var parts: Array = []
	var current = node
	while current:
		parts.push_front(current.name)
		current = current.get_parent()
	return "/".join(parts)

func _enter_tree() -> void:
	if( ThingGuid.length()==0 ):
		ThingGuid = self.gen_guid()
		ObjectInstanceGuid = ThingGuid
	
	
# Helper function to convert enum value to index
func physical_type_to_index(physical_type: String) -> int:
	var enum_values = _load_physical_types()
	return enum_values.find(physical_type)
	
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Initialize gltf_extras if not already present
	if not has_meta("extras"):
		set_meta("extras", {})
	
	# Initialize the gltf_extras with current values
	_update_gltf_extras("ThingInstanceLabel", ThingInstanceLabel)
	_update_gltf_extras("ObjectInstanceGuid", ObjectInstanceGuid)
	_update_gltf_extras("PrefabPath", PrefabPath)
	# we generate GUID
	if( ThingGuid.length()==0 ):
		ThingGuid = self.gen_guid()
	# Re-publish StaticBounds into metadata (set_meta from the @export setter
	# doesn't fire during scene load — only after _ready does the value land
	# in the property, so we mirror it explicitly here for the C++ walker).
	if StaticBounds.size != Vector3.ZERO:
		set_meta("_static_bounds_local", StaticBounds)
	# Build the wireframe gizmo if requested. Deferred to next idle so child
	# meshes have a chance to realise their AABBs (otherwise compute_local_mesh_aabb
	# may return zero on first frame).
	if useBoundsHelper:
		call_deferred("_refresh_bounds_gizmo")

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if useLabel3D:
		if _label3d == null or not is_instance_valid(_label3d):
			_label3d = Label3D.new()
			add_child(_label3d)
			_label3d.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		_label3d.text = LabelText
		_label3d.position = LabelOffset
		_label3d.pixel_size = 0.01
		_label3d.font_size = int(LabelFontSize)
		var cam := get_viewport().get_camera_3d()
		if cam:
			_label3d.look_at(cam.global_transform.origin, Vector3.UP)
	else:
		if _label3d and is_instance_valid(_label3d):
			_label3d.queue_free()
			_label3d = null

func _update_gltf_extras(key: String, value):
	if not has_meta("extras"):
		set_meta("extras", {})
	var extras = get_meta("extras")
	# if(extras == null):
	# 	extras = {}
	extras[key] = value
	set_meta("extras", extras)
	
func prepareForGLTFExport() -> Dictionary:
	var json = {}
	json["type"] = "ThingLinkNode3d"
	json["ThingInstanceLabel"] = self.ThingInstanceLabel
	json["ThingLabelOverride"] = self.ThingLabelOverride
	json["ThingNameOverride"] = self.ThingNameOverride
	#json["ThingLink"] = self.ThingLink
	json["PhysicalType"] = self.PhysicalType

	self.PrefabPath = self.scene_file_path
	if(self.scene_file_path.length()>0):
		json["Prefab"] = self.PrefabPath
	else :
		json["Prefab"] = "-"
	return json

# Export function to convert to GLTF
func _export_gltf(scene_tree: PackedScene):
	# Create an instance of the class
	print("exporting abcdef")
	var instance = AxNode3D.new()
	#instance.ThingLink = "value1"

	# Serialize the instance to JSON
	
	var json_string = JSON.stringify(instance)

	# Add the serialized JSON as metadata in the GLTF (mock process)
	var gltf_file = GLTFDocument.new()
	var gltf_node := GLTFNode.new()
	#gltf_node.set_additional_data("ThingLink", ThingLink)
	
	var gltf_state_save := GLTFState.new()
	#gltf_state_save.set_additional_data("ThingLink", ThingLink)
	
	#var gltf_node = gltf_file.add_node("NodeWithCustomMetadata", Transform.IDENTITY)
	
	# Add custom meta (mock meta field)
	gltf_file.set_meta("custom_data", json_string)

	# Save GLTF
	gltf_file.save("res://my_scene_with_metadata.gltf")
