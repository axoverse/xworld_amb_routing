extends SceneTree

## Headless runner for SyncAmThingLink
##
## Usage (from project directory):
##   godot --headless --editor --script res://addons/xbase_plugin/SyncAmThingLinkHeadless.gd
##
## Options (pass after --):
##   --scene <path>      Restrict to a single scene (e.g. res://levels/EI008.0_LevelGroup.tscn)
##   --override          Enable override_existing mode
##   --verbose           Force verbose logging on
##
## Example:
##   godot --headless --editor --script res://addons/xbase_plugin/SyncAmThingLinkHeadless.gd -- --scene res://levels/EI008.0_LevelGroup.tscn --verbose

const SyncAmThingLink = preload("res://addons/xbase_plugin/sync_am_thinglink.gd")

func _init():
	print("")
	print("========================================")
	print("  SyncAmThingLink Headless Runner")
	print("========================================")
	print("")

	var args = OS.get_cmdline_user_args()
	var scene_path: String = ""
	var override: bool = false
	var verbose: bool = false

	var i = 0
	while i < args.size():
		if args[i] == "--scene" and i + 1 < args.size():
			scene_path = args[i + 1]
			i += 2
		elif args[i] == "--override":
			override = true
			i += 1
		elif args[i] == "--verbose":
			verbose = true
			i += 1
		else:
			i += 1

	if verbose:
		ProjectSettings.set_setting("xbase_plugin/settings/verbose_logging", true)

	var sync = SyncAmThingLink.new()
	sync.override_existing = override

	if scene_path != "":
		sync.restrict_to_paths = [scene_path]
		print("Restricting to scene: %s" % scene_path)

	sync.execute()

	print("")
	print("Done. Exiting...")
	quit(0)
