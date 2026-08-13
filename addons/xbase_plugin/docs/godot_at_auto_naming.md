# Investigation: Godot `@` auto instance naming for generated units

Context: XSG-53. When the test-site builder generates many instances of a
reusable unit (`Bed.tscn` today; `Room`/`Floor`/`Building` in XSG-54), each
instance needs a unique, stable name so the exporter and `SyncAmThingLink`-style
tooling can key on it without hand-numbering. The question: can we lean on
Godot's runtime `@` auto-naming instead of assigning names ourselves?

Short answer: **no — auto `@` names are transient, unstable, and can't be
authored into a scene. Keep explicit deterministic naming, and drive identity
off `ThingInstanceLabel`, not off `node.name`.** Details and the XSG-54
recommendation below. All behaviour was verified empirically against the engine
binary in this tree (Godot 4.6, `godot.linuxbsd.editor.x86_64`).

## 1. Where Godot applies `@` renames

When a child is added whose name collides with an existing sibling (or which has
no name at all), `Node.add_child` generates a name. The form depends on the
`force_readable_name` argument:

| Call | Collision result | Observed |
|---|---|---|
| `add_child(n)` (default `force_readable_name = false`) | `@<ClassName>@<N>` | `@Node3D@3` |
| `add_child(n, true)` | readable `<Base><n>` | `Bed2` |

Findings for the default path:

- The auto-name uses the node's **class name**, not the name you requested —
  set `n.name = "Bed"`, add it into a collision, and it becomes `@Node3D@3`, not
  `@Bed@N`. The requested name is discarded entirely.
- `N` is a **global monotonic instance counter**, not a per-parent index. It is
  assigned by allocation order across the whole run, so it is not predictable,
  not stable across reorderings, and not reproducible in PR diffs.
- With `force_readable_name = true`, Godot instead keeps your base name and
  appends the smallest free integer (`Bed`, `Bed2`, `Bed3`). This is stable
  given a stable add order and is the only auto path worth considering — but it
  still numbers by add order, not by semantic index.

## 2. Why editor-saved scenes can't contain `@`

Node names are validated by `Node.set_name`, which strips a fixed set of
reserved characters. Empirically, setting a name to `@Weird@2/x:y.z%w` yields
`_Weird_2_x_y_z_w` — every one of `@ / : . %` (plus `"`) is replaced with `_`.

Consequences:

- You **cannot manually author an `@` name**. Type it into the editor's rename
  field or call `set_name` with it and it is sanitised to `_`.
- `@` therefore only ever appears as a *runtime* auto-name from the default
  `add_child` path. The editor's scene-tree tooling always assigns readable,
  unique names, so an editor-saved `.tscn` never contains `@` in a node name.
- An `@`-named node is a runtime artifact. It is not something a
  designer-authored or tool-generated-and-saved scene will round-trip.

## 3. What the exporter's label pass requires for uniqueness

The exporter identifies each Thing by its `ThingInstanceLabel`, **not** by
`node.name`. Two passes touch labels (`xbase_plugin.gd`,
`addons/xbase_plugin/axNode3D.gd`):

- `AxNode3D.validate_instance_labels(root)` — a read-only gate run before export
  (`xbase_plugin.gd` ~line 755). It aborts the export if any `useThingLink` node
  has a stale label (one that does not match the recomputed value), an empty
  label, and warns on duplicates. Uniqueness is defined over
  `ThingInstanceLabel`.
- `ValidateInstanceLabelInNode` — the lazy fill path. For a parentless root with
  an empty label it sets `ThingInstanceLabel = node.name`; for a child it calls
  `SetInstanceLabel`, which builds the label from `ThingLabelOverride`
  (the `&` prefix concatenates the parent's resolved label).
- The CSV `label` column falls back to `node.name` **only when
  `ThingInstanceLabel` is empty** (`xbase_plugin.gd` ~line 346).

The critical implication: `node.name` is the *last-resort* source of a Thing's
identity. If a generated instance relied on `@` auto-naming AND carried no
`ThingLabelOverride`, its `ThingInstanceLabel` — and hence the CSV `label`, the
server's `matchLabel` key, and every `partOf` reference to it — would become an
`@Node3D@N` string: reserved-character, add-order-dependent, non-round-trippable.
That breaks stable re-sync and cross-file `partOf` resolution.

`recalculate_instance_labels` derives uniqueness from `ThingLabelOverride` plus
the tree path, so a purely LOCAL suffix (`&_b1`) yields a globally unique
hierarchical label (`TestSite_bN_l0_w1_r1_b1`). Node-name uniqueness is
orthogonal and, for identity purposes, unnecessary — provided `ThingLabelOverride`
is always set.

## 4. Recommendation for XSG-54 generated instances

**Do not depend on `@` auto-naming for identity.** For each generated
Room / Floor / Building instance the builder should, exactly as `_add_bed` does
for beds:

1. Assign an explicit, index-derived **node name** (`Room_r%d`, `Floor_l%d`,
   `Block_%s`). Readable, deterministic, PR-diff-stable, and safe to save.
2. Assign an explicit, index-derived **`ThingLabelOverride`** with a `&` local
   suffix (`&_r%d`, `&_l%d`, `&_%s`), then call
   `AxNode3D.recalculate_instance_labels(site_root)` once. This is what actually
   guarantees globally-unique `ThingInstanceLabel`s and satisfies the export
   gate — it does not rely on node names at all.
3. Assign a deterministic `ThingGuid` before `add_child` (see
   `scene_composition_pattern.md`).

If a defensive collision guard is ever wanted (e.g. two siblings that legitimately
share a base name), pass `add_child(node, true)` for readable `NameN` suffixes —
never the default path, which yields reserved `@Class@N` names. But the primary
mechanism stays: explicit index naming + `&`-hierarchical `ThingLabelOverride`.
This keeps generated instances byte-stable and keeps every downstream consumer
(exporter, `SyncAmThingLink`, server `matchLabel`) keyed on clean labels.
