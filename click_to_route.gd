extends Node3D

## Click-to-route controller.
##
## Left-click sends every agent to the point under the cursor, R hands them back
## to their own wandering, H shows or hides their trails. F switches to emergency
## mode, where left-click drops a temporary obstacle that is carved out of the
## NavMesh. Emergency mode is a wandering mode: entering it drops any routing
## order and hands the crowd back to roaming.
##
## Drop this node anywhere in the scene — it finds the camera, the navigation map
## and the agents itself. Agents are located by group and need `go_to()`,
## `resume_wander()` and `set_trail()`.

signal agents_routed(world_position: Vector3, count: int)
signal wander_resumed(count: int)
signal trails_toggled(are_visible: bool)
signal emergency_toggled(is_active: bool)
signal obstacle_dropped(world_position: Vector3)

@export_group("Input")
## Group the agents belong to.
@export var agent_group: StringName = &"nav_agents"
## Mouse button that issues the move order.
@export var command_button: MouseButton = MOUSE_BUTTON_LEFT
## Puts every agent back into wander mode. KEY_NONE disables it.
@export var resume_wander_key: Key = KEY_R
## Shows or hides every agent's trail. KEY_NONE disables it.
@export var toggle_trails_key: Key = KEY_H
## Toggles emergency mode. KEY_NONE disables it.
@export var emergency_key: Key = KEY_F
## Whether trails start out visible.
@export var trails_visible: bool = true
## Send the crowd off roaming as soon as the scene starts.
@export var start_wandering: bool = true

@export_group("Targeting")
## Radius the agents are scattered over so they don't all target the same spot.
@export var spread_radius: float = 2.0
## How far a click may land from the NavMesh before it is ignored, in metres.
@export var max_snap_distance: float = 6.0
## Length of the picking ray, in metres.
@export var ray_length: float = 4000.0

@export_group("Emergency obstacles")
## Seconds a dropped obstacle lasts before it clears itself.
@export var obstacle_lifetime: float = 5.0
## Footprint radius of a dropped obstacle, in metres.
@export var obstacle_radius: float = 2.0
@export var obstacle_height: float = 2.0
@export var obstacle_color: Color = Color(1.0, 0.25, 0.2, 0.45)
## Corners in the carved footprint.
@export_range(3, 32) var obstacle_sides: int = 8
## How far below the clicked point the carve starts, in metres. A NavMesh floats
## above the floor it was baked from, and an obstruction that starts above the
## floor surface silently carves nothing, so sink it to straddle the geometry.
@export var carve_depth: float = 1.0
## Region re-baked when obstacles come and go. Found automatically if left empty.
@export var navigation_region: NodePath

@export_group("Feedback")
## Drop a marker on the chosen destination.
@export var show_marker: bool = true
@export var marker_color: Color = Color(1.0, 0.85, 0.1, 0.9)
@export var marker_radius: float = 0.45
## Show a usage hint in the corner of the screen.
@export var show_hint: bool = true

## Spreads any number of points over a disc without clumping.
const _GOLDEN_ANGLE := 2.399963229728653
## Give up waiting for the navigation map to pick up a fresh bake.
const _MAX_SYNC_FRAMES := 30

## Left-click drops obstacles instead of routing the crowd while this is on.
var emergency_mode: bool = false

## Milliseconds the last re-bake took. Watch this to tune `cell_size`.
var last_bake_msec := 0

var _region: NavigationRegion3D
var _baking := false
var _bake_queued := false
var _bake_started_msec := 0
var _pending: Array[NavigationObstacle3D] = []
var _marker: MeshInstance3D
var _hint: Label


func _ready() -> void:
	_region = get_node_or_null(navigation_region) as NavigationRegion3D
	if _region == null:
		_region = _find_region()
	if _region != null:
		_region.bake_finished.connect(_on_bake_finished)

	if show_marker:
		_make_marker()
	if show_hint:
		_make_hint()
	# Deferred so every agent has run its own _ready() first.
	if not trails_visible:
		set_trails.call_deferred(false)
	if start_wandering:
		wander_all.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if not button.pressed or button.button_index != command_button:
			return
		# Cursor position is meaningless while the camera has the mouse captured.
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			return
		get_viewport().set_input_as_handled()
		_on_click(button.position)
		return

	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		if resume_wander_key != KEY_NONE and key.keycode == resume_wander_key:
			get_viewport().set_input_as_handled()
			wander_all()
		elif toggle_trails_key != KEY_NONE and key.keycode == toggle_trails_key:
			get_viewport().set_input_as_handled()
			toggle_trails()
		elif emergency_key != KEY_NONE and key.keycode == emergency_key:
			get_viewport().set_input_as_handled()
			set_emergency(not emergency_mode)


func _on_click(screen_position: Vector2) -> void:
	var point := _pick_point(screen_position)
	if point == Vector3.INF:
		_set_hint("No navigable ground under the cursor")
		return

	if emergency_mode:
		drop_obstacle(point)
		return

	var count := route_all(point)

	if is_instance_valid(_marker):
		_marker.global_position = point + Vector3.UP * 0.05
		_marker.visible = true

	_set_hint("%d agents heading to (%.1f, %.1f, %.1f)" % [count, point.x, point.y, point.z])
	agents_routed.emit(point, count)


