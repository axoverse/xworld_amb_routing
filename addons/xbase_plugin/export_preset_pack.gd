@tool
extends RefCounted

## export_preset_pack.gd — drives Godot's NATIVE export-pack for one scene.
##
## Why this exists (XSG-59 G3):
## The old XFabExporter_pck built each per-scene .pck with a manual PCKPacker
## over the scene's source dependency paths. That path packs the AUTHORING
## files only — it silently omits the imported binaries Godot generates
## (`res://.godot/imported/*.ctex`) and their `.import` remap sidecars. A
## texture-bearing scene therefore rendered FLAT once the pack was mounted,
## because the atlas .ctex the material points at was never in the pack.
##
## The fix is to stop hand-packing and let Godot's exporter do it: append a
## transient preset to the project's export_presets.cfg, invoke
## `godot --headless --export-pack <preset> <pck> --path <project>` as a
## SUBPROCESS, then restore the cfg. Godot's export path natively resolves
## import remaps, so the pack ships `<scene>.tscn.remap` +
## `.godot/exported/<hash>/export-…-<scene>.scn` + every imported binary.
##
## In-process preset creation is NOT viable here: EditorExportPreset's
## add_export_file / set_export_filter are not script-bound, and its _set
## reaches EditorExport::singleton->save_presets() — that singleton doesn't
## exist in `--headless --editor --script` SceneTree runs. The cfg+subprocess
## route sidesteps both.
##
## Supply-chain stance (SHIP-WITH-AUDIT, owner decision 2026-07-17): scripts
## ship in packs so scenes can stay BINARY (text scenes blow out on huge
## hospital content; the binary loader hard-fails on stripped script deps).
## Internal-only deployments for now; script deps are logged per scene as the
## audit trail; XSG-60 owns the selective-stripping/gating redesign. See
## docs/pck_supply_chain.md.
##
## Stateless per the plugin convention: all funcs static, no instance state.

## Deterministic preset name — the fixed value lets a crashed run be self-healed
## on the next export (any leftover preset with this name is stripped first).
const PRESET_NAME := "XScapeAddressablePack"


## Exports `scene_res_path` to `pck_abs_path` via a native `--export-pack`
## subprocess, transiently mutating (and always restoring) the project's
## export_presets.cfg.
##
##   scene_res_path : "res://<scene>.tscn" to pack.
##   platform       : Godot export-platform display name (e.g. "Web", "Linux").
##   pck_abs_path   : absolute output path for the .pck.
##   project_dir_abs: absolute project dir (the subprocess --path argument).
##
## Returns OK on success. On any failure (cfg write, subprocess non-zero, pck
## missing / < 1024 bytes) it push_error()s and returns a non-OK Error. The cfg
## is restored on EVERY exit path via _restore().
static func export_scene_pack(scene_res_path: String, platform: String,
		pck_abs_path: String, project_dir_abs: String) -> int:
	var cfg_path: String = project_dir_abs.path_join("export_presets.cfg")

	# Back up the ORIGINAL bytes so restore is byte-exact (the cfg is tracked,
	# e.g. xscape/export_presets.cfg — a ConfigFile round-trip would reorder
	# keys / drop comments, so we keep the raw bytes and only restore those).
	var pre_existed: bool = FileAccess.file_exists(cfg_path)
	var backup: PackedByteArray = PackedByteArray()
	if pre_existed:
		backup = FileAccess.get_file_as_bytes(cfg_path)

	var write_err: int = _write_preset(cfg_path, scene_res_path, platform)
	if write_err != OK:
		push_error("export_preset_pack: could not write preset to %s (error %d)" % [cfg_path, write_err])
		_restore(cfg_path, pre_existed, backup)
		return write_err

	var output: Array = []
	var exit_code: int = OS.execute(
		OS.get_executable_path(),
		["--headless", "--export-pack", PRESET_NAME, pck_abs_path, "--path", project_dir_abs],
		output, true)

	# Restore BEFORE any early-return so the cfg never carries residue.
	_restore(cfg_path, pre_existed, backup)

	if exit_code != 0:
		push_error("export_preset_pack: --export-pack exited %d for %s\n%s" %
				[exit_code, scene_res_path, "\n".join(output)])
		return FAILED

	# File-shape guard: a real GDPC pack is comfortably > 1 KiB. A missing or
	# tiny file means the export silently produced nothing (e.g. the scene was
	# filtered out) — treat as an error rather than shipping an empty pack.
	if not FileAccess.file_exists(pck_abs_path):
		push_error("export_preset_pack: no pck produced at %s" % pck_abs_path)
		return ERR_FILE_NOT_FOUND
	var size: int = FileAccess.get_file_as_bytes(pck_abs_path).size()
	if size < 1024:
		push_error("export_preset_pack: pck suspiciously small (%d bytes) at %s" % [size, pck_abs_path])
		return ERR_FILE_CORRUPT

	return OK


