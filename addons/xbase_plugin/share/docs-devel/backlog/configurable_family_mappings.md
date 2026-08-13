# Configurable Family-to-Property Mappings

## Problem

`sync_am_thinglink.gd` currently uses hardcoded constants to map Revit `family_name` metadata to AxNode3D properties:

- `THINGLINK_ENABLERS` - exact family_name -> PhysicalType (e.g. wall, door)
- `LAYER_ENABLERS` - exact family_name -> {layer, flags}
- `BED_FAMILY_SUBSTRINGS` - case-insensitive substring match for beds

This is fragile: new Revit families (e.g. "CPG_Electric Beds_ Critical care", "MED_Patient Bed", "Bed - Recovery") require code changes. Different projects may use entirely different family naming conventions.

## Current State

Beds are handled via substring matching (`BED_FAMILY_SUBSTRINGS = ["bed"]`) which auto-maps any family containing "bed" to PhysicalType "Bed" + Layer "Furniture". Other mappings (walls, floors) use exact dictionary keys.

## Proposed Solution

Move family-to-property mappings into a JSON config file under `share/data/`, similar to how `physical_types.json` and `layers.json` already work.

### Suggested schema: `share/data/family_mappings.json`

```json
{
  "exact": {
    "Basic Wall": {
      "physical_type": "Room",
      "layer": "Walls",
      "layer_flags": 512
    },
    "Floor": {
      "physical_type": null,
      "layer": "Floor",
      "layer_flags": 128
    }
  },
  "patterns": [
    {
      "substring": "bed",
      "case_insensitive": true,
      "physical_type": "Bed",
      "layer": "Furniture",
      "layer_flags": 2048
    },
    {
      "substring": "door",
      "case_insensitive": true,
      "physical_type": "None",
      "layer": "Doors",
      "layer_flags": 1024
    }
  ]
}
```

### Benefits

- No code changes needed for new family names
- Projects can override with project-specific mappings
- Pattern matching handles naming variations automatically
- JSON is human-editable and version-controllable

### Other settings to consider making configurable

- `WARD_ROOM_TYPES` (currently `["GWS", "HDU"]`) - which room type codes form wards
- `ROOM_UNIT_MESH_PATH` / `AREA_MATERIAL_PATH` - ward/area geometry resources
- Room identification method (currently `metadata/type_name == "Room"`)
- Bed-to-room assignment Y-tolerance (beds at slightly different heights)
- Ward ID format (currently `<level>_<block>` from room number parsing)
- Room number parsing format (currently `RM-<level>-<block>-<code>-<id>`)

### Implementation Notes

- Load JSON once in `execute()`, cache in instance var
- Fall back to hardcoded defaults if JSON not found (backwards compatible)
- Consider project setting `xbase_plugin/settings/family_mappings_path` for custom location
- Validate JSON schema on load, warn on unknown keys
