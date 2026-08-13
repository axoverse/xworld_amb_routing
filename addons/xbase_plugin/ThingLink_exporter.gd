## Place where export logic is planned to be, after refactoring - not used just now
extends RefCounted

class_name ThingLinkExporter

var max_elements

func print_node_info_recursive(node, indent_level) -> void:
	if(max_elements > 1000):
		return
	max_elements = max_elements + 1
	if indent_level>10:
		return
	# Print information about this node
	var indent: String = " ".repeat(indent_level*4)
	print_verbose(" ".repeat(indent_level*4-2) + "{")
	print_verbose(indent + '"Node": "' + node.name + '",')
	print_verbose(indent + '"Type": "' + node.get_class() + '",' )

	#Node_name: node.name
	#Type: node.get_class()   - typically Node3D
	#"instance_of_scene: node.scene_file_path
	#Position: node.position
	#"GlobalPosition":  n3d.global_position    Vector3D: (6.318055, 0, -18.54102)
	#"LocalPosition": n3d.position
	
	# Print position if the node has a position property
	if node is Node2D:
		print_verbose(indent + "  Position: " + str(node.position) + " name" + node.name)
	elif node is Control:
		print_verbose(indent + "  Position: " + str(node.rect_position))
	elif node is Node3D:
		#print("2")
		
		var n3d: Node3D = node as Node3D
		if n3d.is_visible_in_tree() == false:
			return
		var instance_name: String = n3d.scene_file_path
		
		var is_instanced_scene: bool = true # n3d.filename != ""
		if( instance_name.is_empty() ):
			is_instanced_scene = false
		elif(instance_name.begins_with("res://models/AMB/AMB") ):
			is_instanced_scene = true
		elif(instance_name.begins_with("res://models") ):
			is_instanced_scene = false
			
		
		
		if is_instanced_scene == true:
			#print(indent + "  Children: " + str(n3d.get_child_count()))
			var node_pure: Node = n3d as Node
			
			print(indent + '"Instance":"' + str(instance_name ) + '",')
			if n3d is Node3D:
				var global_pos: Vector3 = n3d.global_position
				print(indent + '"Global_Position": "' + str(global_pos) + '",')
				
				var local_pos: Vector3 = n3d.position
				print(indent + '"Local_Position": "' + str(local_pos) + '",')
				
				print(indent + '"Scale": "' + str(n3d.scale) + '",')
				if(indent_level>1):
					print(" ".repeat(indent_level*4-2) + "}")
					is_instanced_scene = false
					#return

	#elif node is Spatial:
	#	print(indent + "  Position: " + str(node.translation))

	# Recursively print information for all children
		if( is_instanced_scene == false or indent_level==1):
			var allc: Array[Node] = node.get_children(false)
			for child in allc:
				print_node_info_recursive(child, indent_level + 1)
	print_verbose(" ".repeat(indent_level*4-2) + "},")
		
# 
func print_node_info(editor_interface: EditorInterface ):
	print_verbose("Printing node information:")
	max_elements = 0
	#var editor_interface = get_editor_interface()
	var scene_root: Node = editor_interface.get_edited_scene_root()

	# Recursively print information for all children
	if scene_root:
		print_node_info_recursive(scene_root, 1)
	else:
		print_verbose("No scene root found.")
		
		
	
