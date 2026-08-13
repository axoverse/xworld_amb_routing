@tool

class_name AxLayer

extends Node3D

@export_group("Layer properties")
@export_flags(
	"Default", "Always", "Never", "System", "Colorizer", "Reserved1", 
	"Exterior", "Floor", "Foundations", "Walls", "Doors", "Furniture", "Sanitary", "Equipment", "Environment",  
	"Hvac", "Plumbing", "Power", "Network", "Fire", "Security", "Maintenance",
	"LabelL0", "LabelL1", "LabelL2", "LabelL3", "LabelL4"
) var LayerFlags: int = 1:
	set(value):
		# Convert the flags to a comma-separated string of layer names
		var selected_layers: Array[Variant] = []
		var layer_names: Array[Variant]     = [
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

var Layers: String = "Default":
	set(value):
		Layers = value

func _ready():
	visible = false

func set_visible(value):
	visible = false

func get_visible():
	return false
	
func _enter_tree() -> void:
	self.visible = false
