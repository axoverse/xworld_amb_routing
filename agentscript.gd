extends CharacterBody3D

## Movement speed in units per second.
@export var movement_speed: float = 4.0
## How long (seconds) the agent idles after reaching a destination.
@export var idle_time: float = 2.0
## Navigation filter — which layers the random point must sit on.
@export_flags_3d_navigation var nav_layers: int = 1
## Show the path line and target marker at runtime.
@export var show_debug: bool = true
## Color of the path line.
@export var path_color: Color = Color(0.2, 0.8, 1.0, 0.8)
## Color of the target marker.
@export var target_color: Color = Color(1.0, 0.3, 0.2, 0.9)

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D

var _idle_timer: float = 0.0
var _is_idle: bool = false
var _path_mesh_instance: MeshInstance3D
var _target_mesh_instance: MeshInstance3D
var _path_material: StandardMaterial3D
var _target_material: StandardMaterial3D


func _ready() -> void:
	navigation_agent.velocity_computed.connect(_on_velocity_computed)
	_setup_debug_visuals()
	# Wait one physics frame so the navigation map has synced at least once.
	await get_tree().physics_frame
	_pick_new_destination()


func _setup_debug_visuals() -> void:
	# --- path line ---
	_path_material = StandardMaterial3D.new()
	_path_material.albedo_color = path_color
	_path_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_path_material.no_depth_test = true
	_path_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	_path_mesh_instance = MeshInstance3D.new()
	_path_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Add to the scene root so transforms are in world space.
	add_child(_path_mesh_instance)
	_path_mesh_instance.top_level = true

	# --- target marker (small sphere) ---
	_target_material = StandardMaterial3D.new()
	_target_material.albedo_color = target_color
	_target_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_target_material.no_depth_test = true
	_target_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var sphere := SphereMesh.new()
	sphere.radius = 0.25
	sphere.height = 0.5
	sphere.radial_segments = 12
	sphere.rings = 6
	sphere.material = _target_material

	_target_mesh_instance = MeshInstance3D.new()
	_target_mesh_instance.mesh = sphere
	_target_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_target_mesh_instance.visible = false
	add_child(_target_mesh_instance)
	_target_mesh_instance.top_level = true


func _pick_new_destination() -> void:
	var map_rid: RID = navigation_agent.get_navigation_map()
	var random_pos: Vector3 = NavigationServer3D.map_get_random_point(
		map_rid, nav_layers, false
	)
	navigation_agent.set_target_position(random_pos)
	_is_idle = false

	if show_debug:
		_target_mesh_instance.global_position = random_pos + Vector3(0, 0.3, 0)
		_target_mesh_instance.visible = true


func _physics_process(delta: float) -> void:
	# Skip until the navigation map has been baked at least once.
	if NavigationServer3D.map_get_iteration_id(navigation_agent.get_navigation_map()) == 0:
		return

	# --- idle state: count down, then pick a new destination ---
	if _is_idle:
		_idle_timer -= delta
		if _idle_timer <= 0.0:
			_pick_new_destination()
		return

	# --- arrived: start idling ---
	if navigation_agent.is_navigation_finished():
		_is_idle = true
		_idle_timer = idle_time
		if show_debug:
			_target_mesh_instance.visible = false
			_path_mesh_instance.mesh = null
		return

	# --- moving toward target ---
	# get_next_path_position() triggers an internal path query update,
	# so call it BEFORE reading the path for debug drawing.
	var next_pos: Vector3 = navigation_agent.get_next_path_position()

	# --- update debug path (right after the path has been refreshed) ---
	if show_debug:
		_update_path_visual()

	var direction: Vector3 = global_position.direction_to(next_pos)
	var new_velocity: Vector3 = direction * movement_speed

	# Face movement direction (only rotate on the Y axis).
	if direction.length_squared() > 0.001:
		var look_target: Vector3 = global_position + direction
		look_target.y = global_position.y
		if global_position.distance_squared_to(look_target) > 0.001:
			look_at(look_target)

	if navigation_agent.avoidance_enabled:
		navigation_agent.set_velocity(new_velocity)
	else:
		_on_velocity_computed(new_velocity)


func _update_path_visual() -> void:
	var path_points: PackedVector3Array = navigation_agent.get_current_navigation_path()
	var path_idx: int = navigation_agent.get_current_navigation_path_index()

	# Only draw from the current segment onward.
	if path_idx >= path_points.size():
		_path_mesh_instance.mesh = null
		return

	# Reuse or create an ImmediateMesh — clear it each frame.
	var im: ImmediateMesh
	if _path_mesh_instance.mesh is ImmediateMesh:
		im = _path_mesh_instance.mesh
		im.clear_surfaces()
	else:
		im = ImmediateMesh.new()
		_path_mesh_instance.mesh = im

	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _path_material)

	# Start at the agent's actual position.
	im.surface_add_vertex(global_position + Vector3(0, 0.15, 0))

	for i in range(path_idx, path_points.size()):
		im.surface_add_vertex(path_points[i] + Vector3(0, 0.15, 0))

	im.surface_end()


func _on_velocity_computed(safe_velocity: Vector3) -> void:
	velocity = safe_velocity
	move_and_slide()
