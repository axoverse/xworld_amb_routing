"""
Tests for data loading from shared JSON files.
"""

import json
from pathlib import Path
import pytest


class TestDataFiles:
    """Tests for the shared JSON data files."""
    
    def test_physical_types_json_exists(self, physical_types_json: Path):
        """Physical types JSON file should exist."""
        assert physical_types_json.exists(), f"File not found: {physical_types_json}"
    
    def test_layers_json_exists(self, layers_json: Path):
        """Layers JSON file should exist."""
        assert layers_json.exists(), f"File not found: {layers_json}"
    
    def test_edges_json_exists(self, edges_json: Path):
        """Edges JSON file should exist."""
        assert edges_json.exists(), f"File not found: {edges_json}"
    
    def test_physical_types_is_valid_json(self, physical_types_json: Path):
        """Physical types should be valid JSON."""
        with open(physical_types_json, 'r') as f:
            data = json.load(f)
        assert isinstance(data, list)
        assert len(data) > 0
    
    def test_physical_types_contains_expected_values(self, physical_types_json: Path):
        """Physical types should contain expected values."""
        with open(physical_types_json, 'r') as f:
            data = json.load(f)
        
        expected = ["None", "Site", "Building", "Room", "Bed", "Ward", "Level"]
        for item in expected:
            assert item in data, f"Missing physical type: {item}"
    
    def test_physical_types_order(self, physical_types_json: Path):
        """Physical types should be in correct order (None=0, Site=1, etc.)."""
        with open(physical_types_json, 'r') as f:
            data = json.load(f)
        
        assert data[0] == "None"
        assert data[1] == "Site"
        assert data[2] == "Building"
        assert data[7] == "Room"
        assert data[8] == "Bed"
    
    def test_layers_contains_expected_values(self, layers_json: Path):
        """Layers should contain expected values."""
        with open(layers_json, 'r') as f:
            data = json.load(f)
        
        expected = ["Default", "Walls", "Doors", "Furniture", "Equipment"]
        for item in expected:
            assert item in data, f"Missing layer: {item}"
    
    def test_edges_contains_expected_values(self, edges_json: Path):
        """Edges should contain expected values."""
        with open(edges_json, 'r') as f:
            data = json.load(f)
        
        expected = ["child", "sibling", "location", "member"]
        for item in expected:
            assert item in data, f"Missing edge: {item}"


class TestDataLoading:
    """Tests for the Python data loading functions."""
    
    def test_load_physical_types(self):
        """load_physical_types should return the list."""
        from xworld_xbase_plugin import load_physical_types
        
        types = load_physical_types()
        assert isinstance(types, list)
        assert len(types) > 0
        assert "Site" in types
        assert "Room" in types
    
    def test_load_layers(self):
        """load_layers should return the list."""
        from xworld_xbase_plugin import load_layers
        
        layers = load_layers()
        assert isinstance(layers, list)
        assert len(layers) > 0
        assert "Default" in layers
        assert "Walls" in layers
    
    def test_load_edges(self):
        """load_edges should return the list."""
        from xworld_xbase_plugin import load_edges
        
        edges = load_edges()
        assert isinstance(edges, list)
        assert len(edges) > 0
        assert "child" in edges
        assert "location" in edges
    
    def test_constants_populated(self):
        """Module constants should be populated."""
        from xworld_xbase_plugin import PHYSICAL_TYPES, LAYER_NAMES, EDGE_TYPES
        
        assert len(PHYSICAL_TYPES) > 0
        assert len(LAYER_NAMES) > 0
        assert len(EDGE_TYPES) > 0

