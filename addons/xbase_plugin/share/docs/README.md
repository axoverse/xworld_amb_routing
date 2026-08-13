# xworld_xbase_plugin

Python utilities for working with ThingLink metadata in GLTF files.

## Overview

This package provides tools for injecting xScape ThingLink metadata into GLTF files, enabling interoperability between:
- Godot (via xbase_plugin)
- Unity (via XScape)
- External tools (Revit, BIM software)

## Installation

```bash
cd godot_proj/addons/xbase_plugin
pip install -e .

# Or install dependencies directly
pip install -r requirements.txt
```

## Quick Start

### Injecting ThingLink Data

```python
from xworld_xbase_plugin import ThingLinkInjector

# Load a GLTF file
injector = ThingLinkInjector("hospital.gltf")

# Add ThingLink metadata to nodes
injector.add_thinglink(
    "Room_101",
    thing_instance_label="hospital-room-101",
    physical_type="Room",
    thing_name_override="Room 101"
)

injector.add_layer("Room_101", ["Default", "Walls", "Doors"])

# Save the modified GLTF
injector.save("hospital_with_metadata.gltf")
```

### Using Mapping Files

```bash
# From CSV
thinglink-inject input.gltf mapping.csv output.gltf

# From JSON
thinglink-inject input.gltf mapping.json output.gltf
```

## Data Files

The package uses shared JSON data files in `share/data/`:

- `physical_types.json` - Physical location types (Site, Building, Room, Bed, etc.)
- `layers.json` - Visibility layer names (Default, Walls, Equipment, etc.)
- `edges.json` - Relationship edge types (child, sibling, location, etc.)

These files are shared with the GDScript implementation for consistency.

## Running Tests

```bash
cd godot_proj/addons/xbase_plugin

# Run all Python tests
pytest

# Run Python tests only (skip Godot)
pytest -m "not godot"

# Run Godot tests only
pytest -m godot

# Run with coverage
pytest --cov=share/scripts/xworld_xbase_plugin
```

## Package Structure

```
share/
├── data/                    # Shared JSON data files
│   ├── physical_types.json
│   ├── layers.json
│   └── edges.json
├── scripts/
│   └── xworld_xbase_plugin/ # Python package
│       ├── __init__.py
│       └── thinglink_injector.py
├── tests/                   # pytest tests
│   ├── conftest.py
│   ├── test_data_loading.py
│   ├── test_thinglink_injector.py
│   └── test_godot_integration.py
└── docs/                    # Documentation
    ├── README.md
    ├── thinglink_injector.md
    └── backlog/
```

## API Reference

See [thinglink_injector.md](thinglink_injector.md) for detailed API documentation.

