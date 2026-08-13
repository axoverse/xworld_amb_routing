## I am not sure it is used now - xbase_plugin.gd connects to buttons from the code by first loading scene xBasePluginScene.tscn and then getting buttons by node name
extends Button

@export var addRBtn: Button

var xb_parent 
# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass

func _enter_tree():
	pass
	#pressed.connect(clicked)


func clicked():
	pass
	#print("Dock button clicked!")
	#xb_parent.add_node_button_pressed()
	
