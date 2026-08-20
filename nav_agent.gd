extends CharacterBody3D

## Generic navigation agent.
##
## Adapted from the Godot 4 navigation demo's `beetle_move_to_position.gd`,
## stripped of the beetle model / animation and driven by a plain capsule.
##
## Usage:
##   agent.target_global_position = some_vector3   # walks there
##   agent.go_to(some_vector3)                     # walks there, stops wandering
##   agent.stop()                                  # halts
## Or tick `wander` in the inspector to have it roam the NavMesh on its own.

signal destination_reached

## Movement speed in metres per second.
@export var speed: float = 3.0:
	set(value):
		speed = value
		if is_instance_valid(_nav):
			_nav.max_speed = value

@export_group("Wandering")
## Pick random NavMesh points forever instead of waiting for commands.
@export var wander: bool = true
## Seconds to pause at each destination before choosing the next one.
@export var wander_idle_time: float = 2.0
## Which navigation layers random points may be drawn from.
@export_flags_3d_navigation var wander_layers: int = 1

@export_group("Turning")
## How quickly the skin swivels to face the direction of travel.
@export var turn_responsiveness: float = 10.0

@export_group("Trail")
## Draw the route still ahead of the agent, redrawn every physics frame.
@export var show_trail: bool = true:
	set(value):
		show_trail = value
		if is_instance_valid(_trail):
			_trail.visible = value
			if not value:
				_clear_trail()
## One colour is drawn from this at random per agent.
@export var trail_palette: PackedColorArray = PackedColorArray([
	Color(0.30, 0.85, 0.40, 0.9),
	Color(0.98, 0.83, 0.20, 0.9),
	Color(0.25, 0.60, 1.00, 0.9),
])
## Height above the floor the trail is drawn at, in metres.
@export var trail_height: float = 0.15

## Colour this agent drew from `trail_palette`.
var trail_color := Color.WHITE

## Setting this starts the walk. Assign Vector3.INF to clear it.
var target_global_position := Vector3.INF:
	set(new_target):
		target_global_position = new_target
		var is_near := global_position.distance_to(new_target) < _nav.target_desired_distance
		var has_new_target := not is_near and new_target != Vector3.INF
		set_physics_process(has_new_target)
		set_avoidance_enabled(has_new_target)
		if has_new_target:
			if not _nav.velocity_computed.is_connected(move):
				_nav.velocity_computed.connect(move)
			_nav.target_position = new_target

## Frames of failed NavMesh sampling before we assume it is misconfigured.
const _WANDER_WARN_AFTER := 180

@onready var _skin: Node3D = %Skin
@onready var _nav: NavigationAgent3D = %NavigationAgent3D

var _wander_retries := 0
var _trail: MeshInstance3D
var _trail_mesh: ImmediateMesh
var _trail_material: StandardMaterial3D


func _ready() -> void:
	_nav.navigation_finished.connect(_on_navigation_finished)
	_nav.max_speed = speed
	# The built-in debug path can't be trimmed, so draw our own.
	_nav.debug_enabled = false
	_make_trail()
	set_physics_process(false)

	if wander:
		# Let the navigation map bake at least once before querying it.
		await get_tree().physics_frame
		_pick_random_target()


func set_avoidance_enabled(enabled: bool) -> void:
	_nav.avoidance_enabled = enabled
	if not enabled and _nav.velocity_computed.is_connected(move):
		_nav.velocity_computed.disconnect(move)


func set_avoidance_radius(radius: float) -> void:
	_nav.radius = radius


func _physics_process(_delta: float) -> void:
	# Queried every frame so moving platforms / rebaked meshes are respected.
	var next_location := _nav.get_next_path_position()
	var direction := (next_location - global_position).normalized()

	var new_velocity := direction * speed
	if _nav.avoidance_enabled:
		_nav.velocity = new_velocity
	else:
		move(new_velocity)


