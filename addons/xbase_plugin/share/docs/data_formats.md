# Data Formats Reference

## Shared JSON Data Files

The package uses shared JSON files located in `share/data/`. These files are the single source of truth for both Python and GDScript implementations.

### physical_types.json

Array of physical location type names. Index position determines the numeric ID.

```json
[
  "None",        // 0
  "Site",        // 1
  "Building",    // 2
  "Wing",        // 3
  "Ward",        // 4
  "Level",       // 5
  "Corridor",    // 6
  "Room",        // 7
  "Bed",         // 8
  // ... more types
]
```

### layers.json

Array of visibility layer names. Used for filtering objects in the 3D view.

```json
[
  "Default",
  "Always",
  "Never",
  "System",
  "Colorizer",
  "Reserved1",
  "Exterior",
  "Floor",
  "Foundations",
  "Walls",
  "Doors",
  "Furniture",
  // ... more layers
]
```

### edges.json

Array of relationship edge types for linking objects in the ThingLink graph.

```json
[
  "none",
  "any",
  "type",
  "subtype",
  "child",
  "sibling",
  "member",
  "owned",
  "dependent",
  "instance",
  "subject",
  "location",
  "reference",
  "element",
  "valuetype",
  "external"
]
```

---

## Usage

### Python

```python
from xworld_xbase_plugin import PHYSICAL_TYPES, LAYER_NAMES, EDGE_TYPES

# Get index of a physical type
room_index = PHYSICAL_TYPES.index("Room")  # Returns 7

# Validate a layer name
is_valid = "Walls" in LAYER_NAMES  # True
```

### GDScript

```gdscript
# In axo_gltfex.gd or axNode3D.gd
var types = _load_physical_types()  # Loads from JSON
var index = types.find("Room")  # Returns 7
```

---

## Modifying Data

When adding new values:

1. Edit the JSON file in `share/data/`
2. Add new values at the END of the array (to preserve indices)
3. Update any documentation
4. Run tests to verify

**Important**: Changing the order of existing values will break compatibility with existing exports!

