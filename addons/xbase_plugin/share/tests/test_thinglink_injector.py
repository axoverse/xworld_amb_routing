"""
Tests for ThingLinkInjector class.
"""

import pytest
from pathlib import Path


class TestComponents:
    """Tests for component data classes."""
    
    def test_thinglink_component_to_dict(self):
        """ThingLinkComponent should serialize correctly."""
        from xworld_xbase_plugin import ThingLinkComponent
        
        component = ThingLinkComponent(
            thing_instance_label="test-label",
            thing_label_override="override",
            thing_name_override="Test Name",
            physical_type="Room"
        )
        
        result = component.to_dict()
        
        assert result["type"] == "Axomem.XScape.Core.ThingLink,XScape.Core"
        assert result["ThingInstanceLabel"] == "test-label"
        assert result["ThingLabelOverride"] == "override"
        assert result["ThingNameOverride"] == "Test Name"
        assert result["PhysicalTypeString"] == "Room"
        assert result["PhysicalType"] == 7  # Room is index 7
    
    def test_bounds_component_to_dict(self):
        """BoundsComponent should serialize correctly."""
        from xworld_xbase_plugin import BoundsComponent
        
        component = BoundsComponent(
            center=(1.0, 2.0, 3.0),
            extent=(4.0, 5.0, 6.0)
        )
        
        result = component.to_dict()
        
        assert result["type"] == "Axomem.XScape.Core.BoundsHelper,XScape.Core"
        assert result["UseStaticBounds"] is True
        assert result["StaticBounds"]["m_Center"]["x"] == 1.0
        assert result["StaticBounds"]["m_Center"]["y"] == 2.0
        assert result["StaticBounds"]["m_Center"]["z"] == 3.0
        assert result["StaticBounds"]["m_Extent"]["x"] == 4.0
    
    def test_layer_component_to_dict(self):
        """LayerComponent should serialize correctly."""
        from xworld_xbase_plugin import LayerComponent
        
        component = LayerComponent(layers=["Default", "Walls", "Doors"])
        result = component.to_dict()
        
        assert result["type"] == "Axomem.XScape.Core.Layer,XScape.Core"
        assert result["Layers"] == "Default,Walls,Doors"
        assert result["Validation"] == "OK"
    
    def test_edge_component_to_dict(self):
        """EdgeComponent should serialize correctly."""
        from xworld_xbase_plugin import EdgeComponent
        
        component = EdgeComponent(edges=["child", "location"])
        result = component.to_dict()
        
        assert result["type"] == "Axomem.XScape.Core.Edge,XScape.Core"
        assert result["Edges"] == "child,location"
    
    def test_pivot_override_to_dict(self):
        """PivotOverrideComponent should serialize correctly."""
        from xworld_xbase_plugin import PivotOverrideComponent
        
        component = PivotOverrideComponent(
            rotation=(0, 90, 0),
            cam_distance_multiplier=1.5
        )
        result = component.to_dict()
        
        assert result["type"] == "Axomem.XScape.Core.PivotOverride,XScape.Core"
        assert result["Rotation"]["y"] == 90
        assert result["CamDistanceMultiplier"] == 1.5


class TestThingLinkInjector:
    """Tests for ThingLinkInjector class."""
    
    @pytest.fixture
    def injector(self, sample_gltf_path: Path):
        """Create an injector with a sample GLTF."""
        pytest.importorskip("pygltflib")
        from xworld_xbase_plugin import ThingLinkInjector
        return ThingLinkInjector(str(sample_gltf_path))
    
    def test_get_node_names(self, injector):
        """Should return list of node names."""
        names = injector.get_node_names()
        assert "RootNode" in names
        assert "Room_101" in names
        assert "Bed_101" in names
    
    def test_find_node_index(self, injector):
        """Should find node by name."""
        idx = injector.find_node_index("Room_101")
        assert idx is not None
        assert idx == 1
    
    def test_find_node_partial_match(self, injector):
        """Should find node by partial name match."""
        idx = injector.find_node_index("room")  # lowercase partial
        assert idx is not None
    
    def test_find_node_not_found(self, injector):
        """Should return None for non-existent node."""
        idx = injector.find_node_index("NonExistentNode")
        assert idx is None
    
    def test_add_thinglink(self, injector):
        """Should add ThingLink component to node."""
        result = injector.add_thinglink(
            "Room_101",
            thing_instance_label="hospital-room-101",
            physical_type="Room",
            thing_name_override="Room 101"
        )
        
        assert result is True
        
        # Verify extras were added
        node = injector.gltf.nodes[1]
        assert node.extras is not None
        assert "1" in node.extras
        assert node.extras["1"]["ThingInstanceLabel"] == "hospital-room-101"
    
    def test_add_layer(self, injector):
        """Should add Layer component to node."""
        result = injector.add_layer("Room_101", ["Default", "Walls"])
        assert result is True
        
        node = injector.gltf.nodes[1]
        assert node.extras is not None
    
    def test_add_multiple_components(self, injector):
        """Should add multiple components with incrementing indices."""
        injector.add_thinglink("Room_101", "label1")
        injector.add_layer("Room_101", ["Default"])
        injector.add_bounds("Room_101", (0, 0, 0), (1, 1, 1))
        
        node = injector.gltf.nodes[1]
        assert "1" in node.extras
        assert "2" in node.extras
        assert "3" in node.extras
    
    def test_save_gltf(self, injector, tmp_path: Path):
        """Should save modified GLTF to file."""
        output_path = tmp_path / "output.gltf"
        
        injector.add_thinglink("RootNode", "test-label")
        injector.save(str(output_path))
        
        assert output_path.exists()


class TestInjectorWithMissingPygltflib:
    """Tests for behavior when pygltflib is not installed."""
    
    def test_import_error_without_pygltflib(self, monkeypatch):
        """Should raise ImportError if pygltflib is not available."""
        # This test would need to mock the import, skipping for now
        pass