## Screen position to a point on the NavMesh, or Vector3.INF if there isn't one.
func _pick_point(screen_position: Vector2) -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		push_warning("ClickToRoute: no active Camera3D in the viewport.")
		return Vector3.INF

	var map: RID = get_world_3d().navigation_map
	if not map.is_valid():
		push_warning("ClickToRoute: no navigation map on this world.")
		return Vector3.INF

	var from := cam.project_ray_origin(screen_position)
	var to := from + cam.project_ray_normal(screen_position) * ray_length
	var raw := Vector3.INF

	# Physics first, so clicking a wall doesn't pick the room behind it.
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.exclude = _agent_rids()
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		raw = hit["position"]
	else:
		var nav_hit := NavigationServer3D.map_get_closest_point_to_segment(map, from, to, true)
		if nav_hit != Vector3.ZERO:
			raw = nav_hit

	if raw == Vector3.INF:
		return Vector3.INF

	var snapped := NavigationServer3D.map_get_closest_point(map, raw)
	return snapped if snapped.distance_to(raw) <= max_snap_distance else Vector3.INF


## Agent collision RIDs, so the picking ray passes through the crowd.
func _agent_rids() -> Array[RID]:
	var rids: Array[RID] = []
	for node in get_tree().get_nodes_in_group(agent_group):
		if node is CollisionObject3D:
			rids.append((node as CollisionObject3D).get_rid())
	return rids


## Retarget every agent. Returns how many were commanded.
func route_all(world_position: Vector3) -> int:
	var map: RID = get_world_3d().navigation_map
	var agents := get_tree().get_nodes_in_group(agent_group)
	var total := agents.size()
	var sent := 0

	for agent in agents:
		if not agent.has_method("go_to"):
			continue
		var target := world_position
		if spread_radius > 0.0 and total > 1:
			target = NavigationServer3D.map_get_closest_point(
				map, world_position + _spread(sent, total)
			)
		agent.call("go_to", target)
		sent += 1

	return sent


## Hand every agent back to its own wandering behaviour.
func wander_all() -> int:
	var resumed := 0
	for agent in get_tree().get_nodes_in_group(agent_group):
		if agent.has_method("resume_wander"):
			agent.call("resume_wander")
			resumed += 1

	if is_instance_valid(_marker):
		_marker.visible = false
	_set_hint("%d agents wandering" % resumed)
	wander_resumed.emit(resumed)
	return resumed


## Turn emergency mode on or off. Returns the state applied.
func set_emergency(is_active: bool) -> bool:
	emergency_mode = is_active
	if is_active:
		# Emergency mode is a wandering mode — drop any standing routing order.
		wander_all()
	_set_hint("Emergency mode %s" % ("ON" if is_active else "off"))
	emergency_toggled.emit(is_active)
	return is_active


## Carve an obstacle out of the NavMesh and clear it after `obstacle_lifetime`.
## Any number can be live at once.
func drop_obstacle(world_position: Vector3) -> NavigationObstacle3D:
	if _region == null:
		push_warning("ClickToRoute: no NavigationRegion3D to carve.")
		return null

	var obstacle := NavigationObstacle3D.new()
	obstacle.name = "EmergencyObstacle"
	obstacle.height = obstacle_height + carve_depth
	obstacle.vertices = _footprint()
	obstacle.affect_navigation_mesh = true
	obstacle.carve_navigation_mesh = true
	obstacle.avoidance_enabled = false
	obstacle.add_child(_make_obstacle_mesh())

	# Parented to the region because the bake only parses that subtree.
	_region.add_child(obstacle)
	obstacle.global_position = world_position - Vector3.UP * carve_depth
	obstacle.tree_exited.connect(_request_bake, CONNECT_DEFERRED)
	# Expiry starts once the carve lands, not now — see _on_bake_finished.
	_pending.append(obstacle)
	_request_bake()

	_set_hint("Obstacle dropped, carving...")
	obstacle_dropped.emit(world_position)
	return obstacle


## Nudge every agent to recompute its route. NavigationAgent3D already
## invalidates its own path when the map changes, so this is belt and braces.
func repath_all() -> int:
	var count := 0
	for agent in get_tree().get_nodes_in_group(agent_group):
		if agent.has_method("repath"):
			agent.call("repath")
			count += 1
	return count


func _find_region() -> NavigationRegion3D:
	var root := get_tree().current_scene if get_tree().current_scene != null else get_parent()
	if root == null:
		return null
	var found := root.find_children("*", "NavigationRegion3D", true, false)
	return found[0] if not found.is_empty() else null


## Bakes are coalesced: drops landing mid-bake trigger one more pass afterwards.
## Tracked with our own flag because is_baking() still reads false for a moment
## after bake_navigation_mesh() is called, which loses obstacles.
func _request_bake() -> void:
	if _region == null:
		return
	if _baking:
		_bake_queued = true
		return
	_baking = true
	_bake_started_msec = Time.get_ticks_msec()
	_region.bake_navigation_mesh(true)


