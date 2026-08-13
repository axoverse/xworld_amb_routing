## Important class to export GLTF extras
extends GLTFDocumentExtension

const PHYSICAL_TYPES_JSON_PATH = "res://addons/xbase_plugin/share/data/physical_types.json"

var _physical_types_cache: Array = []
var _verbose_logging_cache: Variant = null  # null = not checked yet

# Export diagnostics
var _export_node_count: int = 0
var _export_axnode_count: int = 0
var _export_bounds_ms: int = 0
var _export_total_ms: int = 0
var _export_start_ms: int = 0

## Helper function to log only when verbose logging is enabled in project settings
func _log_verbose(msg: Variant, msg2: Variant = "", msg3: Variant = "", msg4: Variant = "") -> void:
	if _verbose_logging_cache == null:
		_verbose_logging_cache = ProjectSettings.get_setting("xbase_plugin/settings/verbose_logging", false)
	if _verbose_logging_cache:
		if str(msg4) != "":
			print(msg, msg2, msg3, msg4)
		elif str(msg3) != "":
			print(msg, msg2, msg3)
		elif str(msg2) != "":
			print(msg, msg2)
		else:
			print(msg)

# Load physical types from shared JSON file
func _load_physical_types() -> Array:
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

# Helper function to convert enum value to index
func physical_type_to_index(physical_type: String) -> int:
	var enum_values = _load_physical_types()
	return enum_values.find(physical_type)

func _process_mesh_instance_bounds(indent: String, node: Node3D, aabb: AABB, has_bounds: bool, parent_translation: Vector3, parent_LB:Vector3, parent_TR: Vector3) -> Dictionary:
	var result: Dictionary[Variant, Variant] = {"aabb": aabb, "has_bounds": has_bounds, "posLB": parent_LB, "posTR":parent_TR}
	result.has_bounds = false
	result.has_bounds = has_bounds
	
	var local_tr = node.transform.origin + parent_translation
	var new_LB = node.transform.origin

	if node is MeshInstance3D:
		var mesh_instance: MeshInstance3D = node as MeshInstance3D
		if mesh_instance.mesh:
			var local_aabb = mesh_instance.get_aabb()
			_log_verbose(indent + "Node:" + node.name + " Local translation:" + str(local_tr) + " RelPosition:" + str(node.transform.origin))
			_log_verbose(indent + "_Mesh XYZ" + str(local_aabb.position) + " EndXYZ:" + str(local_aabb.end) + " SizeXYZ" + str(local_aabb.size))
			_log_verbose(indent + "_In  Extent :" + str(parent_LB) + str(parent_TR))
			#print("Mesh in node",node.name, local_aabb.position.x, local_aabb.position.y, local_aabb.end.x, local_aabb.end.y, local_aabb.size.x, local_aabb.size.y)
			
			var new_position = local_aabb.position + local_tr
			if( has_bounds == true):
				if(new_position.x<= parent_LB.x):
					result.posLB.x = new_position.x
					
				if(new_position.y<= parent_LB.y):
					result.posLB.y = new_position.y

				if(new_position.z<= parent_LB.z):
					result.posLB.z = new_position.z

				var new_positionEnd = local_aabb.end + local_tr
				if(new_positionEnd.x > parent_TR.x):
					result.posTR.x = new_positionEnd.x
					
				if(new_positionEnd.y > parent_TR.y):
					result.posTR.y = new_positionEnd.y
					
				if(new_positionEnd.z > parent_TR.z):
					result.posTR.z = new_positionEnd.z
			else:
				result.posLB.x = new_position.x
				result.posLB.y = new_position.y
				result.posLB.z = new_position.z
				var new_positionEnd = local_aabb.end + local_tr
				result.posTR.x = new_positionEnd.x
				result.posTR.y = new_positionEnd.y
				result.posTR.z = new_positionEnd.z

				
			var labb = AABB(new_position,local_aabb.size)
			
			var local_aabb_in_parents_coords = labb
			var new_aabb = result.aabb.merge( local_aabb_in_parents_coords )
			result.aabb = new_aabb
			result.has_bounds = true
	else: #node has no mesh - then we need to add this node.translation to parent translation, 
		pass

	
	# Recursively process all children
	print_verbose(indent+"_","Out Extent :",result.posLB, result.posTR)
	for child in node.get_children():
		if not (child is Node3D):
			continue
		var child_result: Dictionary = _process_mesh_instance_bounds(indent + "  ",child, result.aabb, result.has_bounds, local_tr, result.posLB, result.posTR)
		if( !child_result ):
			push_warning("Bad object")
		elif( ! child_result.aabb ):
			push_warning("No aabb for node:"+child.name)
		else:
			result.aabb = child_result.aabb
		if(result.has_bounds == false && child_result.has_bounds == true):
			result.has_bounds = child_result.has_bounds
			result.posLB.x = child_result.posLB.x
			result.posLB.y = child_result.posLB.y
			result.posLB.z = child_result.posLB.z
				
			result.posTR.x = child_result.posTR.x
			result.posTR.y = child_result.posTR.y
			result.posTR.z = child_result.posTR.z
			
		elif(child_result.has_bounds == true): #implicitly result.has_bounds also true - so we merge
			if(child_result.posLB.x<=result.posLB.x):
				result.posLB.x = child_result.posLB.x
			if(child_result.posLB.y<=result.posLB.y):
				result.posLB.y = child_result.posLB.y
			if(child_result.posLB.z<=result.posLB.z):
				result.posLB.z = child_result.posLB.z
				
			if(child_result.posTR.x > result.posTR.x):
				result.posTR.x = child_result.posTR.x
			if(child_result.posTR.y > result.posTR.y):
				result.posTR.y = child_result.posTR.y
			if(child_result.posTR.z > result.posTR.z):
				result.posTR.z = child_result.posTR.z
				
			#result = child_result # NEED TO MERGE
			
	print_verbose(indent+"_","Out Extent w children :",result.posLB, result.posTR)

	return result

