Below is a complete, working-style Godot 4 GDScript that:

* Takes a baked NavigationMesh (from a NavigationRegion3D)
* Projects it onto XZ (typical floor plane)
* Rasterizes it into a 2D occupancy grid at a requested cell size (meters per cell)
* Outputs:

  * A 1D PackedInt32Array of values in ROS-style convention: free = 0, occupied = 100
  * Optionally unknown = -1 if you choose to use that outside a footprint (hook included)
  * Metadata (width, height, origin) you can use to export YAML/PNG later

Notes:

* This is the "navmesh implies free-space" method: if a cell center is inside navmesh polygons, it is free.
* Everything else is occupied (or unknown if you implement a separate building footprint mask).

GDScript (Godot 4.x)

```gdscript
# NavmeshToOccupancyGrid.gd
# Godot 4.x
#
# Usage:
#   var conv = NavmeshToOccupancyGrid.new()
#   var result = conv.generate_from_region($NavigationRegion3D, 0.10) # 10 cm cells
#   print(result.width, result.height, result.origin_world)
#   # result.data is PackedInt32Array of length width*height (row-major y->x)
#
# Assumptions:
# - Floor is the XZ plane (Y is up).
# - NavigationMesh is baked in a NavigationRegion3D.
# - Cell size is in world meters.

class_name NavmeshToOccupancyGrid
extends RefCounted

# Output container
class GridResult:
	var width: int
	var height: int
	var cell_size: float
	var origin_world: Vector3              # world-space origin of cell (0,0) corner (min_x, 0, min_z)
	var data: PackedInt32Array             # length = width*height, values like ROS: -1 unknown, 0 free, 100 occupied

# Public API
func generate_from_region(nav_region: NavigationRegion3D, cell_size: float) -> GridResult:
	assert(nav_region != null)
	assert(cell_size > 0.0)

	var nav_mesh: NavigationMesh = nav_region.navigation_mesh
	assert(nav_mesh != null)

	# Get navmesh vertices and indices in LOCAL space of the region
	var verts_local: PackedVector3Array = nav_mesh.vertices
	var indices: PackedInt32Array = nav_mesh.indices

	assert(verts_local.size() > 0)
	assert(indices.size() % 3 == 0)

	# Transform verts to WORLD space
	var xform: Transform3D = nav_region.global_transform
	var verts_world: PackedVector3Array = PackedVector3Array()
	verts_world.resize(verts_local.size())
	for i in range(verts_local.size()):
		verts_world[i] = xform * verts_local[i]

	# Compute world-space bounds on XZ plane (ignoring Y)
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for v in verts_world:
		min_x = min(min_x, v.x)
		max_x = max(max_x, v.x)
		min_z = min(min_z, v.z)
		max_z = max(max_z, v.z)

	# Pad bounds slightly so edge cells don't get clipped by float error
	var pad := cell_size * 0.5
	min_x -= pad
	min_z -= pad
	max_x += pad
	max_z += pad

	var width := int(ceil((max_x - min_x) / cell_size))
	var height := int(ceil((max_z - min_z) / cell_size))
	assert(width > 0 and height > 0)

	var result := GridResult.new()
	result.width = width
	result.height = height
	result.cell_size = cell_size
	result.origin_world = Vector3(min_x, 0.0, min_z)
	result.data = PackedInt32Array()
	result.data.resize(width * height)

	# Default everything to occupied (100).
	# If you prefer unknown for "outside building footprint", change the default to -1
	# and apply a footprint mask later.
	for i in range(result.data.size()):
		result.data[i] = 100

	# Rasterize triangles: mark cells whose center is inside any triangle as free (0).
	# For performance: iterate triangles, compute their AABB in grid coords, then test cell centers.
	var tri_count := indices.size() / 3
	for t in range(tri_count):
		var i0 := indices[t * 3 + 0]
		var i1 := indices[t * 3 + 1]
		var i2 := indices[t * 3 + 2]

		var a: Vector3 = verts_world[i0]
		var b: Vector3 = verts_world[i1]
		var c: Vector3 = verts_world[i2]

		# Work in 2D XZ
		var ax := a.x; var az := a.z
		var bx := b.x; var bz := b.z
		var cx := c.x; var cz := c.z

		# Triangle bounds in world XZ
		var tmin_x := min(ax, min(bx, cx))
		var tmax_x := max(ax, max(bx, cx))
		var tmin_z := min(az, min(bz, cz))
		var tmax_z := max(az, max(bz, cz))

		# Convert to grid index range
		var gx0 := clampi(int(floor((tmin_x - min_x) / cell_size)), 0, width - 1)
		var gx1 := clampi(int(ceil((tmax_x - min_x) / cell_size)), 0, width - 1)
		var gz0 := clampi(int(floor((tmin_z - min_z) / cell_size)), 0, height - 1)
		var gz1 := clampi(int(ceil((tmax_z - min_z) / cell_size)), 0, height - 1)

		# Fill cells
		for gz in range(gz0, gz1 + 1):
			var cz_world := min_z + (float(gz) + 0.5) * cell_size
			for gx in range(gx0, gx1 + 1):
				var cx_world := min_x + (float(gx) + 0.5) * cell_size

				if _point_in_triangle_2d(cx_world, cz_world, ax, az, bx, bz, cx, cz):
					var idx := gz * width + gx
					result.data[idx] = 0

	return result


# Barycentric sign method in 2D, robust enough for grid sampling.
# Returns true if P is inside triangle (including edges).
func _point_in_triangle_2d(px: float, pz: float,
		ax: float, az: float,
		bx: float, bz: float,
		cx: float, cz: float) -> bool:

	var d1 := _sign_2d(px, pz, ax, az, bx, bz)
	var d2 := _sign_2d(px, pz, bx, bz, cx, cz)
	var d3 := _sign_2d(px, pz, cx, cz, ax, az)

	var has_neg := (d1 < 0.0) or (d2 < 0.0) or (d3 < 0.0)
	var has_pos := (d1 > 0.0) or (d2 > 0.0) or (d3 > 0.0)

	return not (has_neg and has_pos)

func _sign_2d(px: float, pz: float,
		ax: float, az: float,
		bx: float, bz: float) -> float:
	return (px - bx) * (az - bz) - (ax - bx) * (pz - bz)


# Optional helper: convert grid to a grayscale Image (PGM/PNG style).
# Free = white, occupied = black, unknown = mid-gray.
func to_image(result: GridResult) -> Image:
	var img := Image.create(result.width, result.height, false, Image.FORMAT_L8)
	img.lock()
	for z in range(result.height):
		for x in range(result.width):
			var v := result.data[z * result.width + x]
			var c: int
			if v == 0:
				c = 255
			elif v == 100:
				c = 0
			else:
				# unknown (-1)
				c = 127
			img.set_pixel(x, z, Color8(c, c, c))
	img.unlock()
	return img
```

