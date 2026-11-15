--!strict
-- BM-059: lock-on targets are granted and kept only by the server;
-- invalid and distant targets are refused, locks drop on death, range
-- and sight loss, and engagement follows server-resolved damage.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Damage = require(ServerScriptService.Server.Combat.Damage)
local Hitboxes = require(ServerScriptService.Server.Combat.Hitboxes)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Targeting = require(ServerScriptService.Server.Combat.Targeting)

local suite = Suite.new("Targeting")

type Vec3 = { x: number, y: number, z: number }

type World = {
	sim: Simulation.Simulation,
	targeting: Targeting.Targeting,
	tick: (steps: number) -> (),
	events: (kind: string) -> { Simulation.Event },
}

local function pos(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

local function world(env: Suite.Env, deps: Targeting.Deps?): World
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork("combat") })
	local hitboxes = Hitboxes.attach(sim)
	local damage = Damage.attach(sim, hitboxes)
	local options: Targeting.Deps = deps or {}
	options.damage = damage
	local targeting = Targeting.attach(sim, options)
	local w = {} :: World
	w.sim = sim
	w.targeting = targeting
	w.tick = function(steps: number)
		for _ = 1, steps do
			sim:step()
			targeting:tick()
		end
	end
	w.events = function(kind: string): { Simulation.Event }
		local out = {}
		for _, event in sim:drainEvents() do
			if event.kind == kind then
				table.insert(out, event)
			end
		end
		return out
	end
	return w
end

local function refused(outcome: { ok: boolean, reason: string? }, needle: string)
	Assert.isFalse(outcome.ok, "refused: " .. needle)
	Assert.contains(outcome.reason :: string, needle, needle)
end

suite:case("invalid targets are refused and the lock stays as it was", function(env)
	local w = world(env)
	w.sim:addCombatant({ id = "p", team = "players", position = pos(0, 0, 0) })
	w.sim:addCombatant({ id = "ally", team = "players", position = pos(1, 0, 0) })
	w.sim:addCombatant({ id = "e", team = "enemies", position = pos(0, 0, -5) })
	w.sim:addCombatant({ id = "corpse", team = "enemies", position = pos(0, 0, -6) })
	w.sim:damage("corpse", 10000)
	refused(w.targeting:request("ghost", "e") :: any, "unknown combatant")
	refused(w.targeting:request("p", "nobody") :: any, "unknown target")
	refused(w.targeting:request("p", "p") :: any, "cannot target yourself")
	refused(w.targeting:request("p", "ally") :: any, "cannot target an ally")
	refused(w.targeting:request("p", "corpse") :: any, "target is dead")
	refused(w.targeting:request("p", "") :: any, "invalid target id")
	Assert.isNil(w.targeting:target("p"), "no lock from refused requests")
	Assert.isTrue(w.targeting:request("p", "e").ok, "valid")
	Assert.equal(w.targeting:target("p"), "e", "locked")
	refused(w.targeting:request("p", "ally") :: any, "cannot target an ally")
	Assert.equal(w.targeting:target("p"), "e", "still locked on the valid one")
	Assert.count(w.events("target_acquired"), 1, "one acquisition")
	Assert.isTrue(w.targeting:request("p", nil).ok, "clear")
	Assert.isNil(w.targeting:target("p"), "cleared")
	Assert.equal((w.events("target_lost")[1].data :: any).reason, "cleared", "logged")
	w.sim:damage("p", 10000)
	refused(w.targeting:request("p", "e") :: any, "dead")
end)

suite:case(
	"distant targeting: out of range or out of sight is refused, and a held lock drops after the grace period",
	function(env)
		local visible = true
		local w = world(env, {
			lineOfSight = function()
				return visible
			end,
			rules = { maxLockRange = 20, loseSteps = 10, engageSteps = 50 },
		})
		w.sim:addCombatant({ id = "p", team = "players", position = pos(0, 0, 0) })
		local e = w.sim:addCombatant({ id = "e", team = "enemies", position = pos(0, 0, -25) })
		refused(w.targeting:request("p", "e") :: any, "target out of range")
		e.position = pos(0, 0, -15)
		visible = false
		refused(w.targeting:request("p", "e") :: any, "target not in sight")
		visible = true
		Assert.isTrue(w.targeting:request("p", "e").ok, "in range and in sight")

		e.position = pos(0, 0, -30)
		w.tick(9)
		Assert.equal(w.targeting:target("p"), "e", "kept during the grace period")
		e.position = pos(0, 0, -15)
		w.tick(1)
		Assert.isNil(
			(w.targeting:lock("p") :: Targeting.Lock).lostSince,
			"back in range resets the grace period"
		)
		e.position = pos(0, 0, -30)
		w.tick(10)
		Assert.isNil(w.targeting:target("p"), "dropped after ten steps out of range")
		Assert.equal(
			(w.events("target_lost")[1].data :: any).reason,
			"target out of range",
			"reason"
		)

		e.position = pos(0, 0, -15)
		Assert.isTrue(w.targeting:request("p", "e").ok, "re-lock")
		visible = false
		w.tick(10)
		Assert.isNil(w.targeting:target("p"), "dropped after losing sight")
	end
)