func processBoundingBox(cNode: Node) -> Dictionary:
	var json: Dictionary[Variant, Variant] = {}
	if not (cNode is AxNode3D) or not (cNode as AxNode3D).useBoundsHelper:
		return json
	json["type"] = "Axomem.XScape.Core.BoundsHelper,XScape.Core"
	json["UseStaticBounds"] = true
	json["RecalcStaticBounds"] = false

# BoundsHelper format
#  {"UseStaticBounds":false,
# "RecalcStaticBounds":false,
# "StaticBounds":{"m_Center":{"x":0.0,"y":0.0,"z":0.0},
# "m_Extent":{"x":0.0,"y":0.0,"z":0.0}}}


	if cNode is Node3D:
		var n3d = cNode as Node3D
		var lets_reset_position = Vector3( n3d.transform.origin.x*-1, n3d.transform.origin.y*-1, n3d.transform.origin.z*-1)
		
		print_verbose("processBoundingBox Starting node: ", cNode.name, " Origin:", n3d.transform.origin)
		var bounds_result = _process_mesh_instance_bounds("--", n3d, AABB(), false, lets_reset_position, Vector3.ZERO, Vector3.ZERO)
		
		if bounds_result.has_bounds:
			# Convert AABB to position and size
			#var position = bounds_result.aabb.position
			#var size = bounds_result.aabb.size
			var posLB = bounds_result.posLB
			var posRT = bounds_result.posTR
			json["StaticBounds"] = {
				"m_Center": {
					"x": (posLB.x + posRT.x )*-0.5,
					"y": (posLB.y + posRT.y ) / 2,
					"z": (posLB.z + posRT.z ) / 2
				},
				"m_Extent": {
					"x": (posRT.x - posLB.x)/2,
					"y": (posRT.y - posLB.y)/2,
					"z": (posRT.z - posLB.z)/2
				}
			}
			#json["StaticBounds"] = {
				#"m_Center": {
					#"x": (position.x + (size.x / 2))*-1,
					#"y": position.y + (size.y / 2),
					#"z": position.z + (size.z / 2)
				#},
				#"m_Extent": {
					#"x": size.x/2,
					#"y": size.y/2,
					#"z": size.z/2
				#}
			#}
	
	return json
	
