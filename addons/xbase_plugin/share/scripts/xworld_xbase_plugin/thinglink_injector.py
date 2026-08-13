#!/usr/bin/env python3
"""
ThingLink Injector for GLTF Files

Injects xScape ThingLink metadata into GLTF node extras for use with
Godot xbase_plugin or Unity XScape.

Usage:
    python -m xworld_xbase_plugin.thinglink_injector input.gltf mapping.csv output.gltf
"""

import json
import csv
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, field
from pathlib import Path

try:
    from pygltflib import GLTF2
except ImportError:
    GLTF2 = None  # Will be checked at runtime

# =============================================================================
# Data Loading from Shared JSON Files
# =============================================================================

_DATA_DIR = Path(__file__).parent.parent.parent / "data"

def _load_json_list(filename: str) -> List[str]:
    """Load a JSON array from the shared data directory."""
    json_path = _DATA_DIR / filename
    if json_path.exists():
        with open(json_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    return []

def load_physical_types() -> List[str]:
    """Load physical types from shared JSON."""
    return _load_json_list("physical_types.json")

def load_layers() -> List[str]:
    """Load layer names from shared JSON."""
    return _load_json_list("layers.json")

def load_edges() -> List[str]:
    """Load edge types from shared JSON."""
    return _load_json_list("edges.json")

# Cache loaded data
PHYSICAL_TYPES: List[str] = load_physical_types()
LAYER_NAMES: List[str] = load_layers()
EDGE_TYPES: List[str] = load_edges()


# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class ThingLinkComponent:
    """ThingLink component data."""
    thing_instance_label: str
    thing_label_override: str = ""
    thing_name_override: str = ""
    physical_type: str = "None"
    prefab: str = "-"
    
    def to_dict(self) -> Dict[str, Any]:
        physical_type_index = PHYSICAL_TYPES.index(self.physical_type) if self.physical_type in PHYSICAL_TYPES else 0
        return {
            "type": "Axomem.XScape.Core.ThingLink,XScape.Core",
            "ThingInstanceLabel": self.thing_instance_label,
            "ThingLabelOverride": self.thing_label_override,
            "ThingNameOverride": self.thing_name_override,
            "PhysicalType": physical_type_index,
            "PhysicalTypeString": self.physical_type,
            "Prefab": self.prefab
        }


@dataclass
class BoundsComponent:
    """BoundsHelper component data."""
    center: tuple = (0.0, 0.0, 0.0)
    extent: tuple = (1.0, 1.0, 1.0)
    use_static_bounds: bool = True
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": "Axomem.XScape.Core.BoundsHelper,XScape.Core",
            "UseStaticBounds": self.use_static_bounds,
            "RecalcStaticBounds": False,
            "StaticBounds": {
                "m_Center": {"x": self.center[0], "y": self.center[1], "z": self.center[2]},
                "m_Extent": {"x": self.extent[0], "y": self.extent[1], "z": self.extent[2]}
            }
        }


@dataclass
class LayerComponent:
    """Layer component data."""
    layers: List[str] = field(default_factory=lambda: ["Default"])
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": "Axomem.XScape.Core.Layer,XScape.Core",
            "Layers": ",".join(self.layers),
            "Validation": "OK"
        }


@dataclass
class EdgeComponent:
    """Edge component data."""
    edges: List[str] = field(default_factory=lambda: ["child"])
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": "Axomem.XScape.Core.Edge,XScape.Core",
            "Edges": ",".join(self.edges),
            "Validation": "OK"
        }


@dataclass
class PivotOverrideComponent:
    """PivotOverride component data."""
    rotation: tuple = (0.0, 0.0, 0.0)
    cam_distance_multiplier: float = 1.0
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": "Axomem.XScape.Core.PivotOverride,XScape.Core",
            "Rotation": {"x": self.rotation[0], "y": self.rotation[1], "z": self.rotation[2]},
            "CamDistanceMultiplier": self.cam_distance_multiplier
        }


