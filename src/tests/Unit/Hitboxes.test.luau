--!strict
-- BM-055: hits exist only where the server finds them during active
-- frames; range spoofing, duplicate hits and obstructed attacks never
-- produce a hit.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Hitboxes = require(ServerScriptService.Server.Combat.Hitboxes)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Hitboxes")

type Setup = {
	sim: Simulation.Simulation,
	hitboxes: Hitboxes.Hitboxes,
	hits: { Hitboxes.Hit },
}

local function setup(env: Suite.Env, deps: Hitboxes.Deps?): Setup
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork("combat") })
	local hitboxes = Hitboxes.attach(sim, deps)
	local hits: { Hitboxes.Hit } = {}
	hitboxes:onHit(function(hit)
		table.insert(hits, hit)
	end)
	return { sim = sim, hitboxes = hitboxes, hits = hits }
end

local function attack(sim: Simulation.Simulation, id: string, sequence: number, target: string?)
	local outcome = sim:submit(id, { kind = "Attack", sequence = sequence, target = target })
	Assert.isTrue(outcome.ok, "attack accepted")
end

local function run(sim: Simulation.Simulation, steps: number)
	for _ = 1, steps do
		sim:step()
	end
end

local function pos(x: number, y: number, z: number)
	return { x = x, y = y, z = z }
end

suite:case(
	"an attack hits a target in front once per swing, on the first active frame",
	function(env)
		local s = setup(env)
		s.sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
		s.sim:addCombatant({ id = "b", team = "enemies", position = pos(0, 0, -3) })
		attack(s.sim, "a", 1)
		run(s.sim, 30)
		Assert.count(s.hits, 1, "one hit for four active frames")
		Assert.equal(s.hits[1].targetId, "b", "target")
		Assert.equal(s.hits[1].step, 7, "first active step")
		Assert.equal(s.hits[1].frame, 0, "first active frame")
		Assert.equal(s.hits[1].distance, 3, "distance recorded")
		Assert.equal(s.hitboxes:hitsThisSwing("a"), 0, "swing is over")
		local hitEvents = 0
		for _, event in s.sim:drainEvents() do
			if event.kind == "hit" then
				hitEvents += 1
			end
		end
		Assert.equal(hitEvents, 1, "recorded in the simulation log")

		attack(s.sim, "a", 2)
		run(s.sim, 30)
		Assert.count(s.hits, 2, "a new swing hits again")
		Assert.notEqual(s.hits[1].actionId, s.hits[2].actionId, "different swings")
	end
)

suite:case(
	"range, arc and height are checked on the server; the intent target proves nothing",
	function(env)
		local s = setup(env)
		s.sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
		s.sim:addCombatant({ id = "far", team = "enemies", position = pos(0, 0, -20) })
		s.sim:addCombatant({ id = "behind", team = "enemies", position = pos(0, 0, 3) })
		s.sim:addCombatant({ id = "above", team = "enemies", position = pos(0, 10, -3) })
		s.sim:addCombatant({ id = "side", team = "enemies", position = pos(3, 0, -1) }) -- ~72 degrees off
		attack(s.sim, "a", 1, "far")
		run(s.sim, 30)
		Assert.count(s.hits, 0, "no eligible target, whatever the client named")
		Assert.deepEqual(s.hitboxes:candidates("a"), {}, "no candidates")

		-- A target that steps into reach during the active frames is hit on
		-- the frame it arrives, not before.
		local far = s.sim:get("far") :: Simulation.Combatant
		attack(s.sim, "a", 2)
		run(s.sim, 8) -- step 38: active frame 1 (started at 31, active at 37)
		far.position = pos(0, 0, -5)
		run(s.sim, 1)
		Assert.count(s.hits, 1, "hit when in range")
		Assert.equal(s.hits[1].frame, 2, "on a later active frame")
		far.position = pos(0, 0, -20)
		run(s.sim, 30)
		Assert.count(s.hits, 1, "leaving again changes nothing")
	end
)