func processCollisionShape(cNode: Node) -> Dictionary:
	var json: Dictionary[Variant, Variant] = {}

	# Search children for CollisionShape3D
	var collision_shape = _find_collision_shape(cNode)

	if collision_shape and collision_shape.shape:
		json["type"] = "BoxCollider"
		json["IsTrigger"] = true
		json["ProvidesContacts"] = false
		var shape = collision_shape.shape
		# Shape centre in cNode's local space, computed by walking the parent
		# chain rather than via global_position: exported scenes are
		# instantiated without being added to a tree (headless export), where
		# get_global_transform() errors and returns identity — centres came
		# out as (0,0,0) for every offset collider.
		var center = _shape_center_relative_to(collision_shape, cNode)
		var extent = Vector3.ZERO

		# Extract center and size based on shape type
		if shape is BoxShape3D:
			var box_shape = shape as BoxShape3D
			extent = box_shape.size * 0.5  # Extent is half-size
			# Center is typically at origin for BoxShape3D
		elif shape is SphereShape3D:
			var sphere_shape = shape as SphereShape3D
			var size = Vector3(sphere_shape.radius * 2, sphere_shape.radius * 2, sphere_shape.radius * 2)
			extent = size * 0.5
		elif shape is CylinderShape3D:
			var cyl_shape = shape as CylinderShape3D
			extent = Vector3(cyl_shape.radius, cyl_shape.height * 0.5, cyl_shape.radius)
		elif shape is CapsuleShape3D:
			var cap_shape = shape as CapsuleShape3D
			var height = cap_shape.height + cap_shape.radius * 2
			extent = Vector3(cap_shape.radius, height * 0.5, cap_shape.radius)
		
		# Add to json using the same format as processBoundingBox
		json["Center"] = {
			"x": -center.x,
			"y": center.y,
			"z": center.z
		}
		json["Size"] = {
			"x": extent.x,
			"y": extent.y,
			"z": extent.z
		}
	
	return json

# Helper function to recursively search for CollisionShape3D
## Position of `shape` in `ancestor`'s local space, without requiring either
## node to be inside a scene tree (instances are out-of-tree during headless
## export). Equivalent to ancestor.to_local(shape.global_position) when both
## are inside the same tree.
func _shape_center_relative_to(shape: Node3D, ancestor: Node) -> Vector3:
	var t: Transform3D = shape.transform
	var current: Node = shape.get_parent()
	while current and current != ancestor:
		if current is Node3D:
			t = (current as Node3D).transform * t
		current = current.get_parent()
	if current == null:
		# Shape is not a descendant of ancestor — fall back to local position
		return shape.position
	return t.origin

func _find_collision_shape(node: Node) -> CollisionShape3D:
	for child in node.get_children():
		if child is CollisionShape3D:
			return child as CollisionShape3D
		# Recursively search children
		var found = _find_collision_shape(child)
		if found:
			return found
	return null
	
func processNodeParams(cNode: Node, state: GLTFState) -> Dictionary:
	var json = {}
	if cNode is AxNode3D:
		var thNode : AxNode3D = cNode
		if not thNode.useThingLink:
			return json
		json["type"] = "Axomem.XScape.Core.ThingLink,XScape.Core"
		json["ThingInstanceLabel"] = thNode.ThingInstanceLabel
		json["ThingLabelOverride"] = thNode.ThingLabelOverride
		json["ThingNameOverride"] = thNode.ThingNameOverride  # to CSV , for root element it is name
		json["PhysicalType"] = physical_type_to_index(thNode.PhysicalType)
		json["PhysicalTypeString"] = thNode.PhysicalType
		json["ThingGuid"] = thNode.ThingGuid

		if thNode.ParentOverride != null:
			var parent_idx = state.get_node_index(thNode.ParentOverride)
			if parent_idx >= 0:
				json["_nodeRefs"] = { "ParentOverride": parent_idx }
			else:
				_log_verbose("ParentOverride target not in GLTF: ", thNode.ParentOverride.name)

		thNode.PrefabPath = thNode.scene_file_path
		if(thNode.scene_file_path.length()>0):
			json["Prefab"] = thNode.PrefabPath
		else :
			json["Prefab"] = "-"
	return json
	
# adding Layer component to GLB/GLTF
func processLayerComponent(cNode: Node) -> Dictionary:
	var json = {}
	if cNode is AxNode3D:
		var thNode : AxNode3D = cNode
		if(thNode.useLayers && thNode.Layers.length() > 0):
			json["type"] = "Axomem.XScape.Core.Layer,XScape.Core"
			json["Layers"] = thNode.Layers
			json["Validation"] = "OK"
			_log_verbose("Found Layer:", json)
		else:
			for childNode in cNode.get_children():
				if childNode is AxLayer:
					var lNode : AxLayer = childNode
					json["type"] = "Axomem.XScape.Core.Layer,XScape.Core"
					json["Layers"] = lNode.Layers
					json["Validation"] = "OK"
					_log_verbose("Found Layer (child):", json)
					break
	
	return json


