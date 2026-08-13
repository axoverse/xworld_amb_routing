# Test-site composition: reusable AxNode3D scene units

Status: bed unit shipped (XSG-53). Room / floor / building units are XSG-54 and
MUST follow this pattern mechanically.

## Why

The XScape procedural test site (`xscape/scripts/builders/test_site_builder.gd`)
originally hand-assembled every `AxNode3D` inline. Owner direction (2026-07-16)
is to COMPOSE the site from reusable authored scene units — `Bed.tscn`,
`Room.tscn`, `Floor.tscn`, `Building.tscn` — so the marker set for each level of
the hierarchy lives in ONE place and every instance inherits it. The builder
then applies only the per-instance variation.

The hard constraint: the export gate (`test_test_site_export.gd` →
`XFabExporter`) must keep emitting a **byte-identical `tl_things.csv`**. Beds
became instances of `Bed.tscn` with zero CSV drift; the same must hold as the
siblings land.

## The unit / builder split

A reusable unit carries the SHARED marker set; the builder applies the
PER-INSTANCE variation after `instantiate()`. Split for `Bed.tscn`
(`xscape/scenes/test_site/Bed.tscn`):

| Concern | Lives in the SCENE (shared) | Applied by the BUILDER (per instance) |
|---|---|---|
| `AxNode3D` script | yes | — |
| `useThingLink`, `PhysicalType` | `true`, `"Bed"` | — |
| `useLayers`, `Layers` | `true`, `"Furniture"` | — |
| `useBoundsHelper` | `true` (baked at build time by `_bake_all_bounds`) | — |
| Pivot fields, `usePivotOverride` | present, `false` (see note) | — |
| child `BedMesh` MeshInstance3D + BoxMesh geometry | yes | — |
| node `name` (`Bed_b1`) | default `"Bed"` | set per instance |
| `ThingLabelOverride` (`&_b1`) | empty | set per instance |
| `ThingNameOverride` (`Bed_b1`) | empty | set per instance |
| local `position` | identity | set per instance |
| `ThingGuid` | **empty** | set per instance (deterministic) |
| BedMesh red/yellow material | none (BoxMesh material null) | `material_override` by seed |
| parent edge | — | `room.add_child(bed)` |

### Rules that keep the CSV byte-identical

1. **`ThingGuid` is empty in the scene, overridden per instance.** An authored
   `AxNode3D` auto-generates a random 32-hex GUID in `_enter_tree()` when
   `ThingGuid` is empty. If the scene shipped a baked GUID, all N instances
   would collide; if left to auto-generate, the `glbs_guid` CSV column would
   churn every run. The builder assigns a deterministic GUID **before
   `add_child`** (so `_enter_tree` sees a non-empty value and leaves it alone).

2. **Consume exactly one GUID counter per instance, in the old call order.**
   `TestSiteBuilder._next_guid()` is a monotonic counter; the CSV `glbs_guid`
   column is that counter in depth-first preorder. `_add_bed` calls
   `_next_guid()` once per bed at the same point the old `_make_axnode` did, so
   the whole-site GUID sequence is unchanged. When adding Room/Floor/Building
   units, preserve the one-`_next_guid()`-per-node ordering identically.

3. **Labels come from `ThingLabelOverride` + `recalculate_instance_labels`,
   NOT node names.** The builder sets `ThingLabelOverride = "&_b%d"`; the `&`
   prefix concatenates with the parent's resolved `ThingInstanceLabel`
   (`recalculate_instance_labels`, called once on the root). This yields globally
   unique hierarchical labels (`TestSite_bN_l0_w1_r1_b1`) with only a LOCAL
   suffix authored per node. Never rely on node-name uniqueness for label
   uniqueness — see the `@` note below.

4. **`transform_position` accumulates AxNode3D translations only.** The exporter
   sums `AxNode3D` local translations down the chain; child `MeshInstance3D`
   offsets (the BedMesh lift) do NOT enter the CSV. Set each unit's local
   `position` on the AxNode3D root; bake mesh offsets into the scene.

