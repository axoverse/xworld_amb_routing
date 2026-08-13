Write A new plugin module in the xbase plugin add-on folder. When run, IT will scan all TSCN files in The current project and look for nodes with metadata exported from Axoverse Studio Asset Management module. IT will do this by looking for checking each node for metadata "metadata/element_id="

this is probably going to be faster by simply iterating The TSCN files directly on The file system And using line pattern matching, rather than trying to first OPEN in godot.

If found it then needs to OPEN The TSCN in Godot, and 
- Check the metadata as follows:
    - Check ThingLink enablers
        - if the family name is one of these, you'll be setting setting useThingLink = true, otherwise set to false
          set PhysicalType based on metadata/family_name
          - "Bed": "Bed"

    - Check layer Enablers
        - if the metadata/family_name is one of these, you will be setting set "useLayers = true" otherwise set to false
            - "Basic Wall": Walls 
            - "Floor": Floor
            - "CPG_Electric_Beds": furniture
    
    if either of useThingLink are true: 
        - Check if the node has a script "res://addons/xbase_plugin/axNode3D.gd" which is ExtResource("69_ivd8p"), if not add it and set as above
    if all are false and the node has the script
        - remove the script

Here are some examples looking at TSCN side but you need to do via Godot APi.

Keep a log of files touched and actions, and the total added, updated, removed and write to console at end. 

```
[node name="Basic_Wall__CPG_Int_ALC_150__14530339" type="MeshInstance3D" parent="Walls/Basic_Wall"]
transform = Transform3D(-3.99959e-07, 0, 0.15, 0, 1, 0, -9.14999, 0, -6.55671e-09, 311.475, 41.45, -276.768)
material_override = ExtResource("mat_wall_basic_wall_5194af31")
mesh = ExtResource("mesh_0")
script = ExtResource("69_ivd8p")
useThingLink = false
useLayers = true
Layers = "Walls"
LayerFlags = 512
metadata/element_id = 14530339
metadata/family_name = "Basic Wall"
metadata/segment_count = 1
metadata/segment_index = 1
metadata/segment_role = "wall"
metadata/source = "EGH-OSJV-CN-05-M-W-00 WSO 5TH STOREY.rvt : 1"
metadata/type_name = "CPG_Int_ALC_150"

[node name="Floor__MHT_300mm_THK_RC_Slab__3185354" type="MeshInstance3D" parent="Floors/Floor"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 47.600296, 0)
material_override = ExtResource("mat_floor_floor_d268c9c4")
mesh = ExtResource("mesh_38")
script = ExtResource("69_ivd8p")
useThingLink = false
useLayers = true
Layers = "Floor"
LayerFlags = 128
metadata/element_id = 3185354
metadata/family_name = | "Floor"
metadata/source = "EGH-OSJV-CN-05-M-W-00 CBP 5TH STOREY.rvt : 16"
metadata/type_name = "MHT_300mm THK_RC_Slab"

[node name="CPG_Electric_Beds__CPG_Electric_Beds__1805305" type="MeshInstance3D" parent="Beds/CPG_Electric_Beds"]
transform = Transform3D(2.2, 0, -6.82552e-15, 0, 0.849284, 0, 1.3651e-14, 0, 1.1, -1.85322, 38.65, -284.723)
material_override = ExtResource("mat_bed_default")
mesh = ExtResource("mesh_0")
script = ExtResource("69_ivd8p")
useLayers = true
PhysicalType = "Bed"
Layers = "Furniture"
LayerFlags = 2048
metadata/element_id = 1805305
metadata/family_name = "CPG_Electric Beds"
metadata/height_ft = 2.786366224288942
metadata/length_ft = 7.217847769028872
metadata/source = "EGH-OSJV-CN-05-M-W-00 FFE 5TH STOREY.rvt : 15"
metadata/type_name = "CPG_Electric Beds"
metadata/width_ft = 3.608923884514436


```