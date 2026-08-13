# XFabGLX: Transparency and Mesh Reuse in glTF

## Transparency

### PBR vs Unlit

Standard PBR transparency (`glTF/PbrMetallicRoughness` with `alphaMode: "BLEND"`) does work in
simple cases on Unity's built-in render pipeline. However, it has been unreliable in the xfabglx
hospital pipeline — rooms exported from Revit via Godot rendered opaque despite correct blend state,
keywords, and render queue settings. The root cause in the pipeline is still under investigation.

Regardless, Unlit is the preferred shader for area colorizers:
- **No lighting calculations** — better performance for flat-color overlays
- **Simpler alpha path** — avoids any PBR transparency edge cases
- **`MaterialPropertyBlock` works identically** — both shaders use `[MainColor] baseColorFactor`

### Recommended: Use Unlit Materials for Rooms/Wards

To trigger glTFast to use the `glTF/Unlit` shader, the glTF material must include the
`KHR_materials_unlit` extension.

**In Godot, configure the area material (`area_material.tres`) as:**

| Property | Value |
|----------|-------|
| Shading Mode | Unshaded |
| Transparency | Alpha |
| Albedo Color A | 0 (or desired default alpha) |

This exports as:
```json
{
  "alphaMode": "BLEND",
  "extensions": { "KHR_materials_unlit": {} },
  "pbrMetallicRoughness": {
    "baseColorFactor": [r, g, b, a]
  }
}
```

glTFast sees `KHR_materials_unlit` and selects the `glTF/Unlit` shader, which:
- Uses `[MainColor] baseColorFactor` for color (same as PBR)
- Correctly outputs alpha when `_ALPHABLEND_ON` keyword is active
- Supports `MaterialPropertyBlock` overrides (used by `ThingRendererColorizer`)
- Has no lighting calculations (better performance for area colorizers)

### What NOT to Do

- Do not use standard PBR shading for rooms/wards — even though PBR transparency can work, Unlit
  is more performant and avoids known edge cases in the xfabglx pipeline
- Do not omit `alphaMode: "BLEND"` — without it, alpha in `baseColorFactor` is ignored and the
  material renders opaque regardless of alpha value
- Do not set alpha to 0 without BLEND mode — the glTF spec says opaque materials ignore alpha

### Layer Convention

Room and ward objects must include a `Layer` component in their glTF extras with `Colorizer` in the
`Layers` field:

```json
{
  "Layer": {
    "type": "Axomem.XScape.Core.Layer, io.axomem.xscape.core",
    "Layers": "Colorizer"
  }
}
```

This signals to `ThingRendererColorizer` that the object's own mesh should be treated as an area
colorizer (default alpha = 0, controlled by the colorizer system).

### Fallback: Material Swap

As a safety net, `ThingRendererController.AddRendererComponentsTimed()` detects objects with:
1. `Colorizer` already in their Layer (from GLX extras, before the automatic append)
2. A `MeshRenderer` with a `glTF/*` shader

For these objects, the material is swapped to `PrefabCache.GetAreaRendererMaterial()`
(`UI/Unlit/Transparent`) which is known to work with `ThingRendererColorizer`. This fallback
catches older exports that still use PBR materials for rooms/wards.

### Shader Property Compatibility

`ThingRendererColorizer.ResolveMainColorPropertyId()` automatically detects the correct color
property for any shader by looking for the `[MainColor]` flag:

| Shader | Property | Tagged |
|--------|----------|--------|
| `glTF/Unlit` | `baseColorFactor` | `[MainColor]` |
| `glTF/PbrMetallicRoughness` | `baseColorFactor` | `[MainColor]` |
| `UI/Unlit/Transparent` | `_Color` | `[MainColor]` |

No code changes are needed when switching between these shaders — `MaterialPropertyBlock` overrides
target the correct property automatically.

## Mesh Reuse

glTFast deduplicates mesh data when multiple glTF meshes reference the same buffer accessors.

### How It Works

In glTF, a mesh is a combination of accessors (vertex positions, normals, UVs, indices) and a
material. When multiple meshes share identical accessor references, glTFast imports a single Unity
`Mesh` asset and assigns it to multiple `MeshFilter` components.

**Example from test file (`testtranssamemesh.gltf`):**

| glTF Mesh | POSITION | NORMAL | TANGENT | UV | Indices | Material | Unity Mesh |
|-----------|----------|--------|---------|-----|---------|----------|------------|
| 0 (Lit) | 0 | 2 | 1 | 3 | 4 | solid | Shared |
| 1 (LitTrans) | 0 | 2 | 1 | 3 | 4 | trans | Shared |
| 2 (Unlit1) | 0 | 2 | 1 | 3 | 4 | unlittrans | Shared |
| 3 (Unlit2) | 0 | 2 | 1 | 3 | 4 | unlittrans | Shared |

All 4 nodes reference the same vertex data, resulting in 1 Unity Mesh in memory.

### Implications for Revit Export

- Room/ward meshes with identical geometry (same shape, different materials) share a single mesh
- This is good for memory and enables GPU instancing
- Different materials on the same mesh geometry is the expected pattern — rooms share geometry
  but have per-instance color/alpha controlled by `ThingRendererColorizer` via `MaterialPropertyBlock`

### Godot Source vs glTF Output

In Godot, mesh resources can be:
- **SubResource** (inline, per-node) — each node gets its own mesh definition
- **ExtResource** (external `.tres` file) — multiple nodes share one mesh

Both patterns export to glTF with shared accessor references when the vertex data is identical.
glTFast deduplicates on import regardless of how the meshes were defined in Godot.