func move(safe_velocity: Vector3) -> void:
	velocity = safe_velocity

	# Swivel the skin towards travel direction, smoothed over time.
	if velocity.length_squared() > 0.001:
		var look_target := global_position + velocity
		look_target.y = _skin.global_position.y
		if _skin.global_position.distance_squared_to(look_target) > 0.001:
			var previous_transform := _skin.global_transform
			_skin.look_at(look_target, Vector3.UP, true)
			_skin.global_transform = previous_transform.interpolate_with(
				_skin.global_transform,
				turn_responsiveness * get_physics_process_delta_time()
			)

	move_and_slide()

	# After the move, so the trail starts exactly where the agent now is.
	if show_trail:
		_draw_trail()


func stop() -> void:
	set_physics_process(false)
	set_avoidance_enabled(false)
	_clear_trail()


## Walk to a specific point. Wandering is switched off so the agent stays put
## once it arrives.
func go_to(world_position: Vector3, keep_wandering: bool = false) -> void:
	wander = keep_wandering
	target_global_position = world_position


## Hand control back to the roaming behaviour.
func resume_wander() -> void:
	wander = true
	_pick_random_target()


## Recompute the route to the current target, e.g. after the NavMesh changed.
func repath() -> void:
	if target_global_position != Vector3.INF:
		_nav.target_position = target_global_position


## Show or hide this agent's trail.
func set_trail(is_visible: bool) -> void:
	show_trail = is_visible


func _make_trail() -> void:
	if not trail_palette.is_empty():
		trail_color = trail_palette[randi() % trail_palette.size()]

	_trail_material = StandardMaterial3D.new()
	_trail_material.albedo_color = trail_color
	_trail_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_trail_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_trail_material.no_depth_test = true

	_trail_mesh = ImmediateMesh.new()

	_trail = MeshInstance3D.new()
	_trail.name = "Trail"
	_trail.mesh = _trail_mesh
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail.visible = show_trail
	add_child(_trail)
	# Vertices are world space, so detach from the agent's transform.
	_trail.top_level = true
	_trail.global_transform = Transform3D.IDENTITY


## Redraw the route ahead, anchored at the agent's current position.
func _draw_trail() -> void:
	if not is_instance_valid(_trail_mesh):
		return
	_trail_mesh.clear_surfaces()

	var path := _nav.get_current_navigation_path()
	var index := _nav.get_current_navigation_path_index()
	# stop() can run mid-frame from navigation_finished; without this the agent
	# leaves a stub of trail at its destination.
	if _nav.is_navigation_finished() or path.is_empty() or index >= path.size():
		return

	var lift := Vector3.UP * trail_height
	_trail_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _trail_material)
	_trail_mesh.surface_add_vertex(global_position + lift)
	for i in range(index, path.size()):
		_trail_mesh.surface_add_vertex(path[i] + lift)
	_trail_mesh.surface_end()


func _clear_trail() -> void:
	if is_instance_valid(_trail_mesh):
		_trail_mesh.clear_surfaces()


func _on_navigation_finished() -> void:
	stop()
	destination_reached.emit()
	if wander:
		await get_tree().create_timer(wander_idle_time).timeout
		if is_inside_tree() and wander:
			_pick_random_target()


func _pick_random_target() -> void:
	var map: RID = _nav.get_navigation_map()
	var point := Vector3.ZERO
	if map.is_valid():
		point = NavigationServer3D.map_get_random_point(map, wander_layers, false)

	# map_get_random_point returns the origin when it finds nothing, and the map
	# reports a non-zero iteration id a few frames before it can be sampled — so
	# trust the point, not the id, or the whole crowd walks to (0, 0, 0).
	if point == Vector3.ZERO:
		_wander_retries += 1
		if _wander_retries == _WANDER_WARN_AFTER:
			push_warning(("%s: still no random NavMesh point. Check the region's " +
				"navigation_layers against this agent's wander_layers.") % name)
		await get_tree().physics_frame
		# go_to() may have cleared `wander` while we waited.
		if is_inside_tree() and wander:
			_pick_random_target()
		return

	_wander_retries = 0
	target_global_position = point
