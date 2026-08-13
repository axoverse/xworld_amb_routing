"""
xworld_xbase_plugin - ThingLink metadata tools for GLTF files.

This package provides utilities for injecting xScape ThingLink metadata
into GLTF files for use with Godot xbase_plugin or Unity XScape.
"""

from .thinglink_injector import (
    ThingLinkInjector,
    ThingLinkComponent,
    BoundsComponent,
    LayerComponent,
    EdgeComponent,
    PivotOverrideComponent,
    load_physical_types,
    load_layers,
    load_edges,
    PHYSICAL_TYPES,
    LAYER_NAMES,
    EDGE_TYPES,
)

__version__ = "0.1.0"
__all__ = [
    "ThingLinkInjector",
    "ThingLinkComponent",
    "BoundsComponent",
    "LayerComponent",
    "EdgeComponent",
    "PivotOverrideComponent",
    "load_physical_types",
    "load_layers",
    "load_edges",
    "PHYSICAL_TYPES",
    "LAYER_NAMES",
    "EDGE_TYPES",
]