suite:case("locks drop when either side dies or leaves", function(env)
	local w = world(env)
	w.sim:addCombatant({ id = "p", team = "players", position = pos(0, 0, 0) })
	w.sim:addCombatant({ id = "e", team = "enemies", position = pos(0, 0, -5) })
	w.sim:addCombatant({ id = "f", team = "enemies", position = pos(0, 0, -6) })
	Assert.isTrue(w.targeting:request("p", "e").ok, "lock e")
	w.sim:damage("e", 10000)
	w.tick(1)
	Assert.isNil(w.targeting:target("p"), "target died")
	Assert.isTrue(w.targeting:request("p", "f").ok, "lock f")
	w.sim:removeCombatant("f")
	w.tick(1)
	Assert.isNil(w.targeting:target("p"), "target removed")
	w.sim:addCombatant({ id = "g", team = "enemies", position = pos(0, 0, -6) })
	Assert.isTrue(w.targeting:request("p", "g").ok, "lock g")
	w.sim:damage("p", 10000)
	w.tick(1)
	Assert.isNil(w.targeting:target("p"), "the dead hold no lock")
end)

suite:case("cycling walks eligible targets nearest-first and wraps", function(env)
	local w = world(env)
	w.sim:addCombatant({ id = "p", team = "players", position = pos(0, 0, 0) })
	w.sim:addCombatant({ id = "far", team = "enemies", position = pos(0, 0, -12) })
	w.sim:addCombatant({ id = "near", team = "enemies", position = pos(0, 0, -3) })
	w.sim:addCombatant({ id = "mid", team = "enemies", position = pos(0, 0, -7) })
	w.sim:addCombatant({ id = "gone", team = "enemies", position = pos(0, 0, -99) })
	Assert.deepEqual(
		w.targeting:candidates("p"),
		{ "near", "mid", "far" },
		"sorted by distance, out of range excluded"
	)
	Assert.isTrue(w.targeting:cycle("p").ok, "first")
	Assert.equal(w.targeting:target("p"), "near", "nearest first")
	w.targeting:cycle("p")
	Assert.equal(w.targeting:target("p"), "mid", "then next")
	w.targeting:cycle("p")
	Assert.equal(w.targeting:target("p"), "far", "then the farthest")
	w.targeting:cycle("p")
	Assert.equal(w.targeting:target("p"), "near", "wraps")
	Assert.count(w.events("target_lost"), 3, "each switch logs a loss with reason switched")
	for _, id in { "near", "mid", "far" } do
		w.sim:damage(id, 10000)
	end
	w.tick(1)
	refused(w.targeting:cycle("p") :: any, "no eligible target")
end)

suite:case("engagement follows server-resolved damage and times out", function(env)
	local w = world(env, { rules = { maxLockRange = 40, loseSteps = 60, engageSteps = 20 } })
	w.sim:addCombatant({ id = "p", team = "players", position = pos(0, 0, 0) })
	w.sim:addCombatant({ id = "e", team = "enemies", position = pos(0, 0, -3) })
	w.sim:addCombatant({ id = "bystander", team = "players", position = pos(30, 0, 0) })
	Assert.isFalse(w.targeting:engaged("p"), "peaceful")
	Assert.isTrue(w.sim:submit("p", { kind = "Attack", sequence = 1 }).ok, "attack")
	w.tick(7)
	Assert.isTrue(w.targeting:engaged("p"), "attacker engaged")
	Assert.isTrue(w.targeting:engaged("e"), "victim engaged")
	Assert.isFalse(w.targeting:engaged("bystander"), "bystander not engaged")
	w.tick(19)
	Assert.isTrue(w.targeting:engaged("p"), "still engaged just inside the timeout")
	w.tick(1)
	Assert.isFalse(w.targeting:engaged("p"), "timed out")
	Assert.isFalse(w.targeting:engaged("e"), "timed out")

	Assert.isTrue(w.targeting:request("p", "e").ok, "lock")
	Assert.isTrue(w.targeting:engaged("p"), "a lock engages")
	w.targeting:request("p", nil)
	Assert.isFalse(w.targeting:engaged("p"), "cleared lock, no recent damage")
	w.targeting:engage("bystander")
	Assert.isTrue(w.targeting:engaged("bystander"), "explicit engagement")
	w.targeting:engage("nobody")
	Assert.isFalse(w.targeting:engaged("nobody"), "unknown ids are ignored")
end)

suite:case("rules are validated", function(env)
	Assert.count(Targeting.validateRules(Targeting.DEFAULT_RULES), 0, "defaults")
	Assert.throws(function()
		world(env, { rules = { maxLockRange = 0, loseSteps = 1, engageSteps = 1 } })
	end, "maxLockRange")
	Assert.throws(function()
		world(env, { rules = { maxLockRange = 10, loseSteps = 1.5, engageSteps = 1 } })
	end, "loseSteps")
end)

return suite:cases()