## Loads the existing cfg (if any), self-heals a stale preset, appends a fresh
## preset for `scene_res_path`, and saves. ConfigFile is used deliberately: it
## serialises PackedStringArray in the exact `PackedStringArray("res://…")`
## shape the exporter expects.
static func _write_preset(cfg_path: String, scene_res_path: String, platform: String) -> int:
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(cfg_path):
		var load_err: int = cfg.load(cfg_path)
		if load_err != OK:
			return load_err

	# Self-heal: a crashed prior run may have left an XScapeAddressablePack
	# preset behind. Strip it (and its .options) before counting/appending.
	_strip_stale_preset(cfg)

	var idx: int = _next_preset_index(cfg)
	var sec: String = "preset.%d" % idx
	cfg.set_value(sec, "name", PRESET_NAME)
	cfg.set_value(sec, "platform", platform)
	cfg.set_value(sec, "runnable", false)
	cfg.set_value(sec, "advanced_options", false)
	cfg.set_value(sec, "dedicated_server", false)
	cfg.set_value(sec, "custom_features", "")
	cfg.set_value(sec, "export_filter", "scenes")
	cfg.set_value(sec, "export_files", PackedStringArray([scene_res_path]))
	cfg.set_value(sec, "include_filter", "")
	# Scripts SHIP in packs (owner decision 2026-07-17): scenes must export in
	# binary form (huge hospital scenes — text format risks a size blowout),
	# and the binary .scn loader hard-fails on missing script deps, so
	# stripping is incompatible with binary scenes. Deployments are
	# internal-only and customer builds are first-party, so the supply-chain
	# exposure is accepted FOR NOW; custom .gd in packs is unsupported /
	# at-your-own-risk. XSG-60 owns the selective-stripping / trust-gating
	# design that re-tightens this. Script deps are logged per scene at the
	# XFabExporter_pck call site as the audit trail. See
	# docs/pck_supply_chain.md.
	cfg.set_value(sec, "exclude_filter", "")
	cfg.set_value(sec, "export_path", "")
	cfg.set_value(sec, "patches", PackedStringArray())
	cfg.set_value(sec, "encryption_include_filters", "")
	cfg.set_value(sec, "encryption_exclude_filters", "")
	cfg.set_value(sec, "seed", 0)
	cfg.set_value(sec, "encrypt_pck", false)
	cfg.set_value(sec, "encrypt_directory", false)

	var save_err: int = cfg.save(cfg_path)
	if save_err != OK:
		return save_err

	# ConfigFile cannot serialise an EMPTY section, but the export machinery
	# expects a `[preset.N.options]` block (options default when absent, but we
	# match the probe-verified preset shape exactly). Append it if missing.
	_ensure_options_section(cfg_path, idx)
	return OK


## Removes any preset section whose `name` is PRESET_NAME, plus its `.options`
## sibling. Idempotent — safe when no stale preset exists.
static func _strip_stale_preset(cfg: ConfigFile) -> void:
	var to_erase: Array[String] = []
	for section in cfg.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			if str(cfg.get_value(section, "name", "")) == PRESET_NAME:
				to_erase.append(section)
				to_erase.append(section + ".options")
	for section in to_erase:
		if cfg.has_section(section):
			cfg.erase_section(section)


## Next preset index = count of existing `preset.N` sections (excluding the
## `.options` siblings). Presets are 0-contiguous by construction, so count is
## the correct next index.
static func _next_preset_index(cfg: ConfigFile) -> int:
	var count: int = 0
	for section in cfg.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			count += 1
	return count


## Appends an empty `[preset.N.options]` section if the saved cfg lacks it.
static func _ensure_options_section(cfg_path: String, idx: int) -> void:
	var marker: String = "[preset.%d.options]" % idx
	var text: String = FileAccess.get_file_as_string(cfg_path)
	if text.find(marker) != -1:
		return
	var f := FileAccess.open(cfg_path, FileAccess.READ_WRITE)
	if f == null:
		push_warning("export_preset_pack: could not append options section to %s" % cfg_path)
		return
	f.seek_end()
	f.store_string("\n%s\n" % marker)
	f.close()


## Restores export_presets.cfg to its pre-run state on every exit path:
## byte-exact from `backup` if it pre-existed, else delete the file we created.
static func _restore(cfg_path: String, pre_existed: bool, backup: PackedByteArray) -> void:
	if pre_existed:
		var f := FileAccess.open(cfg_path, FileAccess.WRITE)
		if f:
			f.store_buffer(backup)
			f.close()
		else:
			push_error("export_preset_pack: FAILED to restore %s — cfg may carry residue" % cfg_path)
	elif FileAccess.file_exists(cfg_path):
		var err: int = DirAccess.remove_absolute(cfg_path)
		if err != OK:
			push_error("export_preset_pack: FAILED to delete transient %s (error %d)" % [cfg_path, err])
