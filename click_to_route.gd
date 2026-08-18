extends Node3D

## Click-to-route controller.
##
## Left-click anywhere in the world and every NavAgent in the scene abandons
## its current destination and paths to the point under the cursor. Press the
## resume key to hand them back to their own wandering behaviour.
##
## Drop this node anywhere in the scene — it finds the active Camera3D, the
## navigation map and the agents by itself. Agents are located by group
## (`nav_agents`, set on the root of nav_agent.tscn) and must expose a
## `go_to(world_position)` method.

## Emitted after a successful click. `count` is how many agents were retargeted.
signal agents_routed(world_position: Vector3, count: int)
## Emitted when the agents are handed back to their wandering behaviour.
signal wander_resumed(count: int)

@export_group("Input")
## Group the agents belong to.
@export var agent_group: StringName = &"nav_agents"
## Mouse button that issues the move order.
@export var command_button: MouseButton = MOUSE_BUTTON_LEFT
## Key that puts every agent back into wander mode. Set to KEY_NONE to disable.
@export var resume_wander_key: Key = KEY_R

@export_group("Targeting")
## Agents are scattered inside this radius around the click so 100+ of them
## don't all fight over the same half-metre. 0 = everyone targets the exact point.
@export var spread_radius: float = 2.0
## How far a click may land from the NavMesh before it is ignored, in metres.
## Stops clicks on walls, ceilings and the skybox from teleporting the crowd.
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

## Golden angle — spreads N points evenly over a disc with no clumping.
const _GOLDEN_ANGLE := 2.399963229728653

var _marker: MeshInstance3D
var _hint: Label


func _ready() -> void:
	if show_marker:
		_build_marker()
	if show_hint:
		_build_hint()


# --------------------------------------------------------------------------
# Input
# --------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed or mb.button_index != command_button:
			return
		# The free-look camera captures the mouse on right-drag; while captured
		# the cursor position is meaningless, so ignore clicks.
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			return
		get_viewport().set_input_as_handled()
		_handle_click(mb.position)
		return

	if event is InputEventKey and resume_wander_key != KEY_NONE:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == resume_wander_key:
			get_viewport().set_input_as_handled()
			resume_wandering()


func _handle_click(screen_position: Vector2) -> void:
	var point := _resolve_click_point(screen_position)
	if point == Vector3.INF:
		_set_hint_status("No navigable ground under the cursor")
		return

	var count := send_all_agents_to(point)

	if is_instance_valid(_marker):
		_marker.global_position = point + Vector3.UP * 0.05
		_marker.visible = true

	_set_hint_status("%d agents heading to (%.1f, %.1f, %.1f)" % [
		count, point.x, point.y, point.z
	])
	agents_routed.emit(point, count)


# --------------------------------------------------------------------------
# Picking
# --------------------------------------------------------------------------

## Turns a screen position into a point that is guaranteed to sit on the
## NavMesh. Returns Vector3.INF if the click didn't land anywhere sensible.
func _resolve_click_point(screen_position: Vector2) -> Vector3:
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

	var raw_point := Vector3.INF

	# 1. Physics ray — respects floors, walls and furniture, so clicking behind
	#    a wall doesn't silently pick the room beyond it.
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = _agent_rids()
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		raw_point = hit["position"]
	else:
		# 2. Nothing solid under the cursor — intersect the NavMesh directly.
		var nav_hit := NavigationServer3D.map_get_closest_point_to_segment(map, from, to, true)
		if nav_hit != Vector3.ZERO:
			raw_point = nav_hit

	if raw_point == Vector3.INF:
		return Vector3.INF

	# Snap onto the NavMesh so agents always get a reachable target.
	var snapped := NavigationServer3D.map_get_closest_point(map, raw_point)
	if snapped.distance_to(raw_point) > max_snap_distance:
		return Vector3.INF
	return snapped


## Collision RIDs of every agent, so the picking ray passes through the crowd
## instead of stopping on whoever happens to be in the way.
func _agent_rids() -> Array[RID]:
	var rids: Array[RID] = []
	for node in get_tree().get_nodes_in_group(agent_group):
		if node is CollisionObject3D:
			rids.append((node as CollisionObject3D).get_rid())
	return rids


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

## Retarget every agent in the group. Returns how many were actually commanded.
func send_all_agents_to(world_position: Vector3) -> int:
	var map: RID = get_world_3d().navigation_map
	var agents := get_tree().get_nodes_in_group(agent_group)
	var total := agents.size()
	var sent := 0

	for i in total:
		var agent := agents[i]
		if not agent.has_method("go_to"):
			continue
		var target := world_position
		if spread_radius > 0.0 and total > 1:
			target = NavigationServer3D.map_get_closest_point(
				map, world_position + _disc_offset(sent, total)
			)
		agent.call("go_to", target)
		sent += 1

	return sent


## Hand every agent back to its own wandering behaviour.
func resume_wandering() -> int:
	var resumed := 0
	for agent in get_tree().get_nodes_in_group(agent_group):
		if agent.has_method("resume_wander"):
			agent.call("resume_wander")
			resumed += 1

	if is_instance_valid(_marker):
		_marker.visible = false
	_set_hint_status("%d agents wandering" % resumed)
	wander_resumed.emit(resumed)
	return resumed


## Evenly distributes `total` points over a disc of `spread_radius`.
func _disc_offset(index: int, total: int) -> Vector3:
	var r: float = spread_radius * sqrt(float(index) / float(maxi(total - 1, 1)))
	var a: float = _GOLDEN_ANGLE * float(index)
	return Vector3(cos(a) * r, 0.0, sin(a) * r)


# --------------------------------------------------------------------------
# Feedback
# --------------------------------------------------------------------------

func _build_marker() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = marker_color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true

	var mesh := SphereMesh.new()
	mesh.radius = marker_radius
	mesh.height = marker_radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	mesh.material = mat

	_marker = MeshInstance3D.new()
	_marker.name = "ClickMarker"
	_marker.mesh = mesh
	_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker.top_level = true
	_marker.visible = false
	add_child(_marker)


func _build_hint() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ClickToRouteHUD"
	add_child(layer)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.position = Vector2(16, 16)
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_hint.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hint)
	_set_hint_status("")


func _set_hint_status(status: String) -> void:
	if not is_instance_valid(_hint):
		return
	var keys := "Left-click: send all agents there"
	if resume_wander_key != KEY_NONE:
		keys += "    %s: resume wandering" % OS.get_keycode_string(resume_wander_key)
	_hint.text = keys if status.is_empty() else "%s\n%s" % [keys, status]