func processEdgeComponent(cNode: Node) -> Dictionary:
	var json = {}
	if cNode is AxNode3D:
		var thNode : AxNode3D = cNode
		if(thNode.useEdges && thNode.Edges.length() > 0):
			json["type"] = "Axomem.XScape.Core.Edge,XScape.Core"
			json["Edges"] = thNode.Edges
			json["Validation"] = "OK"
			_log_verbose("Found Edges:", json)
	
	return json

func processRoutingWaypoint(cNode: Node) -> Dictionary:
	var json = {}
	if cNode is AxNode3D:
		var thNode : AxNode3D = cNode
		if(thNode.isRoutingWaypoint):
			json["type"] = "Axomem.XWorld.RoutingWaypoint,XWorld"
	return json

# adding PivotOverride component to GLB/GLTF
func processPivotOverrideComponent(cNode: Node) -> Dictionary:
	var json = {}
	if cNode is AxNode3D:
		var thNode : AxNode3D = cNode
		if(thNode.usePivotOverride):
			json["type"] = "Axomem.XScape.Core.PivotOverride,XScape.Core"
			json["Rotation"] = { "x": thNode.PivotRotation.x, "y": thNode.PivotRotation.y, "z": thNode.PivotRotation.z }
			json["CamDistanceMultiplier"] = thNode.CamDistanceMultiplier
			return json
	return json
	
# adding TransformLock component to GLB/GLTF
func processTransformLockComponent(cNode: Node) -> Dictionary:
	var json = {}
	if cNode is AxNode3D:
		var thNode : AxNode3D = cNode
		if(thNode.useTransformLock):
			json["type"] = "Axomem.XWorld.LockTransform,XWorld"
			json["LockX"] = thNode.LockX
			json["LockY"] = thNode.LockY
			json["LockZ"] = thNode.LockZ
			json["Messages"] = thNode.Messages
	return json

func processVisibility(cNode: Node) -> Dictionary:
	var json = {}
	if cNode is AxNode3D:
		var thNode : AxNode3D = cNode
		if(!thNode.useTimeState or !thNode.useTimeStateManager):
			if(!cNode.visible):
				json["type"] = "NonTimeStateInvisible"
				json["Messages"] = thNode.Messages
	return json

func _export_preflight(state: GLTFState, root: Node) -> Error:
	# Reset diagnostic counters so they're clean if the extension is reused across scenes
	_export_node_count = 0
	_export_axnode_count = 0
	_export_bounds_ms = 0
	_export_total_ms = 0
	_export_start_ms = 0
	return OK

func _export_node ( state:GLTFState,  gltf_node:GLTFNode,  json:Dictionary,  node:Node ) -> Error :
	if _export_start_ms == 0:
		_export_start_ms = Time.get_ticks_msec()
	_export_node_count += 1

	if node is AxNode3D:
		_export_axnode_count += 1
		var thNode : AxNode3D = node
		print_verbose("_export_node thNode:"+thNode.name)
		var node_extras = self.processNodeParams(node, state)
		node_extras["axoprop"] = "abcd"

		var t0 = Time.get_ticks_msec()
		var node_extras_bb = self.processBoundingBox(node)
		_export_bounds_ms += Time.get_ticks_msec() - t0

		var node_coll = self.processCollisionShape(node)
		var node_layer = self.processLayerComponent(node)
		var node_pivot = self.processPivotOverrideComponent(node)
		var node_route = self.processRoutingWaypoint(node)
		var node_edge = self.processEdgeComponent(node)
		var node_transform_lock = self.processTransformLockComponent(node)
		var node_notvisible = self.processVisibility(node)

		var all_components = [node_extras, node_extras_bb, node_layer, node_pivot, node_transform_lock, node_route, node_edge, node_coll, node_notvisible]
		all_components = all_components.filter(func(component): return component.keys().size() > 0) # removing empty components

		var cidx = 1
		var extras:Dictionary

		for component in all_components:
			if component.has("type"):
				extras[str(cidx)] = component
			cidx += 1

		json["extras"] = extras

	return OK

func _export_post(state: GLTFState) -> Error:
	_export_total_ms = Time.get_ticks_msec() - _export_start_ms if _export_start_ms > 0 else 0
	print("  GLTF extras diagnostics: %d nodes visited, %d AxNode3D processed, bounds=%dms, total_extras=%dms" % [_export_node_count, _export_axnode_count, _export_bounds_ms, _export_total_ms])
	return OK