5. **Per-instance material is a `material_override`, not a mesh material.** The
   BoxMesh geometry is shared across all instances. Mutating a shared mesh's
   surface material would bleed across instances; `material_override` on the
   MeshInstance3D varies appearance without touching the shared resource.
   Material does not affect the CSV, but it does affect screenshot regressions —
   use the same `TestSiteGeometry` material resources the inline path used so
   pixels are identical.

### Pivot note (XSG-52)

Author `usePivotOverride = false` on shared units. The pivot rotation is
consumed at runtime (XSG-52); enabling it on a shared unit would rotate every
instance's bound patient — a visible behavior change. Keep the pivot fields
present (defaults) but disabled, and let a consumer opt a specific instance in.

## Packing instanced units (export path)

`test_test_site_export.gd` packs the built site into a `.tscn`, then the
exporter reloads and walks it. The instanced-bed change required NO change to
the pack step:

- `_set_owner_recursive` sets every procedurally-added child's `owner` to the
  packed-scene root (skipping only transient `_BoundsHelperGizmo` nodes). For an
  instanced unit, `pack()` KEEPS the instance reference
  (`instance=ExtResource("…/Bed.tscn")`) and, because the internal nodes' owner
  is now the outer root, additionally writes them as editable-children override
  entries (`[node name="BedMesh" parent="Bed_b1" …]`). This is where
  per-instance overrides such as `material_override` are recorded. The packed
  `.tscn` therefore DEPENDS on the unit scene existing at its path — do not move
  or delete `Bed.tscn` (the export test only cleans up the generated site
  `.tscn`, never the unit).
- The exporter instantiates the reloaded `PackedScene`, so it walks the same
  live tree whether a node was authored inline or came from an instanced unit.
  The CSV depends only on the resolved property VALUES, which the table above
  pins — which is why the bed change produced a byte-identical `tl_things.csv`
  with the pack step untouched.

## `@` auto instance naming — recommendation for XSG-54

See `docs/godot_at_auto_naming.md` for the full investigation. Summary for unit
authors:

- Godot auto-renames colliding siblings using a reserved `@<Class>@N` form
  (verified: `add_child(n)` on a name collision yields `@Node3D@3`, discarding
  the requested name). These names cannot be authored into editor-saved `.tscn`
  (the reserved characters `. : @ / % "` are stripped by `Node.set_name`), and
  the numeric suffix is a global add-order counter, so they are neither stable
  nor round-trippable.
- The exporter's fallback path (`ValidateInstanceLabelInNode`, and the CSV label
  column) uses `node.name` **only when `ThingInstanceLabel` is empty**. A unit
  that relied on `@` naming and had no `ThingLabelOverride` would leak an
  `@<Class>@N` string into the CSV `label` column.
- **Recommendation: keep explicit deterministic naming in the builder.** Give
  each generated instance an index-derived `name` (`Room_r%d`, `Floor_l%d`,
  `Block_%s`) AND an index-derived `ThingLabelOverride` (`&_r%d`, `&_l%d`,
  `&_%s`). The `&` hierarchical mechanism supplies global label uniqueness from
  a purely LOCAL suffix, so no full-path hand-numbering is needed. Use
  `add_child(node, true)` (force-readable) only as a defensive collision guard;
  never depend on `@` names for identity.

## Checklist for XSG-54 (Room / Floor / Building units)

1. Author `Room.tscn`, `Floor.tscn`, `Building.tscn` under
   `xscape/scenes/test_site/` carrying each level's shared marker set
   (`PhysicalType` Room/Level/Building, layers, `useBoundsHelper`, pivot off,
   child visuals that are constant across instances).
2. Leave `ThingGuid` empty; override deterministically in the builder before
   `add_child`, one `_next_guid()` per node, preserving DFS preorder.
3. Give each instance an explicit `name` + `ThingLabelOverride` (`&_` local
   suffix); call `recalculate_instance_labels` once on the site root.
4. Apply per-instance visuals via `material_override`, not shared-mesh mutation.
5. Re-run `xscape_test_site_export`; the `tl_things.csv` diff against
   pre-change output MUST be byte-identical (site + every per-building CSV).
