"""
GLTF validation tests using pygltflib.

These tests read exported GLB files and validate that the extras
match expected values from the test fixtures.

Run with: pytest -m gltf_validation
"""

import json
from pathlib import Path
from typing import Dict, List, Any, Optional
import pytest

# Mark all tests in this module
pytestmark = pytest.mark.gltf_validation


def pytest_addoption(parser):
    """Add custom CLI options for GLB validation."""
    try:
        parser.addoption(
            "--glb",
            action="store",
            default=None,
            help="Path to a specific GLB file to validate"
        )
        parser.addoption(
            "--expected",
            action="store",
            default=None,
            help="Path to expected values JSON file"
        )
    except ValueError:
        # Options may already be registered by conftest.py
        pass


def get_output_dir() -> Path:
    """Get the tests/output directory."""
    return Path(__file__).parent.parent.parent / "tests" / "output"


# Use .gltf extension (text JSON format) for easier parsing
GLTF_EXT = ".gltf"


def get_fixtures_dir() -> Path:
    """Get the tests/fixtures directory."""
    return Path(__file__).parent.parent.parent / "tests" / "fixtures"


def load_expected_extras() -> Dict:
    """Load expected_extras.json."""
    expected_path = get_fixtures_dir() / "expected_extras.json"
    if expected_path.exists():
        with open(expected_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    return {}


def parse_gltf_extras(gltf) -> Dict[str, Dict]:
    """
    Parse GLTF node extras into a structured format.
    
    Returns: {node_name: {components: [...]}}
    """
    result = {}
    
    for node in gltf.nodes:
        if node.name and node.extras:
            components = []
            
            # Extras are numbered: "1", "2", etc.
            for key in sorted(node.extras.keys(), key=lambda k: int(k) if k.isdigit() else 999):
                if not key.isdigit():
                    continue
                    
                comp = node.extras[key]
                if not isinstance(comp, dict):
                    continue
                
                # Determine component type from the "type" field
                type_str = comp.get("type", "")
                if "ThingLink" in type_str:
                    components.append({
                        "type": "ThingLink",
                        "ThingInstanceLabel": comp.get("ThingInstanceLabel"),
                        "PhysicalType": comp.get("PhysicalType"),
                        "PhysicalTypeString": comp.get("PhysicalTypeString"),
                    })
                elif "Layer" in type_str:
                    components.append({
                        "type": "Layer",
                        "Layers": comp.get("Layers"),
                    })
                elif "Edge" in type_str:
                    components.append({
                        "type": "Edge",
                        "Edges": comp.get("Edges"),
                    })
                elif "PivotOverride" in type_str:
                    components.append({
                        "type": "PivotOverride",
                    })
                elif "BoundsHelper" in type_str:
                    components.append({
                        "type": "BoundsHelper",
                    })
            
            if components:
                result[node.name] = {"components": components}
    
    return result


def validate_node_components(
    actual: Dict[str, Dict],
    expected: Dict[str, Dict],
    errors: List[str]
) -> bool:
    """Validate that actual node components match expected."""
    all_valid = True
    
    for node_name, expected_data in expected.items():
        if node_name.startswith("_"):  # Skip comment fields
            continue
            
        if node_name not in actual:
            errors.append(f"Node '{node_name}' not found in GLTF")
            all_valid = False
            continue
        
        actual_comps = actual[node_name].get("components", [])
        expected_comps = expected_data.get("components", [])
        
        for exp_comp in expected_comps:
            comp_type = exp_comp.get("type")
            
            # Find matching component in actual
            matching = [c for c in actual_comps if c.get("type") == comp_type]
            
            if not matching:
                errors.append(f"Node '{node_name}': Missing {comp_type} component")
                all_valid = False
                continue
            
            actual_comp = matching[0]
            
            # Validate specific fields
            for key, exp_value in exp_comp.items():
                if key == "type":
                    continue
                    
                actual_value = actual_comp.get(key)
                
                if exp_value is not None and actual_value != exp_value:
                    errors.append(
                        f"Node '{node_name}' {comp_type}.{key}: "
                        f"expected '{exp_value}', got '{actual_value}'"
                    )
                    all_valid = False
    
    return all_valid


@pytest.fixture
def expected_extras() -> Dict:
    """Load expected extras for all fixtures."""
    return load_expected_extras()


class TestMinimalScene:
    """Tests for minimal_thinglink_scene.gltf."""
    
    def test_minimal_scene_exists(self):
        """Minimal scene GLTF should exist."""
        gltf_path = get_output_dir() / f"minimal_thinglink_scene{GLTF_EXT}"
        if not gltf_path.exists():
            pytest.skip("GLTF not found - run 'godot --headless --script test_runner.gd -- --export-only' first")
    
    def test_minimal_scene_has_thinglink_extras(self, expected_extras):
        """Minimal scene should have ThingLink extras on root node."""
        pytest.importorskip("pygltflib")
        from pygltflib import GLTF2
        
        gltf_path = get_output_dir() / f"minimal_thinglink_scene{GLTF_EXT}"
        if not gltf_path.exists():
            pytest.skip("GLTF not found")
        
        gltf = GLTF2().load(str(gltf_path))
        actual = parse_gltf_extras(gltf)
        expected = expected_extras.get("minimal_thinglink_scene", {})
        
        errors = []
        valid = validate_node_components(actual, expected, errors)
        
        if not valid:
            pytest.fail("\n".join(errors))
    
    def test_minimal_scene_physical_types(self):
        """Verify PhysicalType indices match PhysicalTypeString."""
        pytest.importorskip("pygltflib")
        from pygltflib import GLTF2
        
        gltf_path = get_output_dir() / f"minimal_thinglink_scene{GLTF_EXT}"
        if not gltf_path.exists():
            pytest.skip("GLTF not found")
        
        gltf = GLTF2().load(str(gltf_path))
        
        # Load physical types to verify indices
        from xworld_xbase_plugin import PHYSICAL_TYPES
        
        for node in gltf.nodes:
            if not node.extras:
                continue
            
            for key, comp in node.extras.items():
                if not isinstance(comp, dict):
                    continue
                if "ThingLink" not in comp.get("type", ""):
                    continue
                
                pt_index = comp.get("PhysicalType")
                pt_string = comp.get("PhysicalTypeString")
                
                if pt_index is not None and pt_string is not None:
                    expected_index = PHYSICAL_TYPES.index(pt_string) if pt_string in PHYSICAL_TYPES else -1
                    assert pt_index == expected_index, (
                        f"Node '{node.name}': PhysicalType {pt_index} doesn't match "
                        f"PhysicalTypeString '{pt_string}' (expected index {expected_index})"
                    )


class TestEdgeCases:
    """Tests for edge_cases.gltf."""
    
    def test_edge_cases_unicode(self, expected_extras):
        """Verify unicode strings are preserved."""
        pytest.importorskip("pygltflib")
        from pygltflib import GLTF2
        
        gltf_path = get_output_dir() / f"edge_cases{GLTF_EXT}"
        if not gltf_path.exists():
            pytest.skip("GLTF not found")
        
        gltf = GLTF2().load(str(gltf_path))
        actual = parse_gltf_extras(gltf)
        
        # Find Unicode node
        unicode_node = actual.get("Unicode", {})
        assert unicode_node, "Unicode node not found in GLTF"
        
        comps = unicode_node.get("components", [])
        thinglink = next((c for c in comps if c["type"] == "ThingLink"), None)
        assert thinglink, "ThingLink component not found on Unicode node"
        assert thinglink.get("ThingInstanceLabel") == "unicode-office"
    
    def test_edge_cases_empty_strings(self, expected_extras):
        """Verify empty strings are handled correctly."""
        pytest.importorskip("pygltflib")
        from pygltflib import GLTF2
        
        gltf_path = get_output_dir() / f"edge_cases{GLTF_EXT}"
        if not gltf_path.exists():
            pytest.skip("GLTF not found")
        
        gltf = GLTF2().load(str(gltf_path))
        actual = parse_gltf_extras(gltf)
        expected = expected_extras.get("edge_cases", {})
        
        errors = []
        valid = validate_node_components(actual, expected, errors)
        
        if not valid:
            pytest.fail("\n".join(errors))


class TestNestedHierarchy:
    """Tests for nested_hierarchy.gltf."""
    
    def test_nested_hierarchy_depth(self, expected_extras):
        """Verify all nested nodes have correct extras."""
        pytest.importorskip("pygltflib")
        from pygltflib import GLTF2
        
        gltf_path = get_output_dir() / f"nested_hierarchy{GLTF_EXT}"
        if not gltf_path.exists():
            pytest.skip("GLTF not found")
        
        gltf = GLTF2().load(str(gltf_path))
        actual = parse_gltf_extras(gltf)
        expected = expected_extras.get("nested_hierarchy", {})
        
        errors = []
        valid = validate_node_components(actual, expected, errors)
        
        if not valid:
            pytest.fail("\n".join(errors))
    
    def test_nested_hierarchy_contains_all_levels(self):
        """Verify all hierarchy levels are present."""
        pytest.importorskip("pygltflib")
        from pygltflib import GLTF2
        
        gltf_path = get_output_dir() / f"nested_hierarchy{GLTF_EXT}"
        if not gltf_path.exists():
            pytest.skip("GLTF not found")
        
        gltf = GLTF2().load(str(gltf_path))
        node_names = [n.name for n in gltf.nodes if n.name]
        
        expected_nodes = ["Site", "Building", "Wing", "Level1", "Ward", "Room1", "Bed1"]
        
        for expected_name in expected_nodes:
            assert expected_name in node_names, f"Node '{expected_name}' not found in GLTF"


class TestAllComponents:
    """Tests for all_components.gltf."""
    
    def test_all_components_layers(self, expected_extras):
        """Verify Layer component is exported correctly."""
        pytest.importorskip("pygltflib")
        from pygltflib import GLTF2
        
        gltf_path = get_output_dir() / f"all_components{GLTF_EXT}"
        if not gltf_path.exists():
            pytest.skip("GLTF not found")
        
        gltf = GLTF2().load(str(gltf_path))
        actual = parse_gltf_extras(gltf)
        
        # LayersOnly node should have Layer component
        layers_node = actual.get("LayersOnly", {})
        assert layers_node, "LayersOnly node not found"
        
        comps = layers_node.get("components", [])
        layer_comp = next((c for c in comps if c["type"] == "Layer"), None)
        assert layer_comp, "Layer component not found"
        assert layer_comp.get("Layers") == "Environment,Hvac,Plumbing"
    
    def test_all_components_edges(self, expected_extras):
        """Verify Edge component is exported correctly."""
        pytest.importorskip("pygltflib")
        from pygltflib import GLTF2
        
        gltf_path = get_output_dir() / f"all_components{GLTF_EXT}"
        if not gltf_path.exists():
            pytest.skip("GLTF not found")
        
        gltf = GLTF2().load(str(gltf_path))
        actual = parse_gltf_extras(gltf)
        
        # EdgesOnly node should have Edge component
        edges_node = actual.get("EdgesOnly", {})
        assert edges_node, "EdgesOnly node not found"
        
        comps = edges_node.get("components", [])
        edge_comp = next((c for c in comps if c["type"] == "Edge"), None)
        assert edge_comp, "Edge component not found"
        assert edge_comp.get("Edges") == "sibling,reference,external"
    
    def test_fully_loaded_has_all_components(self, expected_extras):
        """Verify FullyLoaded node has all component types."""
        pytest.importorskip("pygltflib")
        from pygltflib import GLTF2
        
        gltf_path = get_output_dir() / f"all_components{GLTF_EXT}"
        if not gltf_path.exists():
            pytest.skip("GLTF not found")
        
        gltf = GLTF2().load(str(gltf_path))
        actual = parse_gltf_extras(gltf)
        
        fully_loaded = actual.get("FullyLoaded", {})
        assert fully_loaded, "FullyLoaded node not found"
        
        comps = fully_loaded.get("components", [])
        comp_types = [c["type"] for c in comps]
        
        assert "ThingLink" in comp_types, "Missing ThingLink"
        assert "Layer" in comp_types, "Missing Layer"
        assert "Edge" in comp_types, "Missing Edge"
        assert "PivotOverride" in comp_types, "Missing PivotOverride"


class TestCustomGlb:
    """Test custom GLB file passed via --glb option."""
    
    def test_custom_glb(self, request, expected_extras):
        """Validate a custom GLB file if --glb is provided."""
        gltf_path = request.config.getoption("--glb")
        expected_path = request.config.getoption("--expected")
        
        if not gltf_path:
            pytest.skip("No --glb option provided")
        
        pytest.importorskip("pygltflib")
        from pygltflib import GLTF2
        
        gltf_path = Path(gltf_path)
        if not gltf_path.exists():
            pytest.fail(f"GLB file not found: {gltf_path}")
        
        gltf = GLTF2().load(str(gltf_path))
        actual = parse_gltf_extras(gltf)
        
        # Load custom expected values if provided
        if expected_path:
            with open(expected_path, 'r') as f:
                expected = json.load(f)
        else:
            # Just verify basic structure
            assert len(gltf.nodes) > 0, "GLTF has no nodes"
            
            # Print summary for manual inspection
            print(f"\nGLTF Summary for {gltf_path.name}:")
            print(f"  Nodes: {len(gltf.nodes)}")
            print(f"  Nodes with extras: {len(actual)}")
            for name, data in list(actual.items())[:5]:
                comps = [c["type"] for c in data.get("components", [])]
                print(f"    {name}: {comps}")
            return
        
        errors = []
        valid = validate_node_components(actual, expected, errors)
        
        if not valid:
            pytest.fail("\n".join(errors))