suite:case("collision filtering: self, team, dead, and a layer veto", function(env)
	local vetoed: { [string]: boolean } = {}
	local s = setup(env, {
		canHit = function(_, target)
			return not vetoed[target.id]
		end,
	})
	s.sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
	s.sim:addCombatant({ id = "ally", team = "players", position = pos(0, 0, -2) })
	s.sim:addCombatant({ id = "dead", team = "enemies", position = pos(1, 0, -2) })
	s.sim:addCombatant({ id = "ghost", team = "enemies", position = pos(-1, 0, -2) })
	s.sim:addCombatant({ id = "live", team = "enemies", position = pos(0, 0, -4) })
	s.sim:damage("dead", 10000)
	vetoed.ghost = true
	Assert.deepEqual(s.hitboxes:candidates("a"), { "live" }, "only the live hostile")
	attack(s.sim, "a", 1)
	run(s.sim, 30)
	Assert.count(s.hits, 1, "one hit")
	Assert.equal(s.hits[1].targetId, "live", "the live enemy")

	local ff = setup(env, { friendlyFire = true })
	ff.sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
	ff.sim:addCombatant({ id = "ally", team = "players", position = pos(0, 0, -2) })
	attack(ff.sim, "a", 1)
	run(ff.sim, 30)
	Assert.count(ff.hits, 1, "friendly fire when enabled")
end)

suite:case("an obstructed attack hits nothing", function(env)
	local blocked = true
	local s = setup(env, {
		lineOfSight = function()
			return not blocked
		end,
	})
	s.sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
	s.sim:addCombatant({ id = "b", team = "enemies", position = pos(0, 0, -3) })
	Assert.deepEqual(s.hitboxes:candidates("a"), {}, "wall in the way")
	attack(s.sim, "a", 1)
	run(s.sim, 30)
	Assert.count(s.hits, 0, "no hit through the wall")
	blocked = false
	Assert.deepEqual(s.hitboxes:candidates("a"), { "b" }, "clear")
	attack(s.sim, "a", 2)
	run(s.sim, 30)
	Assert.count(s.hits, 1, "hit once the wall is gone")
end)

suite:case("several targets in the arc are hit in id order within one frame", function(env)
	local s = setup(env)
	s.sim:addCombatant({
		id = "a",
		team = "players",
		position = pos(0, 0, 0),
		facing = pos(1, 0, 0),
	})
	s.sim:addCombatant({ id = "z", team = "enemies", position = pos(4, 0, 1) })
	s.sim:addCombatant({ id = "m", team = "enemies", position = pos(2, 1, -1) })
	attack(s.sim, "a", 1)
	run(s.sim, 30)
	Assert.count(s.hits, 2, "both hit")
	Assert.equal(s.hits[1].targetId, "m", "id order")
	Assert.equal(s.hits[2].targetId, "z", "id order")
	Assert.equal(s.hits[1].step, s.hits[2].step, "same frame")
end)

suite:case("actions without a shape never hit, and shapes are validated", function(env)
	local s = setup(env)
	s.sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
	s.sim:addCombatant({ id = "b", team = "enemies", position = pos(0, 0, -1) })
	Assert.isTrue(s.sim:submit("a", { kind = "Parry", sequence = 1 }).ok, "parry accepted")
	run(s.sim, 30)
	Assert.count(s.hits, 0, "a parry has no hitbox")
	Assert.throws(function()
		Hitboxes.attach(s.sim, { shapes = { Attack = { reach = 0, halfAngle = 60, height = 6 } } })
	end, "reach must be")
	Assert.throws(function()
		Hitboxes.attach(
			s.sim,
			{ shapes = { Attack = { reach = 500, halfAngle = 60, height = 6 } } }
		)
	end, "reach must be")
	Assert.throws(function()
		Hitboxes.attach(s.sim, { shapes = { Attack = { reach = 6, halfAngle = 181, height = 6 } } })
	end, "halfAngle must be")
	Assert.count(Hitboxes.validateShape(Hitboxes.DEFAULT_SHAPES.Attack), 0, "default valid")
end)

return suite:cases()
