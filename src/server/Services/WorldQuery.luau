--!strict
-- Collision queries for server-moved combatants (Roblox adapter).
--
-- The Verse movement effects never trust a destination. They ask this
-- adapter for the farthest point that is actually reachable, so a move can
-- never cross:
--
--   * a solid part (walls, locked doors, gates: anything that collides),
--   * a part tagged "BM_Boundary" (invisible, non-colliding region and
--     encounter boundaries),
--   * a void: the destination must have ground under it.
--
-- Characters and anything under a folder named "BMDynamic" (effects,
-- stand-ins) do not block. All geometry belongs to the server's view of the
-- world, so no client can change an answer.
--
-- Positions are character root heights. The hover above the ground is kept
-- through a move, so a lunge does not sink a character into the floor.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

local WorldQuery = {}

WorldQuery.BOUNDARY_TAG = "BM_Boundary"
WorldQuery.DYNAMIC_FOLDER = "BMDynamic"
-- Height of the chest ray above the root, and clearance kept from a hit.
local CHEST = 0
local CLEARANCE = 1.0
local GROUND_PROBE_UP = 6
local GROUND_PROBE_DOWN = 40
local SAMPLE_SPACING = 3
local MAX_HOVER = 8

local function toVector(v: Vec3.Vec3): Vector3
	return Vector3.new(v.x, v.y, v.z)
end

local function fromVector(v: Vector3): Vec3.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function params(): RaycastParams
	local excluded: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character ~= nil then
			table.insert(excluded, player.Character)
		end
	end
	local dynamic = Workspace:FindFirstChild(WorldQuery.DYNAMIC_FOLDER)
	if dynamic ~= nil then
		table.insert(excluded, dynamic)
	end
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = excluded
	p.RespectCanCollide = true
	return p
end

-- Distance along the segment to the first obstruction, or nil.
local function obstruction(from: Vector3, to: Vector3, p: RaycastParams): number?
	local direction = to - from
	local length = direction.Magnitude
	if length < 1e-3 then
		return nil
	end
	local nearest: number? = nil
	local hit = Workspace:Raycast(from, direction, p)
	if hit ~= nil then
		nearest = (hit.Position - from).Magnitude
	end
	-- Boundary volumes do not collide, so they are tested directly.
	local plain = RaycastParams.new()
	plain.FilterType = Enum.RaycastFilterType.Include
	for _, part in CollectionService:GetTagged(WorldQuery.BOUNDARY_TAG) do
		if part:IsA("BasePart") then
			plain.FilterDescendantsInstances = { part }
			local boundary = Workspace:Raycast(from, direction, plain)
			if boundary ~= nil then
				local distance = (boundary.Position - from).Magnitude
				if nearest == nil or distance < nearest then
					nearest = distance
				end
			end
		end
	end
	return nearest
end

local function groundY(x: number, y: number, z: number, p: RaycastParams): number?
	local hit = Workspace:Raycast(
		Vector3.new(x, y + GROUND_PROBE_UP, z),
		Vector3.new(0, -(GROUND_PROBE_UP + GROUND_PROBE_DOWN), 0),
		p
	)
	return if hit ~= nil then hit.Position.Y else nil
end

-- The farthest valid point on the path from `from` toward `to`; `from`
-- itself when nothing is reachable.
function WorldQuery.sweep(from: Vec3.Vec3, to: Vec3.Vec3): Vec3.Vec3
	local p = params()
	local start = toVector(from)
	local startGround = groundY(from.x, from.y, from.z, p)
	local hover = if startGround ~= nil then math.clamp(from.y - startGround, 0, MAX_HOVER) else 3
	local flatTo = Vector3.new(to.x, from.y, to.z)
	local path = flatTo - start
	local length = path.Magnitude
	if length < 1e-3 then
		return Vec3.copy(from)
	end
	local direction = path.Unit
	local allowed = length
	local blocked =
		obstruction(start + Vector3.new(0, CHEST, 0), flatTo + Vector3.new(0, CHEST, 0), p)
	if blocked ~= nil then
		allowed = math.max(0, blocked - CLEARANCE)
	end
	-- Ground must exist along the path; stop before the first void.
	local walked = 0
	local lastGround = startGround
	local point = start
	while walked < allowed do
		local nextWalk = math.min(allowed, walked + SAMPLE_SPACING)
		local sample = start + direction * nextWalk
		local ground = groundY(sample.X, sample.Y, sample.Z, p)
		if ground == nil then
			allowed = walked
			break
		end
		lastGround = ground
		point = sample
		walked = nextWalk
	end
	if walked < 1e-3 then
		return Vec3.copy(from)
	end
	local y = (lastGround or from.y - hover) + hover
	return fromVector(Vector3.new(point.X, y, point.Z))
end

-- Whether nothing solid lies between two points (chest height).
function WorldQuery.lineOfSight(from: Vec3.Vec3, to: Vec3.Vec3): boolean
	return obstruction(toVector(from), toVector(to), params()) == nil
end

return table.freeze(WorldQuery)
