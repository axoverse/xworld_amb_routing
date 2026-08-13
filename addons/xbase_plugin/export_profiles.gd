@tool
extends RefCounted

## Unity build-target label -> Godot asset-profile resolver.
##
## The Unity export target labels (StandaloneWindows64, WebGL, iOS, ...) are
## the STABLE PUBLIC CONTRACT — CI/CD jobs pass them in (--buildTarget=Win64
## etc., see PlatformIds in xbase_plugin.gd) and the addressables directory
## layout embeds them. Inside the exporter each label resolves to one of
## three internal ASSET PROFILES that sit across hard renderer boundaries:
##
##   desktop  Forward+ / Vulkan        (StandaloneWindows64, StandaloneLinux64)
##   web      Compatibility / WebGL2   (WebGL)
##   mobile   Mobile / Vulkan Mobile   (iOS, Android — same asset payload,
##                                      packaging/signing differ downstream)
##
## Do NOT build per-label pipelines — labels are the interface, profiles are
## the logic. Full rationale + the per-profile compression/resolution/shader
## decisions: xScape docs/export_targets_alignment.md.
##
## Today the profile is resolved, logged, and recorded in
## catalog_default.json as provenance. The per-profile knobs returned by
## settings_for() are ADVISORY — nothing consumes them yet; the export-preset
## PCK work (XSG-59 G3) and later texture-variance passes key off them.

const PROFILE_DESKTOP := "desktop"
const PROFILE_WEB := "web"
const PROFILE_MOBILE := "mobile"

# Unity build-target label -> asset profile. Several labels collapse to one
# profile by design. WindowsStoreApps (HoloLens) is RETIRED — see
# RetiredPlatformIds in xbase_plugin.gd; exports for it no-op upstream.
const LABEL_TO_PROFILE: Dictionary = {
	"StandaloneWindows64": PROFILE_DESKTOP,
	"StandaloneLinux64": PROFILE_DESKTOP,
	"WebGL": PROFILE_WEB,
	"iOS": PROFILE_MOBILE,
	"Android": PROFILE_MOBILE,
}

# Unity build-target label -> Godot export-platform DISPLAY NAME. This is the
# string Godot writes as `platform="…"` in export_presets.cfg and matches on
# for `--export-pack` (XSG-59 G3). It is ORTHOGONAL to LABEL_TO_PROFILE above:
# resolve()/asset-profiles drive advisory texture/shader knobs, whereas this
# names the concrete Godot EditorExportPlatform the PCK subprocess targets.
# Display names verified against xscape/export_presets.cfg ("Linux", "Web");
# the desktop/mobile names follow Godot 4.6's registered platform labels.
const LABEL_TO_GODOT_PLATFORM: Dictionary = {
	"StandaloneWindows64": "Windows Desktop",
	"StandaloneLinux64": "Linux",
	"WebGL": "Web",
	"iOS": "iOS",
	"Android": "Android",
}


## Resolves a Unity build-target label to its asset profile. Unknown labels
## fail loud and return "" — the label set is a CI contract, so an unknown
## label is a caller bug, not a case to paper over. (In practice
## get_build_target_from_command_line already coerces unknown CLI ids to
## "WebGL" before this is reached.)
static func resolve(build_target: String) -> String:
	if LABEL_TO_PROFILE.has(build_target):
		return LABEL_TO_PROFILE[build_target]
	push_error("export_profiles: unknown build target label '%s' (known: %s)" %
			[build_target, ", ".join(LABEL_TO_PROFILE.keys())])
	return ""


## Resolves a Unity build-target label to the Godot export-platform display
## name used by the export-preset PCK path (XSG-59 G3). Unknown labels fail
## loud and return "" — but unlike resolve(), the PCK caller does NOT abort on
## "": it falls back to the "Web" platform with a warning, because import
## remapping (the reason the PCK path exists) is platform-agnostic for our
## scene payloads, so "keep exporting" beats "drop the pack".
static func godot_export_platform(build_target: String) -> String:
	if LABEL_TO_GODOT_PLATFORM.has(build_target):
		return LABEL_TO_GODOT_PLATFORM[build_target]
	push_error("export_profiles: unknown build target label '%s' for Godot platform (known: %s)" %
			[build_target, ", ".join(LABEL_TO_GODOT_PLATFORM.keys())])
	return ""


## Advisory per-profile asset knobs (compression family, texture cap, shader
## variant set) from docs/export_targets_alignment.md. Consumers to date:
## none — this is the expansion seam for G3/export-preset and texture passes.
static func settings_for(profile: String) -> Dictionary:
	match profile:
		PROFILE_DESKTOP:
			return {
				"texture_compression": "bptc_s3tc",  # BC7 / S3TC desktop VRAM formats
				"max_texture_size": 0,               # 0 = uncapped (GPU-memory question)
				"shader_set": "forward_plus",
			}
		PROFILE_WEB:
			return {
				"texture_compression": "basis_or_uncompressed",  # no S3TC assumption in browsers
				"max_texture_size": 2048,            # driver is download time
				"shader_set": "compatibility",
			}
		PROFILE_MOBILE:
			return {
				"texture_compression": "astc_etc2",  # ASTC preferred, ETC2 baseline
				"max_texture_size": 2048,            # delivery + GPU memory + thermal
				"shader_set": "compatibility",       # web audit carries over
			}
	push_error("export_profiles: unknown profile '%s'" % profile)
	return {}
