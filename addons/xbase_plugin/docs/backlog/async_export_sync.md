# Plan: Async Frame-Spread Export & Sync with Cancellation

## Status: Backlog

## Context

Both "Export Addressables" and "Sync AM ThingLink" freeze the editor because they run synchronous loops over all scenes (load → process → write, per scene). We want to spread work across frames (one scene per frame), add cancellation via button toggle, and share the async mechanism between both operations.

## Approach: Shared `AsyncJobRunner` + `_process()` on EditorPlugin

### New file: `async_job_runner.gd`

A lightweight `RefCounted` that manages a frame-spread, cancellable job:

- **Items**: array of work items (scene paths) — set dynamically from setup
- **Phases**: array of callables run per item, one phase per `_process()` frame
- **Lifecycle**: `setup_fn` (frame 1) → per-item phases → `finish_fn` (final frame)
- **Cancel**: `cancel()` sets a flag, checked at each iteration boundary; calls `cancel_fn` for cleanup
- **Signals**: `job_finished`, `job_cancelled`
- **Progress**: prints `"Processing N/total: path"` on each item advance
- `tick()` → called once per `_process()` frame, returns `true` when done

### Changes to `xbase_plugin.gd`

**Add `_process(delta)`**: drives `_active_job.tick()` each frame. No-ops when idle.

**Export button toggle** (`_on_export_button_up`):
- If idle: build `AsyncJobRunner` with export phases, change button text to "Cancel Export", disable Sync button
- If running: call `_active_job.cancel()`

**Export phases** (2 per scene):
1. `_xfab_phase_load`: skip-existing check, `ResourceLoader.load()`, `instantiate()`, `XFabExporter_file()` (CSV — fast)
2. `_xfab_phase_export`: `XFabExporter_geometry()` (GLB — heavy), `queue_free()`

**Setup**: `_xfab_setup` calls `get_exportable_scenes()`, applies open-only filter, feeds items to runner
**Finish**: `_xfab_finish` calls `create_xwab_json()` + `create_catalog_file()`, restores buttons
**Cancel**: `_xfab_cancel` frees any held scene instance, restores buttons

**Sync button toggle** (`_on_sync_button_up`):
- If idle: build `AsyncJobRunner` with sync phases, change button text to "Cancel Sync", disable Export button
- If running: call `_active_job.cancel()`

**Sync phases** (1 per file):
1. `_sync_phase_process`: calls `sync._process_scene_file(file_path)` (load+mutate+save)

**Setup**: `_sync_setup` calls `sync._reset_stats()` + `sync._scan_for_candidate_files()`
**Finish**: `_sync_finish` calls `sync._print_summary()` + filesystem scan, restores buttons
**Cancel**: `_sync_cancel` restores buttons

**Button wiring** in `_enter_tree()`: reconnect export → `_on_export_button_up`, sync → `_on_sync_button_up`

**Mutual exclusion**: only one `_active_job` at a time; the other button is disabled.

**`_exit_tree()`**: cancel any active job on plugin unload.

### Headless compatibility — no changes needed

- `xBaseHeadless.gd` calls `XFabExporter()` directly (the synchronous method stays intact)
- `SyncAmThingLinkHeadless.gd` calls `sync.execute()` directly (unchanged)
- The async path is a separate code path triggered only by dock buttons

### Files to modify

| File | Change |
|---|---|
| `async_job_runner.gd` | **New** — shared `AsyncJobRunner` class |
| `xbase_plugin.gd` | Add `_active_job`, `_process()`, button toggles, phase callables, signal handlers, update `_enter_tree`/`_exit_tree` |
| `xBasePluginScene.tscn` | No changes |
| `sync_am_thinglink.gd` | No changes |
| `xBaseHeadless.gd` | No changes |
| `SyncAmThingLinkHeadless.gd` | No changes |

## Verification

1. Open Godot editor with the plugin enabled
2. Click "Export Addressables" — should show "Cancel Export", editor stays responsive, scenes process one-per-frame with progress output
3. Click "Cancel Export" mid-run — should stop, restore button text, print cancellation message
4. Click "Sync AM ThingLink" — should show "Cancel Sync", process one file per frame
5. While export runs, Sync button should be disabled (and vice versa)
6. Headless: `godot --headless --editor --script res://addons/xbase_plugin/xBaseHeadless.gd` still works synchronously
7. Headless: `godot --headless --editor --script res://addons/xbase_plugin/SyncAmThingLinkHeadless.gd` still works
