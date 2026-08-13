extends SceneTree

## Headless GLB + CSV + XWAB export runner
##
## Usage (from project directory):
##   godot --headless --editor --script res://addons/xbase_plugin/xBaseHeadless.gd
##
## Options (pass after --):
##   --scene <path>      Restrict to a single scene (relative path, e.g. levels/EI008.0_LevelGroup.tscn)
##   --buildTarget=<t>   Unity build-target CLI id (Win64, Linux64, WebGL,
##                       iOS, Android — see PlatformIds). Default: WebGL.
##                       Parsed from the full argv by
##                       get_build_target_from_command_line, not the loop
##                       below. Resolved to an internal asset profile via
##                       export_profiles.gd (docs/export_targets_alignment.md).
##   --skip-glb          Skip GLB geometry export (ThingLink CSV still written).
##                       Useful for fast CI runs that only need data round-trip.
##   --export-pck        Also emit a per-scene .pck containing the source .tscn
##                       and dependencies. Independent of --skip-glb (combine for
##                       PCK-only output, omit --skip-glb for GLB+PCK both).
##                       Consumed by the runtime ProcessPrefabThingLinks pipeline.
##
## Examples:
##   godot --headless --editor --script res://addons/xbase_plugin/xBaseHeadless.gd -- --scene levels/EI008.0_LevelGroup.tscn
##   godot --headless --editor --script res://addons/xbase_plugin/xBaseHeadless.gd -- --skip-glb
##   godot --headless --editor --script res://addons/xbase_plugin/xBaseHeadless.gd -- --export-pck --skip-glb

const xbase_plugin = preload("res://addons/xbase_plugin/xbase_plugin.gd")

func get_project_absolute_path() -> String:
	var project_path: String  = "res://"
	var absolute_path: String = ProjectSettings.globalize_path(project_path)
	return absolute_path


func _init():
	var build_dir: String = get_project_absolute_path() + "/build"

	# Ensure build directory has .gdignore so Godot doesn't import GLB output
	DirAccess.make_dir_recursive_absolute(build_dir)
	var gdignore_path: String = build_dir + "/.gdignore"
	if not FileAccess.file_exists(gdignore_path):
		var f = FileAccess.open(gdignore_path, FileAccess.WRITE)
		if f:
			f.close()

	# Parse command-line arguments
	var args = OS.get_cmdline_user_args()
	var scene_paths: Array = []
	var skip_glb := false
	var export_pck := false
	var i = 0
	while i < args.size():
		if args[i] == "--scene" and i + 1 < args.size():
			scene_paths.append(args[i + 1])
			i += 2
		elif args[i] == "--skip-glb":
			skip_glb = true
			i += 1
		elif args[i] == "--export-pck":
			export_pck = true
			i += 1
		else:
			i += 1

	var xbp = xbase_plugin.new()
	xbp.xScape_ProgramData_Dir = build_dir
	xbp.headless_skip_glb = skip_glb
	xbp.headless_export_pck = export_pck
	if skip_glb:
		print("--skip-glb set — no GLB geometry written")
	if export_pck:
		print("--export-pck set — emitting scene .pck per scene")
	if not scene_paths.is_empty():
		xbp.restrict_to_scenes = scene_paths
		print("Restricting export to: %s" % str(scene_paths))

	var export_errors = xbp.XFabExporter()

	# EditorPlugin is a Node — must be freed explicitly; assigning null just
	# leaks the instance into editor teardown (access-violation crashes at exit)
	xbp.free()
	# Force immediate exit after a short delay
	OS.delay_msec(2000)
	if export_errors > 0:
		push_error("Headless export failed: %d scene(s) had errors" % export_errors)
	quit(1 if export_errors > 0 else 0)

	
