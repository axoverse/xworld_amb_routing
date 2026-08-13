# BACKLOG: Code Generation from JSON

## Status: Future Enhancement

This document describes a planned enhancement to auto-generate GDScript code from the shared JSON data files.

## Problem

GDScript `@export_enum` annotations require literal strings at compile time and cannot be populated from loaded data. This means the enum strings in `axNode3D.gd` must be manually kept in sync with `physical_types.json`.

Example of the current limitation:

```gdscript
# This works - literal string:
@export_enum("None", "Site", "Building", "Room") var PhysicalType: int = 0

# This does NOT work - dynamic string:
var enum_string = ",".join(_load_physical_types())
@export_enum(enum_string) var PhysicalType: int = 0  # ERROR
```

## Proposed Solution

Use a `make`-based code generation approach:

1. **JSON files remain the source of truth** in `share/data/`
2. **Python script generates GDScript snippets** from JSON
3. **Generated code is inserted** into target `.gd` files via markers
4. **make generate** runs the generator before builds

### Generator Script

```python
#!/usr/bin/env python3
# generate_gdscript.py

import json
from pathlib import Path

DATA_DIR = Path(__file__).parent.parent / "share/data"
OUTPUT_DIR = Path(__file__).parent.parent

def generate_export_enum(json_file: str, prefix: str) -> str:
    """Generate @export_enum string from JSON array."""
    with open(DATA_DIR / json_file) as f:
        items = json.load(f)
    return f'@export_enum("{",".join(items)}")'

def main():
    # Generate physical types enum
    physical_enum = generate_export_enum("physical_types.json", "PhysicalType")
    
    # Read axNode3D.gd
    axnode_path = OUTPUT_DIR / "axNode3D.gd"
    content = axnode_path.read_text()
    
    # Replace between markers
    # # GENERATED_PHYSICAL_TYPES_START
    # @export_enum(...) var PhysicalType: int = 0
    # # GENERATED_PHYSICAL_TYPES_END
    
    # ... replacement logic ...

if __name__ == "__main__":
    main()
```

### Markers in GDScript

```gdscript
# axNode3D.gd

## GENERATED_PHYSICAL_TYPES_START - do not edit manually
@export_enum("None","Site","Building","Wing","Ward","Level","Corridor","Room","Bed","Vehicle","House","Cabinet","Road","Area","Jurisdiction","UtilityItem","Bathroom","WaterTap","WaterOutlet","Sink","Drain","Toilet","Shower","Urinal","HvacSupplyAirVent","HvacReturnAirIntake","HvacExhaustAirIntake","HvacAhu","HvacFcu","Other","MeetingRoom","Desk","Cluster","Zone","District","Locality","Shelf","Rack","Table","Elevator","Hall","Apartment","Folder","File","Disk","Drive","Computer","Container","Seat","Gate","Terminal","Aisle","Unit","LabelL0","LabelL1","LabelL2","LabelL3","LabelL4","Hanger","Warehouse","Port","Component","RoomGroup","HvacArea","SanitationArea") var PhysicalType: int = 0
## GENERATED_PHYSICAL_TYPES_END
```

### Makefile

```makefile
.PHONY: generate test

generate:
	python3 scripts/generate_gdscript.py

test: generate
	pytest
	godot --headless --script tests/test_runner.gd -- --all
```

## Benefits

1. **Single source of truth** - JSON files define all values
2. **No runtime overhead** - enum strings are compiled in
3. **Editor support** - @export_enum still works in Godot editor
4. **Automated updates** - CI can regenerate on commit

## Tasks to Implement

- [ ] Create `scripts/generate_gdscript.py`
- [ ] Add generation markers to `axNode3D.gd`
- [ ] Add generation markers to `axLayer.gd` and `axEdge.gd`
- [ ] Create Makefile with `generate` target
- [ ] Add CI step to verify generated code is up to date
- [ ] Update documentation

## Notes

- The runtime JSON loading in `physical_type_to_index()` can coexist with generated enums
- Generated code should include a header comment warning not to edit manually
- Consider also generating Unity C# files from the same JSON

