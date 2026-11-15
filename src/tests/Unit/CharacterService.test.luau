--!strict
-- BM-051: respawn, teleport and movement-state transitions; positions
-- come from the server-side rig and implausible jumps are not trusted.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local CharacterService = require(ServerScriptService.Server.Services.CharacterService)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

local suite = Suite.new("CharacterService")

type FakeRig = {
	rig: CharacterService.Rig,
	pos: { value: CharacterService.Vec3? },
	state: { value: CharacterService.MoveState },
	teleports: { CharacterService.Vec3 },
}

local function fakeRig(x: number, y: number, z: number): FakeRig
	local pos = { value = Vec3.new(x, y, z) :: CharacterService.Vec3? }
	local state = { value = "Idle" :: CharacterService.MoveState }
	local teleports = {}
	local rig: CharacterService.Rig = {
		position = function()
			return pos.value
		end,
		moveState = function()
			return state.value
		end,
		teleport = function(to)
			table.insert(teleports, to)
			pos.value = Vec3.copy(to)
		end,
	}
	return { rig = rig, pos = pos, state = state, teleports = teleports }
end

local function make(env: Suite.Env)
	return CharacterService.new({
		clock = env.clock,
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		maxSpeed = 100,
	})
end

suite:case("lifecycle: none -> alive -> dead -> none", function(env)
	local service = make(env)
	Assert.equal(service:lifeState(1), "None", "none before spawn")
	Assert.isNil(service:sample(1), "no sample without a character")
	local f = fakeRig(0, 5, 0)
	service:onCharacterAdded(1, f.rig)
	Assert.equal(service:lifeState(1), "Alive", "alive")
	Assert.equal(service:count(), 1, "tracked")
	service:onDied(1)
	Assert.equal(service:lifeState(1), "Dead", "dead")
	Assert.isNil(service:sample(1), "dead characters have no authoritative position")
	Assert.isFalse(service:teleport(1, Vec3.new(1, 1, 1)), "cannot teleport the dead")
	service:onCharacterRemoving(1)
	Assert.equal(service:lifeState(1), "None", "removed")
	Assert.equal(service:count(), 0, "untracked")
	-- Respawn starts a fresh entry.
	service:onCharacterAdded(1, fakeRig(10, 5, 10).rig)
	Assert.equal(service:lifeState(1), "Alive", "respawned")
	Assert.equal((service:sample(1) :: any).position.x, 10, "new position")
end)

suite:case(
	"samples come from the rig, are cached per interval, and drive range checks",
	function(env)
		local service = make(env)
		local f = fakeRig(0, 0, 0)
		service:onCharacterAdded(1, f.rig)
		Assert.isTrue(
			service:isWithin(1, Vec3.new(3, 50, 4), 5.01),
			"within 5 studs horizontally (y ignored)"
		)
		Assert.isFalse(service:isWithin(1, Vec3.new(3, 0, 4), 4.99), "just outside")
		f.pos.value = Vec3.new(1, 0, 0)
		Assert.equal((service:sample(1) :: any).position.x, 0, "cached within the sample interval")
		env.clock:advance(1)
		Assert.equal((service:sample(1) :: any).position.x, 1, "fresh after the interval")
		f.state.value = "Airborne"
		env.clock:advance(1)
		Assert.equal((service:sample(1) :: any).moveState, "Airborne", "move state sampled")
	end
)

suite:case(
	"an implausible jump is flagged and the last plausible position stays authoritative",
	function(env)
		local service = make(env)
		local f = fakeRig(0, 0, 0)
		service:onCharacterAdded(1, f.rig)
		env.clock:advance(1)
		f.pos.value = Vec3.new(1000, 0, 0) -- 1000 studs in one second
		local snapshot = service:sample(1) :: CharacterService.Snapshot
		Assert.isTrue(snapshot.suspicious, "flagged")
		Assert.equal(snapshot.position.x, 0, "old position kept")
		Assert.isFalse(
			service:isWithin(1, Vec3.new(1000, 0, 0), 5),
			"range checks use the authoritative position"
		)
		Assert.count(env.logged("gameplay", "character_implausible_move"), 1, "logged")
		Assert.count(env.logged("telemetry", "character_implausible_move"), 1, "counted")

		-- A plausible move afterwards is accepted again.
		env.clock:advance(1)
		f.pos.value = Vec3.new(50, 0, 0)
		local next = service:sample(1) :: CharacterService.Snapshot
		Assert.isFalse(next.suspicious, "plausible again")
		Assert.equal(next.position.x, 50, "accepted")
	end
)

suite:case("server teleports move the rig and reset plausibility", function(env)
	local service = make(env)
	local f = fakeRig(0, 0, 0)
	service:onCharacterAdded(1, f.rig)
	Assert.isTrue(service:teleport(1, Vec3.new(5000, 10, 0)), "teleported")
	Assert.count(f.teleports, 1, "rig moved by the server")
	Assert.equal(
		(service:sample(1) :: any).position.x,
		5000,
		"authoritative position updated without a flag"
	)
	Assert.isFalse(
		service:teleport(1, { x = 0 / 0, y = 0, z = 0 } :: any),
		"non-finite target refused"
	)
	Assert.isFalse(service:teleport(9, Vec3.new(0, 0, 0)), "unknown player refused")
end)

suite:case("unreadable positions keep the last known one", function(env)
	local service = make(env)
	local f = fakeRig(2, 0, 2)
	service:onCharacterAdded(1, f.rig)
	env.clock:advance(1)
	f.pos.value = nil
	Assert.equal((service:sample(1) :: any).position.x, 2, "last known kept")
	local g = fakeRig(0, 0, 0)
	g.pos.value = nil
	service:onCharacterAdded(2, g.rig)
	Assert.isNil(service:sample(2), "no position ever read")
	Assert.isNil(service:distanceTo(2, Vec3.new(0, 0, 0)), "no distance")
end)

return suite:cases()