# =============================================================================
# Main Injector Class
# =============================================================================

class ThingLinkInjector:
    """Injects ThingLink metadata into GLTF files."""
    
    def __init__(self, gltf_path: str):
        """Load a GLTF file for modification."""
        if GLTF2 is None:
            raise ImportError("pygltflib is required. Install with: pip install pygltflib")
        
        self.gltf_path = gltf_path
        self.gltf = GLTF2().load(gltf_path)
        self._node_name_map: Dict[str, int] = {}
        self._build_node_map()
    
    def _build_node_map(self):
        """Build a map of node names to indices."""
        for idx, node in enumerate(self.gltf.nodes):
            if node.name:
                self._node_name_map[node.name] = idx
    
    def get_node_names(self) -> List[str]:
        """Return list of all node names in the GLTF."""
        return list(self._node_name_map.keys())
    
    def find_node_index(self, name: str) -> Optional[int]:
        """Find node index by name (case-insensitive partial match)."""
        name_lower = name.lower()
        for node_name, idx in self._node_name_map.items():
            if name_lower in node_name.lower():
                return idx
        return None
    
    def add_thinglink(
        self,
        node_name_or_index,
        thing_instance_label: str,
        physical_type: str = "None",
        thing_name_override: str = "",
        thing_label_override: str = "",
        prefab: str = "-"
    ) -> bool:
        """Add ThingLink component to a node."""
        node_idx = self._resolve_node(node_name_or_index)
        if node_idx is None:
            return False
        
        component = ThingLinkComponent(
            thing_instance_label=thing_instance_label,
            thing_label_override=thing_label_override,
            thing_name_override=thing_name_override,
            physical_type=physical_type,
            prefab=prefab
        )
        
        self._add_component(node_idx, component.to_dict())
        return True
    
    def add_bounds(
        self,
        node_name_or_index,
        center: tuple = (0, 0, 0),
        extent: tuple = (1, 1, 1)
    ) -> bool:
        """Add BoundsHelper component to a node."""
        node_idx = self._resolve_node(node_name_or_index)
        if node_idx is None:
            return False
        
        component = BoundsComponent(center=center, extent=extent)
        self._add_component(node_idx, component.to_dict())
        return True
    
    def add_layer(
        self,
        node_name_or_index,
        layers: List[str]
    ) -> bool:
        """Add Layer component to a node."""
        node_idx = self._resolve_node(node_name_or_index)
        if node_idx is None:
            return False
        
        component = LayerComponent(layers=layers)
        self._add_component(node_idx, component.to_dict())
        return True
    
    def add_edge(
        self,
        node_name_or_index,
        edges: List[str]
    ) -> bool:
        """Add Edge component to a node."""
        node_idx = self._resolve_node(node_name_or_index)
        if node_idx is None:
            return False
        
        component = EdgeComponent(edges=edges)
        self._add_component(node_idx, component.to_dict())
        return True
    
    def add_pivot_override(
        self,
        node_name_or_index,
        rotation: tuple = (0, 0, 0),
        cam_distance_multiplier: float = 1.0
    ) -> bool:
        """Add PivotOverride component to a node."""
        node_idx = self._resolve_node(node_name_or_index)
        if node_idx is None:
            return False
        
        component = PivotOverrideComponent(
            rotation=rotation,
            cam_distance_multiplier=cam_distance_multiplier
        )
        self._add_component(node_idx, component.to_dict())
        return True
    
    def inject_from_csv(self, csv_path: str) -> int:
        """
        Inject ThingLink data from a CSV file.
        
        CSV format:
        node_name,thing_instance_label,physical_type,thing_name,layers
        
        Returns number of nodes updated.
        """
        updated = 0
        with open(csv_path, 'r', newline='', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                node_name = row.get('node_name', '')
                if not node_name:
                    continue
                
                node_idx = self.find_node_index(node_name)
                if node_idx is None:
                    print(f"Warning: Node '{node_name}' not found")
                    continue
                
                # Add ThingLink
                self.add_thinglink(
                    node_idx,
                    thing_instance_label=row.get('thing_instance_label', node_name),
                    physical_type=row.get('physical_type', 'None'),
                    thing_name_override=row.get('thing_name', ''),
                    thing_label_override=row.get('thing_label_override', '')
                )
                
                # Add layers if specified
                layers_str = row.get('layers', '')
                if layers_str:
                    layers = [l.strip() for l in layers_str.split(',')]
                    self.add_layer(node_idx, layers)
                
                updated += 1
        
        return updated
    
    def inject_from_json(self, json_path: str) -> int:
        """
        Inject ThingLink data from a JSON mapping file.
        
        Returns number of nodes updated.
        """
        with open(json_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        updated = 0
        for node_data in data.get('nodes', []):
            node_name = node_data.get('node_name', '')
            if not node_name:
                continue
            
            node_idx = self.find_node_index(node_name)
            if node_idx is None:
                print(f"Warning: Node '{node_name}' not found")
                continue
            
            # Add ThingLink
            self.add_thinglink(
                node_idx,
                thing_instance_label=node_data.get('thing_instance_label', node_name),
                physical_type=node_data.get('physical_type', 'None'),
                thing_name_override=node_data.get('thing_name', ''),
                thing_label_override=node_data.get('thing_label_override', '')
            )
            
            # Add layers
            if 'layers' in node_data:
                self.add_layer(node_idx, node_data['layers'])
            
            # Add edges
            if 'edges' in node_data:
                self.add_edge(node_idx, node_data['edges'])
            
            # Add bounds
            if 'bounds' in node_data:
                bounds = node_data['bounds']
                self.add_bounds(
                    node_idx,
                    center=tuple(bounds.get('center', [0, 0, 0])),
                    extent=tuple(bounds.get('extent', [1, 1, 1]))
                )
            
            updated += 1
        
        return updated
    
    def save(self, output_path: str):
        """Save the modified GLTF to a file."""
        self.gltf.save(output_path)
        print(f"Saved: {output_path}")
    
    def _resolve_node(self, node_name_or_index) -> Optional[int]:
        """Resolve a node name or index to a node index."""
        if isinstance(node_name_or_index, int):
            if 0 <= node_name_or_index < len(self.gltf.nodes):
                return node_name_or_index
            return None
        return self.find_node_index(node_name_or_index)
    
    def _add_component(self, node_idx: int, component_dict: Dict[str, Any]):
        """Add a component to a node's extras."""
        node = self.gltf.nodes[node_idx]
        
        # Initialize extras if needed
        if node.extras is None:
            node.extras = {}
        
        # Find next available component index
        existing_keys = [int(k) for k in node.extras.keys() if isinstance(k, str) and k.isdigit()]
        next_idx = max(existing_keys, default=0) + 1
        
        # Add the component
        node.extras[str(next_idx)] = component_dict


# =============================================================================
# CLI
# =============================================================================

def main():
    """CLI entry point."""
    import argparse
    
    parser = argparse.ArgumentParser(
        description="Inject ThingLink metadata into GLTF files"
    )
    parser.add_argument("input", help="Input GLTF file")
    parser.add_argument("mapping", help="Mapping file (CSV or JSON)")
    parser.add_argument("output", help="Output GLTF file")
    parser.add_argument("--list-nodes", action="store_true",
                        help="List all node names and exit")
    
    args = parser.parse_args()
    
    injector = ThingLinkInjector(args.input)
    
    if args.list_nodes:
        print("Nodes in GLTF:")
        for name in injector.get_node_names():
            print(f"  - {name}")
        return
    
    # Determine mapping format
    mapping_path = Path(args.mapping)
    if mapping_path.suffix.lower() == '.json':
        count = injector.inject_from_json(args.mapping)
    else:
        count = injector.inject_from_csv(args.mapping)
    
    print(f"Updated {count} nodes")
    injector.save(args.output)


if __name__ == "__main__":
    main()

