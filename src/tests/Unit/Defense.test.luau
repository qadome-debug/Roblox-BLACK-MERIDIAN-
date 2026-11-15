--!strict
-- BM-057: perfect-window boundaries, guard economics and breaks, facing,
-- and animation desynchronization. Every outcome is decided by the
-- defender's server state at the step the hit resolves.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local ActionMachine = require(ServerScriptService.Server.Combat.ActionMachine)
local Assert = require(ServerStorage.Tests.Support.Assert)
local Damage = require(ServerScriptService.Server.Combat.Damage)
local Defense = require(ServerScriptService.Server.Combat.Defense)
local Hitboxes = require(ServerScriptService.Server.Combat.Hitboxes)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Defense")

type Setup = {
	sim: Simulation.Simulation,
	records: { Damage.Record },
	defense: Defense.Defense,
}

local function pos(x: number, y: number, z: number)
	return { x = x, y = y, z = z }
end

-- Attacker "a" at the origin facing -Z; defender "b" three studs ahead,
-- facing the attacker unless told otherwise.
local function setup(env: Suite.Env, defenderFacing: Vec3?): Setup
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork("combat") })
	local holder: { damage: Damage.Damage? } = {}
	local hitboxes = Hitboxes.attach(sim, {
		canHit = function(attacker, target)
			local d = holder.damage
			return d == nil or d.canHit(attacker, target)
		end,
	})
	local damage = Damage.attach(sim, hitboxes)
	holder.damage = damage
	local defense = Defense.attach(sim, damage)
	local records: { Damage.Record } = {}
	damage:onDamage(function(record)
		table.insert(records, record)
	end)
	sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0), facing = pos(0, 0, -1) })
	sim:addCombatant({
		id = "b",
		team = "enemies",
		position = pos(0, 0, -3),
		facing = defenderFacing or pos(0, 0, 1),
	})
	return { sim = sim, records = records, defense = defense }
end

type Vec3 = { x: number, y: number, z: number }

local function submit(
	sim: Simulation.Simulation,
	id: string,
	kind: ActionMachine.ActionKind,
	sequence: number
)
	Assert.isTrue(sim:submit(id, { kind = kind, sequence = sequence }).ok, kind .. " accepted")
end

local function run(sim: Simulation.Simulation, steps: number)
	for _ = 1, steps do
		sim:step()
	end
end

local function snap(sim: Simulation.Simulation, id: string): Simulation.Snapshot
	return sim:snapshot(id) :: Simulation.Snapshot
end

local function countEvents(sim: Simulation.Simulation, kind: string): number
	local n = 0
	for _, event in sim:drainEvents() do
		if event.kind == kind then
			n += 1
		end
	end
	return n
end

-- Attacks from "a" land on step 7 after submission at step 0. Submitting
-- the defender's parry at `parryStep` starts it the step after.
local function parryAt(env: Suite.Env, parryStep: number): (Setup, Damage.Record?)
	local s = setup(env)
	submit(s.sim, "a", "Attack", 1)
	run(s.sim, parryStep)
	submit(s.sim, "b", "Parry", 1)
	run(s.sim, 30 - parryStep)
	return s, s.records[1]
end

suite:case(
	"parry perfect window: the first and last active frames parry, one step either side does not",
	function(env)
		-- Parry: windup 2, active 5. Started at step s, active frames s+2..s+6.
		local early, hitEarly = parryAt(env, 0) -- starts 1, active 3..7: last frame
		Assert.equal((hitEarly :: Damage.Record).outcome, "Parried", "last active frame parries")
		Assert.equal(snap(early.sim, "b").health, 200, "no damage")
		Assert.equal(snap(early.sim, "a").posture, 50, "attacker lost posture")

		local _, hitLate = parryAt(env, 4) -- starts 5, active 7..11: first frame
		Assert.equal((hitLate :: Damage.Record).outcome, "Parried", "first active frame parries")

		local tooLate, hitTooLate = parryAt(env, 5) -- starts 6, windup 6..7
		Assert.equal((hitTooLate :: Damage.Record).outcome, "Damaged", "still in windup: hit lands")
		Assert.equal(snap(tooLate.sim, "b").health, 172.73, "full damage")
		Assert.equal(snap(tooLate.sim, "b").state, "Idle", "stun ended, parry was interrupted")
		Assert.equal(snap(tooLate.sim, "a").state, "Idle", "attacker untouched")
	end
)

suite:case("a successful parry staggers the attacker, who cannot act until it ends", function(env)
	local s, hit = parryAt(env, 4)
	Assert.equal((hit :: Damage.Record).outcome, "Parried", "parried")
	Assert.equal(countEvents(s.sim, "parried"), 1, "event")
	-- Attack landed at step 7 -> stagger 20 steps -> free at 27. We are at 30.
	Assert.equal(snap(s.sim, "a").state, "Idle", "stagger over by step 30")
	-- Re-run to inspect the stagger while it lasts.
	local s2 = setup(env)
	submit(s2.sim, "a", "Attack", 1)
	run(s2.sim, 4)
	submit(s2.sim, "b", "Parry", 1)
	run(s2.sim, 3) -- step 7: parried
	Assert.equal(snap(s2.sim, "a").state, "Staggered", "staggered")
	submit(s2.sim, "a", "Attack", 2)
	run(s2.sim, 1)
	local reason = ""
	for _, event in s2.sim:drainEvents() do
		if event.kind == "intent_rejected" and event.id == "a" then
			reason = (event.data :: any).reason
		end
	end
	Assert.equal(reason, "interrupted", "no actions while staggered")
	run(s2.sim, 19) -- step 27
	Assert.equal(snap(s2.sim, "a").state, "Idle", "free at step 27")
	Assert.equal(snap(s2.sim, "b").health, 200, "defender untouched")
end)