func _on_bake_finished() -> void:
	last_bake_msec = Time.get_ticks_msec() - _bake_started_msec

	# bake_finished fires before the server syncs the mesh into the map, which
	# takes a few physics frames. Reading or re-pathing before then uses the old
	# mesh. `_baking` stays set across the wait so drops queue rather than race.
	await _map_synced()
	_baking = false

	if _bake_queued:
		# That bake snapshotted the obstacle set as it was when it started.
		_bake_queued = false
		_request_bake()
		return

	# Obstacles only start ageing now, so a slow bake can't eat their whole life.
	var dropped := _pending.size()
	var carved := 0
	for obstacle in _pending:
		if not is_instance_valid(obstacle):
			continue
		if _is_carved(obstacle.global_position):
			carved += 1
		else:
			push_warning("ClickToRoute: obstacle at %s did not carve the NavMesh." %
				obstacle.global_position)
		get_tree().create_timer(obstacle_lifetime).timeout.connect(obstacle.queue_free)
	_pending.clear()

	repath_all()
	if dropped > 0:
		_set_hint("Re-baked in %d ms, %d/%d carved" % [last_bake_msec, carved, dropped])
	else:
		_set_hint("Re-baked in %d ms" % last_bake_msec)


## Blocks until the navigation map picks up the freshly baked mesh.
func _map_synced() -> void:
	var map: RID = get_world_3d().navigation_map
	var before := NavigationServer3D.map_get_iteration_id(map)
	for i in _MAX_SYNC_FRAMES:
		await get_tree().physics_frame
		if NavigationServer3D.map_get_iteration_id(map) != before:
			return
	push_warning("ClickToRoute: navigation map never picked up the new NavMesh.")


## Whether the NavMesh really has a hole here, i.e. the carve took effect.
func _is_carved(world_position: Vector3) -> bool:
	var nearest := NavigationServer3D.map_get_closest_point(
		get_world_3d().navigation_map, world_position
	)
	var gap := Vector2(nearest.x - world_position.x, nearest.z - world_position.z)
	return gap.length() > obstacle_radius * 0.5


func _footprint() -> PackedVector3Array:
	var points := PackedVector3Array()
	for i in obstacle_sides:
		var angle := TAU * float(i) / float(obstacle_sides)
		points.append(Vector3(cos(angle) * obstacle_radius, 0.0, sin(angle) * obstacle_radius))
	return points


func _make_obstacle_mesh() -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = obstacle_color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var cylinder := CylinderMesh.new()
	cylinder.top_radius = obstacle_radius
	cylinder.bottom_radius = obstacle_radius
	cylinder.height = obstacle_height
	cylinder.material = material

	var mesh := MeshInstance3D.new()
	mesh.mesh = cylinder
	# Sits back on the clicked point, undoing the carve sink.
	mesh.position = Vector3.UP * (carve_depth + obstacle_height * 0.5)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mesh


## Flip the trails on or off. Returns the new visibility.
func toggle_trails() -> bool:
	return set_trails(not trails_visible)


## Show or hide every agent's trail. Returns the visibility applied.
func set_trails(are_visible: bool) -> bool:
	trails_visible = are_visible
	var count := 0
	for agent in get_tree().get_nodes_in_group(agent_group):
		if agent.has_method("set_trail"):
			agent.call("set_trail", are_visible)
			count += 1

	_set_hint("Trails %s on %d agents" % ["shown" if are_visible else "hidden", count])
	trails_toggled.emit(are_visible)
	return are_visible


func _spread(index: int, total: int) -> Vector3:
	var radius: float = spread_radius * sqrt(float(index) / float(maxi(total - 1, 1)))
	var angle: float = _GOLDEN_ANGLE * float(index)
	return Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)


func _make_marker() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = marker_color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true

	var sphere := SphereMesh.new()
	sphere.radius = marker_radius
	sphere.height = marker_radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	sphere.material = material

	_marker = MeshInstance3D.new()
	_marker.name = "ClickMarker"
	_marker.mesh = sphere
	_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker.top_level = true
	_marker.visible = false
	add_child(_marker)


func _make_hint() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ClickToRouteHUD"
	add_child(layer)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.position = Vector2(16, 16)
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_hint.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hint)
	_set_hint("")


func _set_hint(status: String) -> void:
	if not is_instance_valid(_hint):
		return
	var keys := "Left-click: %s" % ("drop obstacle" if emergency_mode else "send all agents there")
	if resume_wander_key != KEY_NONE:
		keys += "    %s: resume wandering" % OS.get_keycode_string(resume_wander_key)
	if toggle_trails_key != KEY_NONE:
		keys += "    %s: show/hide trails" % OS.get_keycode_string(toggle_trails_key)
	if emergency_key != KEY_NONE:
		keys += "    %s: emergency mode" % OS.get_keycode_string(emergency_key)
	_hint.text = keys if status.is_empty() else "%s\n%s" % [keys, status]