How you’d use it in a scene

```gdscript
# Example: in a Node script
@onready var nav_region: NavigationRegion3D = $NavigationRegion3D

func _ready():
	var conv := NavmeshToOccupancyGrid.new()
	var grid := conv.generate_from_region(nav_region, 0.10) # 10 cm cells

	print("grid:", grid.width, "x", grid.height, " origin:", grid.origin_world)

	# Optional: write an image for debugging
	var img := conv.to_image(grid)
	img.save_png("user://occupancy.png")
```

A couple of practical upgrades you will probably want next

1. Unknown vs occupied outside the building footprint

* Right now, anything not walkable is occupied.
* If you want unknown outside the building, you can:

  * Default grid to -1
  * Compute a "footprint polygon" per level (from your floor boundary mesh, or from Revit rooms/levels)
  * Mark cells inside footprint as occupied by default, then overwrite walkable as free.

2. Inflate obstacles after the fact (robot radius)

* If you bake navmesh with a tiny agent and then do inflation on the occupancy grid, you can produce different robot classes without rebaking.

3. Holes / enclosed voids

* Your point about enclosed pockets (around pillars, double walls) is exactly where navmesh helps, because those pockets simply won’t be in the navmesh if they’re unreachable or excluded by bake settings.

If you want, I can extend this into:

* Export to ROS map_server style: occupancy.png + map.yaml (origin, resolution, thresholds)
* A per-room extractor: given a room polygon, emit a sub-grid and origin offsets so you can publish room-scoped updates efficiently.
