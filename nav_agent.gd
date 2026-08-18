extends CharacterBody3D

## Generic navigation agent.
##
## Adapted from the Godot 4 navigation demo's `beetle_move_to_position.gd`,
## stripped of the beetle model / animation and driven by a plain capsule.
##
## Usage:
##   agent.target_global_position = some_vector3   # walks there
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

@onready var _skin: Node3D = %Skin
@onready var _nav: NavigationAgent3D = %NavigationAgent3D


func _ready() -> void:
	_nav.navigation_finished.connect(_on_navigation_finished)
	_nav.max_speed = speed
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


func stop() -> void:
	set_physics_process(false)
	set_avoidance_enabled(false)


## Walk to an explicit world position, overriding whatever the agent was doing.
##
## Wandering is switched off so the agent stays put once it arrives; pass
## `keep_wandering = true` if it should carry on roaming after reaching the spot.
func go_to(world_position: Vector3, keep_wandering: bool = false) -> void:
	wander = keep_wandering
	target_global_position = world_position


## Hand control back to the roaming behaviour.
func resume_wander() -> void:
	wander = true
	_pick_random_target()


func _on_navigation_finished() -> void:
	stop()
	destination_reached.emit()
	if wander:
		await get_tree().create_timer(wander_idle_time).timeout
		if is_inside_tree() and wander:
			_pick_random_target()


func _pick_random_target() -> void:
	var map: RID = _nav.get_navigation_map()
	if not map.is_valid() or NavigationServer3D.map_get_iteration_id(map) == 0:
		# Map not ready yet — retry next frame.
		await get_tree().physics_frame
		# `wander` may have been cleared by go_to() while we were waiting.
		if is_inside_tree() and wander:
			_pick_random_target()
		return
	target_global_position = NavigationServer3D.map_get_random_point(map, wander_layers, false)