suite:case(
	"a parry that is already recovering is punished with full damage and interruption",
	function(env)
		local s = setup(env)
		submit(s.sim, "a", "Attack", 1) -- hit at 7
		run(s.sim, 24)
		submit(s.sim, "b", "Parry", 1) -- starts 25, active 27..31, recovery 32..43
		run(s.sim, 6) -- step 30
		submit(s.sim, "a", "Attack", 2) -- starts 31, hit at 37
		run(s.sim, 7)
		Assert.count(s.records, 2, "two hits")
		Assert.equal(s.records[2].outcome, "Damaged", "recovering parry does not parry")
		Assert.equal(s.records[2].amount, 27.27, "full damage")
		Assert.equal(snap(s.sim, "b").state, "Hit", "parry recovery interrupted")
		Assert.equal(snap(s.sim, "b").health, 145.46, "two full hits")
	end
)

suite:case(
	"guard: reduced damage, posture and stamina paid, guard kept; break at zero posture",
	function(env)
		local s = setup(env)
		submit(s.sim, "b", "Guard", 1) -- starts 1, held from 3
		submit(s.sim, "a", "Attack", 1) -- hit at 7
		run(s.sim, 7)
		Assert.count(s.records, 1, "one record")
		Assert.equal(s.records[1].outcome, "Guarded", "guarded")
		Assert.equal(s.records[1].amount, 5.45, "27.27 * 0.2")
		Assert.equal(s.records[1].posture, 15, "raw 30 * 0.5")
		Assert.equal(snap(s.sim, "b").posture, 65, "posture paid")
		Assert.equal(snap(s.sim, "b").stamina, 130, "stamina paid")
		Assert.equal(snap(s.sim, "b").state, "Guarding", "still guarding")
		Assert.equal(snap(s.sim, "b").phase, "Active", "still held")
		Assert.equal(countEvents(s.sim, "guarded"), 1, "event")

		local b = s.sim:get("b") :: Simulation.Combatant
		b.resources.posture = 10
		run(s.sim, 23) -- step 30
		submit(s.sim, "a", "Attack", 2) -- hit at 37
		run(s.sim, 7)
		Assert.count(s.records, 2, "second record")
		Assert.equal(s.records[2].outcome, "Guarded", "guard outcome")
		Assert.equal(s.records[2].amount, 27.27, "full damage on a break")
		Assert.equal(snap(s.sim, "b").posture, 0, "posture gone")
		Assert.isTrue(b.resources.postureBroken, "broken")
		Assert.equal(snap(s.sim, "b").state, "Staggered", "staggered")
		Assert.equal(countEvents(s.sim, "guard_broken"), 1, "event")
		run(s.sim, 24)
		Assert.equal(snap(s.sim, "b").state, "Idle", "stagger ends")
	end
)

suite:case("a guard without stamina breaks, and a guard from behind does nothing", function(env)
	local starved = setup(env)
	local b = starved.sim:get("b") :: Simulation.Combatant
	b.resources.stamina = 5
	b.resources.lastSpent.stamina = 0
	submit(starved.sim, "b", "Guard", 1)
	submit(starved.sim, "a", "Attack", 1)
	run(starved.sim, 7)
	Assert.equal(starved.records[1].amount, 27.27, "full damage")
	Assert.equal(snap(starved.sim, "b").state, "Staggered", "broken")
	Assert.equal(snap(starved.sim, "b").stamina, 5, "unaffordable cost not taken")

	local behind = setup(env, pos(0, 0, -1)) -- defender looks away
	submit(behind.sim, "b", "Guard", 1)
	submit(behind.sim, "a", "Attack", 1)
	run(behind.sim, 7)
	Assert.equal(behind.records[1].outcome, "Damaged", "guard ignored from behind")
	Assert.equal(snap(behind.sim, "b").state, "Hit", "interrupted")
	Assert.isFalse(
		behind.defense:facing(
			behind.sim:get("b") :: Simulation.Combatant,
			behind.sim:get("a") :: Simulation.Combatant
		),
		"not facing"
	)
end)

suite:case(
	"animation desynchronization: a dodge or parry one step late on the server is late",
	function(env)
		local s = setup(env)
		submit(s.sim, "a", "Attack", 1) -- hit at 7
		run(s.sim, 7)
		-- The client believes its dodge animation started in time; the
		-- server received the intent after step 7 resolved, so it is late.
		Assert.count(s.records, 1, "hit landed")
		Assert.equal(s.records[1].outcome, "Damaged", "late dodge")
		submit(s.sim, "b", "Dodge", 1)
		run(s.sim, 1)
		Assert.equal(snap(s.sim, "b").state, "Hit", "stunned, dodge rejected")

		local early = setup(env)
		submit(early.sim, "a", "Attack", 1)
		run(early.sim, 6)
		submit(early.sim, "b", "Dodge", 1) -- received before step 7: in effect for the hit at 7
		run(early.sim, 25)
		Assert.count(early.records, 0, "dodge in time")
	end
)

suite:case("tuning is validated", function()
	Assert.count(Defense.validateTuning(Defense.DEFAULT_TUNING), 0, "defaults valid")
	local bad = table.clone(Defense.DEFAULT_TUNING)
	bad.guardDamageFactor = 1.5
	Assert.contains(
		table.concat(Defense.validateTuning(bad), ";"),
		"guardDamageFactor",
		"factor range"
	)
	bad = table.clone(Defense.DEFAULT_TUNING)
	bad.parryStaggerSteps = 2.5
	Assert.contains(
		table.concat(Defense.validateTuning(bad), ";"),
		"parryStaggerSteps",
		"whole steps"
	)
end)

return suite:cases()
