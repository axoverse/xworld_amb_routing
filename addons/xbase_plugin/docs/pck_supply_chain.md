# PCK addressables and the script supply-chain

Status: SHIP-WITH-AUDIT (owner decision 2026-07-17) — scripts ship in packs,
every pack's script deps are logged at export, and custom `.gd` in packs is
**unsupported / at-your-own-risk**. XSG-60 owns the selective-stripping /
trust-gating redesign that re-tightens this.

## The capability

XScape addressable content ships as Godot `.pck` packs produced by Godot's
native export-pack (see `export_preset_pack.gd`, driven from
`XFabExporter_pck` in `xbase_plugin.gd`). Unlike the earlier GLB pipeline, a
Godot PCK **can carry executable code** — `.gd` source compiled to `.gdc`,
plus `.cs` — mounted straight into `res://` via `load_resource_pack`. The GLB
format could only smuggle code as *sidecar files* next to the `.glb`, never as
something the engine would load and run. PCKs remove that friction: a mounted
pack's scripts are indistinguishable from first-party project scripts.

## Why scripts ship today (and what constrains it)

An earlier iteration stripped `*.gd / *.gd.uid / *.cs` via the preset's
exclude_filter. That forced scenes to export as TEXT (`.tscn`), because the
binary `.scn` loader hard-fails on the first missing ext dependency while the
text loader tolerates a missing script and loads the node scriptless. The
owner reversed that trade: hospital scenes are huge and text-format scenes
risk a serious size blowout (Godot itself warns about scene size on this
content), so **scenes export binary and their script deps must therefore ship
in the pack**.

Accepted risk basis, explicitly scoped:

- Deployments are **internal-only** right now, and customer builds are also
  first-party — there is no untrusted-pack ingestion path today.
- Every export logs the pack's script deps as an audit trail:

  ```
  XFabExporter_pck: pack ships N script dep(s) (unsupported/at-your-own-risk, see docs/pck_supply_chain.md): a.gd, …
  ```

- **Custom `.gd` in packs is unsupported.** First-party marker scripts
  (axNode3D.gd etc.) riding along is expected; content authors must not rely
  on pack-delivered behaviour scripts. Nothing in the runtime consumes pack
  scripts by design — Thing metadata comes from `tl_things.csv` / GLB extras.

## Before third-party or CDN-multi-tenant packs exist

The moment packs can arrive from outside the first-party pipeline, this
stance is insufficient — a mounted pack's scripts would execute inside the
client (a direct RCE surface). XSG-60 must land first, covering:

- **selective stripping**: strip scripts at export EXCEPT an allowlist (or
  strip script *references* from exported scenes so binary scenes load
  scriptless — which would also lift the binary/text constraint entirely);
- a trust model for packs that deliberately ship code (signed-pack
  allowlist, author/tenant identity, or a capability-scoped sandbox);
- a mount-time guard (scan or catalog-declared script manifest + hash) so
  the runtime refuses unlisted script-bearing packs.

Do not widen pack ingestion beyond first-party sources before XSG-60 is
designed, reviewed, and shipped.
