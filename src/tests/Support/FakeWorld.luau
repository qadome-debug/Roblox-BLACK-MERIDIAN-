--!strict
-- A flat, deterministic stand-in for the Roblox world, for headless tests.
--
-- Solid boxes (walls, locked doors, encounter boundaries) block movement;
-- a void (no ground) stops it; a height function gives ground height. The
-- same contract as Services/WorldQuery.sweep: the farthest valid point on
-- the path, `from` itself when nothing is reachable.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

export type Box = { minX: number, maxX: number, minZ: number, maxZ: number }

export type Options = {
	walls: { Box }?,
	-- Ground height at a point; nil means void. Default: flat at 0.
	heightAt: ((x: number, z: number) -> number?)?,
}

local FakeWorld = {}

local SPACING = 0.25
local CLEARANCE = 0.5
-- Highest ledge a single sample may climb.
local MAX_STEP_UP = 1.5

function FakeWorld.new(options: Options?)
	local walls: { Box } = if options ~= nil and options.walls ~= nil then options.walls else {}
	local heightAt: (x: number, z: number) -> number? = if options ~= nil
			and options.heightAt ~= nil
		then options.heightAt
		else function(_x: number, _z: number): number?
			return 0
		end

	local function inWall(x: number, z: number): boolean
		for _, wall in walls do
			if x >= wall.minX and x <= wall.maxX and z >= wall.minZ and z <= wall.maxZ then
				return true
			end
		end
		return false
	end

	local world = {}

	function world.sweep(from: Vec3.Vec3, to: Vec3.Vec3): Vec3.Vec3
		local startGround = heightAt(from.x, from.z) or 0
		local hover = from.y - startGround
		local dx, dz = to.x - from.x, to.z - from.z
		local length = math.sqrt(dx * dx + dz * dz)
		if length < 1e-6 then
			return Vec3.copy(from)
		end
		local ux, uz = dx / length, dz / length
		local walked = 0
		local lastGround = startGround
		local last = 0
		while walked < length do
			local nextWalk = math.min(length, walked + SPACING)
			local x, z = from.x + ux * nextWalk, from.z + uz * nextWalk
			-- Keep a margin from solids: test a point slightly ahead too.
			local ahead = nextWalk + CLEARANCE
			local ax, az = from.x + ux * ahead, from.z + uz * ahead
			if inWall(x, z) or inWall(ax, az) then
				break
			end
			local ground = heightAt(x, z)
			if ground == nil or ground - lastGround > MAX_STEP_UP then
				break
			end
			lastGround = ground
			last = nextWalk
			walked = nextWalk
		end
		if last < 1e-6 then
			return Vec3.copy(from)
		end
		return { x = from.x + ux * last, y = lastGround + hover, z = from.z + uz * last }
	end

	function world.lineOfSight(from: Vec3.Vec3, to: Vec3.Vec3): boolean
		local dx, dz = to.x - from.x, to.z - from.z
		local length = math.sqrt(dx * dx + dz * dz)
		local steps = math.max(1, math.floor(length / SPACING))
		for i = 1, steps do
			local t = i / steps
			if inWall(from.x + dx * t, from.z + dz * t) then
				return false
			end
		end
		return true
	end

	return world
end

return table.freeze(FakeWorld)
