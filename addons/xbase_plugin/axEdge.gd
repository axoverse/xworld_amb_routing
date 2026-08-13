@tool

class_name AxoEdge

extends Node3D

@export_group("Edge properties")
@export_flags(
"None", "Any", "Type", "Subtype", "Child", "Sibling", "Member", "Owned", "Dependent",
"Instance", "Subject", "Location", "Reference", "Element", "Valuetype", "External"
) var EdgeFlags: int = 1:
	set(value):
		# Convert the flags to a comma-separated string of layer names
		var selected_edges = []
		var edge_names = ["None", "Any", "Type", "Subtype", "Child", "Sibling", "Member", "Owned", "Dependent", "Instance", "Subject", "Location", "Reference", "Element", "Valuetype", "External"
		]
		for i in range(edge_names.size()):
			if value & (1 << i):
				selected_edges.append(edge_names[i])
		Edges = ",".join(selected_edges)
		EdgeFlags = value

var Edges: String = "Default":
	set(value):
		Edges = value

func _ready():
	visible = false

func set_visible(value):
	visible = false

func get_visible():
	return false
	
func _enter_tree() -> void:
	self.visible = false
