# ThingLink Injector API Reference

## Classes

### ThingLinkInjector

Main class for injecting ThingLink metadata into GLTF files.

```python
from xworld_xbase_plugin import ThingLinkInjector

injector = ThingLinkInjector("input.gltf")
```

#### Methods

##### `get_node_names() -> List[str]`

Returns list of all node names in the GLTF.

##### `find_node_index(name: str) -> Optional[int]`

Find a node by name (case-insensitive partial match).

##### `add_thinglink(node, thing_instance_label, physical_type="None", ...)`

Add ThingLink component to a node.

Parameters:
- `node`: Node name or index
- `thing_instance_label`: Unique identifier for the thing
- `physical_type`: Type from PHYSICAL_TYPES (default: "None")
- `thing_name_override`: Display name (optional)
- `thing_label_override`: Label override, use "&" prefix for relative (optional)
- `prefab`: Prefab path (optional)

##### `add_layer(node, layers: List[str])`

Add Layer component to a node.

##### `add_edge(node, edges: List[str])`

Add Edge component to a node.

##### `add_bounds(node, center, extent)`

Add BoundsHelper component to a node.

##### `add_pivot_override(node, rotation, cam_distance_multiplier)`

Add PivotOverride component to a node.

##### `inject_from_csv(csv_path: str) -> int`

Inject from CSV mapping file. Returns count of updated nodes.

##### `inject_from_json(json_path: str) -> int`

Inject from JSON mapping file. Returns count of updated nodes.

##### `save(output_path: str)`

Save modified GLTF to file.

---

### Component Data Classes

#### ThingLinkComponent

```python
from xworld_xbase_plugin import ThingLinkComponent

component = ThingLinkComponent(
    thing_instance_label="hospital-room-101",
    physical_type="Room",
    thing_name_override="Room 101"
)
```

#### BoundsComponent

```python
from xworld_xbase_plugin import BoundsComponent

component = BoundsComponent(
    center=(0, 1.5, 0),
    extent=(5, 1.5, 3)
)
```

#### LayerComponent

```python
from xworld_xbase_plugin import LayerComponent

component = LayerComponent(layers=["Default", "Walls", "Doors"])
```

#### EdgeComponent

```python
from xworld_xbase_plugin import EdgeComponent

component = EdgeComponent(edges=["child", "location"])
```

---

## Mapping File Formats

### CSV Format

```csv
node_name,thing_instance_label,physical_type,thing_name,layers
Room_101,hospital-room-101,Room,Room 101,"Default,Walls,Doors"
Bed_101,hospital-bed-101,Bed,Bed 101,Equipment
```

### JSON Format

```json
{
  "nodes": [
    {
      "node_name": "Room_101",
      "thing_instance_label": "hospital-room-101",
      "physical_type": "Room",
      "thing_name": "Room 101",
      "layers": ["Default", "Walls", "Doors"]
    }
  ]
}
```

---

## GLTF Extras Format

The injector adds metadata to GLTF node `extras` as numbered components:

```json
{
  "extras": {
    "1": {
      "type": "Axomem.XScape.Core.ThingLink,XScape.Core",
      "ThingInstanceLabel": "hospital-room-101",
      "PhysicalType": 7,
      "PhysicalTypeString": "Room"
    },
    "2": {
      "type": "Axomem.XScape.Core.Layer,XScape.Core",
      "Layers": "Default,Walls,Doors",
      "Validation": "OK"
    }
  }
}
```

This format is compatible with:
- Godot xbase_plugin (import extension planned)
- Unity XScape ThingLink system

