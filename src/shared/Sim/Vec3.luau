--!strict
-- Plain-table 3D vectors for simulation code that must run under Lune as
-- well as in Roblox. Combat, positioning and AI use these; the thin Roblox
-- adapters convert to and from Vector3 at the edge.

export type Vec3 = { x: number, y: number, z: number }

local Vec3 = {}

Vec3.ZERO = table.freeze({ x = 0, y = 0, z = 0 })

function Vec3.new(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

function Vec3.add(a: Vec3, b: Vec3): Vec3
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

function Vec3.sub(a: Vec3, b: Vec3): Vec3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

function Vec3.scale(a: Vec3, s: number): Vec3
	return { x = a.x * s, y = a.y * s, z = a.z * s }
end

function Vec3.dot(a: Vec3, b: Vec3): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

function Vec3.magnitude(a: Vec3): number
	return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
end

function Vec3.distance(a: Vec3, b: Vec3): number
	return Vec3.magnitude(Vec3.sub(a, b))
end

-- Horizontal (XZ) distance, which most gameplay range checks want.
function Vec3.flatDistance(a: Vec3, b: Vec3): number
	local dx, dz = a.x - b.x, a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

function Vec3.unit(a: Vec3): Vec3
	local m = Vec3.magnitude(a)
	if m == 0 then
		return { x = 0, y = 0, z = 0 }
	end
	return { x = a.x / m, y = a.y / m, z = a.z / m }
end

function Vec3.isFinite(a: unknown): boolean
	if type(a) ~= "table" then
		return false
	end
	local v = a :: { [string]: unknown }
	for _, key in { "x", "y", "z" } do
		local n = v[key]
		if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
			return false
		end
	end
	return true
end

function Vec3.copy(a: Vec3): Vec3
	return { x = a.x, y = a.y, z = a.z }
end

return table.freeze(Vec3)
