extends Node3D

## Click-to-route controller.
##
## Left-click sends every agent to the point under the cursor, R hands them back
## to their own wandering, H shows or hides their trails.
##
## Drop this node anywhere in the scene — it finds the camera, the navigation map
## and the agents itself. Agents are located by group and need `go_to()`,
## `resume_wander()` and `set_trail()`.

signal agents_routed(world_position: Vector3, count: int)
signal wander_resumed(count: int)
signal trails_toggled(are_visible: bool)

@export_group("Input")
## Group the agents belong to.
@export var agent_group: StringName = &"nav_agents"
## Mouse button that issues the move order.
@export var command_button: MouseButton = MOUSE_BUTTON_LEFT
## Puts every agent back into wander mode. KEY_NONE disables it.
@export var resume_wander_key: Key = KEY_R
## Shows or hides every agent's trail. KEY_NONE disables it.
@export var toggle_trails_key: Key = KEY_H
## Whether trails start out visible.
@export var trails_visible: bool = true

@export_group("Targeting")
## Radius the agents are scattered over so they don't all target the same spot.
@export var spread_radius: float = 2.0
## How far a click may land from the NavMesh before it is ignored, in metres.
@export var max_snap_distance: float = 6.0
## Length of the picking ray, in metres.
@export var ray_length: float = 4000.0

@export_group("Feedback")
## Drop a marker on the chosen destination.
@export var show_marker: bool = true
@export var marker_color: Color = Color(1.0, 0.85, 0.1, 0.9)
@export var marker_radius: float = 0.45
## Show a usage hint in the corner of the screen.
@export var show_hint: bool = true

## Spreads any number of points over a disc without clumping.
const _GOLDEN_ANGLE := 2.399963229728653

var _marker: MeshInstance3D
var _hint: Label


func _ready() -> void:
	if show_marker:
		_make_marker()
	if show_hint:
		_make_hint()
	if not trails_visible:
		# Deferred so every agent has run _ready() first.
		set_trails.call_deferred(false)


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


func _on_click(screen_position: Vector2) -> void:
	var point := _pick_point(screen_position)
	if point == Vector3.INF:
		_set_hint("No navigable ground under the cursor")
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
	var keys := "Left-click: send all agents there"
	if resume_wander_key != KEY_NONE:
		keys += "    %s: resume wandering" % OS.get_keycode_string(resume_wander_key)
	if toggle_trails_key != KEY_NONE:
		keys += "    %s: show/hide trails" % OS.get_keycode_string(toggle_trails_key)
	_hint.text = keys if status.is_empty() else "%s\n%s" % [keys, status]
