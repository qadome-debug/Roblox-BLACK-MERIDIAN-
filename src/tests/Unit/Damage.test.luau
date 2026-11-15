--!strict
-- BM-056: damage boundaries, invulnerability windows, repeated-hit
-- exploits and death. Health only ever changes on the server.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local ActionMachine = require(ServerScriptService.Server.Combat.ActionMachine)
local Assert = require(ServerStorage.Tests.Support.Assert)
local Attributes = require(ServerScriptService.Server.Combat.Attributes)
local Damage = require(ServerScriptService.Server.Combat.Damage)
local Hitboxes = require(ServerScriptService.Server.Combat.Hitboxes)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Damage")

type Setup = {
	sim: Simulation.Simulation,
	hitboxes: Hitboxes.Hitboxes,
	damage: Damage.Damage,
	records: { Damage.Record },
}

local function setup(env: Suite.Env, deps: Damage.Deps?): Setup
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork("combat") })
	-- Composition order used by the real server: damage supplies the
	-- invulnerability veto to the hitbox pass.
	local holder: { damage: Damage.Damage? } = {}
	local hitboxes = Hitboxes.attach(sim, {
		canHit = function(attacker, target)
			local d = holder.damage
			return d == nil or d.canHit(attacker, target)
		end,
	})
	local damage = Damage.attach(sim, hitboxes, deps)
	holder.damage = damage
	local records: { Damage.Record } = {}
	damage:onDamage(function(record)
		table.insert(records, record)
	end)
	return { sim = sim, hitboxes = hitboxes, damage = damage, records = records }
end

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

local function pos(x: number, y: number, z: number)
	return { x = x, y = y, z = z }
end

local function snap(sim: Simulation.Simulation, id: string): Simulation.Snapshot
	return sim:snapshot(id) :: Simulation.Snapshot
end

suite:case("damage arithmetic is bounded and deterministic", function()
	Assert.equal(Damage.raw(30, 1), 30, "raw")
	Assert.equal(Damage.raw(30, 1.5), 45, "scaled")
	Assert.equal(Damage.raw(-1, 1), 0, "negative power")
	Assert.equal(Damage.raw(30, 0 / 0), 0, "NaN scale")
	Assert.equal(Damage.mitigate(30, 10), 27.27, "10 defense")
	Assert.equal(Damage.mitigate(30, 100), 15, "100 defense halves")
	Assert.equal(Damage.mitigate(30, -50), 30, "negative defense ignored")
	Assert.equal(Damage.mitigate(30, 1e9), 0, "huge defense still never negative")
	Assert.equal(Damage.mitigate(0, 10), 0, "zero raw")
	Assert.equal(Damage.clamp(5000, 5000), 1000, "per-hit cap")
	Assert.equal(Damage.clamp(50, 30), 30, "never above raw")
	Assert.equal(Damage.clamp(-5, 30), 0, "never negative")
	Assert.equal(Damage.clamp(0 / 0, 30), 0, "NaN")
	Assert.equal(Damage.clamp(12.345, 30), 12.35, "rounded to 1/100")
end)

suite:case("a landed hit lowers health by the mitigated amount and stuns the target", function(env)
	local s = setup(env)
	s.sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
	s.sim:addCombatant({ id = "b", team = "enemies", position = pos(0, 0, -3) })
	submit(s.sim, "a", "Attack", 1)
	run(s.sim, 7) -- first active frame
	Assert.count(s.records, 1, "one record")
	Assert.equal(s.records[1].outcome, "Damaged", "damaged")
	Assert.equal(s.records[1].amount, 27.27, "30 attack power into 10 defense")
	Assert.equal(snap(s.sim, "b").health, 172.73, "health lowered on the server")
	Assert.equal(snap(s.sim, "b").state, "Hit", "stunned")
	Assert.isTrue(s.sim:submit("b", { kind = "Attack", sequence = 1 }).ok, "intent queues")
	run(s.sim, 1)
	local rejected = false
	for _, event in s.sim:drainEvents() do
		if event.kind == "intent_rejected" and event.id == "b" then
			rejected = (event.data :: any).reason == "interrupted"
		end
	end
	Assert.isTrue(rejected, "no actions while stunned")
	run(s.sim, 5)
	Assert.equal(snap(s.sim, "b").state, "Idle", "stun ends after six steps")
	run(s.sim, 30)
	Assert.count(s.records, 1, "the same swing never hits twice")
end)

suite:case("dodge active frames are invulnerable; recovery frames are not", function(env)
	local s = setup(env)
	s.sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
	s.sim:addCombatant({ id = "b", team = "enemies", position = pos(0, 0, -3) })
	submit(s.sim, "a", "Attack", 1) -- active steps 7..10
	run(s.sim, 5)
	submit(s.sim, "b", "Dodge", 1) -- starts step 6, active 6..13
	run(s.sim, 25)
	Assert.count(s.records, 0, "no hit at all during i-frames")
	Assert.equal(snap(s.sim, "b").health, 200, "untouched")

	s.sim:drainEvents()
	submit(s.sim, "a", "Attack", 2) -- starts 31, active 37..40
	submit(s.sim, "b", "Dodge", 2) -- starts 31, active 31..38, recovery 39..44
	run(s.sim, 8) -- step 38: still invulnerable
	Assert.count(s.records, 0, "frame 37 and 38 invulnerable")
	-- Step 39: b leaves its active frames when b is processed, which is
	-- after a (id order), so a sees the change on the next step.
	run(s.sim, 1)
	Assert.count(s.records, 0, "phase change visible to others from the next step")
	run(s.sim, 1) -- step 40
	Assert.count(s.records, 1, "hit on the first vulnerable frame of the same swing")
	Assert.equal(s.records[1].hit.frame, 3, "last active frame")
	Assert.isTrue(
		s.damage:isInvulnerable(s.sim:get("b") :: Simulation.Combatant) == false,
		"not invulnerable now"
	)
end)

suite:case(
	"repeated-hit exploits: long active windows, inflated power and hooks cannot exceed the caps",
	function(env)
		local s = setup(env)
		local actions = table.clone(ActionMachine.DEFAULT_ACTIONS)
		actions.Attack = {
			kind = "Attack",
			windup = 1,
			active = 200,
			recovery = 1,
			cost = nil,
			cancelInto = {},
			cancelFromRecoveryFrame = math.huge,
		}
		s.sim:addCombatant({
			id = "a",
			team = "players",
			position = pos(0, 0, 0),
			actions = actions,
			modifiers = {
				{ id = "cheat", stat = "attackPower", add = 1000 },
				{ id = "cheat2", stat = "attackPower", mul = 5 },
			} :: { Attributes.Modifier },
		})
		s.sim:addCombatant({
			id = "b",
			team = "enemies",
			position = pos(0, 0, -3),
			base = { vigor = 99, might = 10, grace = 10, will = 10 },
		})
		s.damage:onBeforeDamage(function(context)
			context.amount = 99999
		end)
		submit(s.sim, "a", "Attack", 1)
		run(s.sim, 150)
		Assert.count(s.records, 1, "200 active frames, one hit")
		Assert.equal(
			s.records[1].amount,
			1000,
			"attack power capped at 1000, hook clamped to raw and the per-hit cap"
		)
		Assert.equal(snap(s.sim, "b").health, 1090 - 1000, "server health")
	end
)

suite:case("hooks may lower damage; a negated hit does not stun", function(env)
	local s = setup(env)
	s.sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
	s.sim:addCombatant({ id = "b", team = "enemies", position = pos(0, 0, -3) })
	s.damage:onBeforeDamage(function(context)
		context.amount = 0
		context.posture = 15
	end)
	submit(s.sim, "a", "Attack", 1)
	run(s.sim, 7)
	Assert.count(s.records, 1, "recorded")
	Assert.equal(s.records[1].outcome, "Negated", "negated")
	Assert.equal(s.records[1].posture, 15, "posture taken instead")
	Assert.equal(snap(s.sim, "b").posture, 65, "posture lowered")
	Assert.equal(snap(s.sim, "b").health, 200, "health untouched")
	Assert.equal(snap(s.sim, "b").state, "Idle", "not stunned")
end)

suite:case("a lethal hit kills, and the dead are never hit again", function(env)
	local s = setup(env)
	s.sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
	local b = s.sim:addCombatant({ id = "b", team = "enemies", position = pos(0, 0, -3) })
	b.resources.health = 5
	submit(s.sim, "a", "Attack", 1)
	run(s.sim, 7)
	Assert.count(s.records, 1, "one record")
	Assert.isTrue(s.records[1].killed, "killed")
	Assert.equal(s.records[1].amount, 5, "only the remaining health")
	Assert.equal(snap(s.sim, "b").state, "Dead", "dead")
	local died, interrupted = 0, 0
	for _, event in s.sim:drainEvents() do
		if event.kind == "died" then
			died += 1
		elseif event.kind == "interrupted" then
			interrupted += 1
		end
	end
	Assert.equal(died, 1, "died once")
	Assert.equal(interrupted, 0, "no stun on a corpse")
	run(s.sim, 30)
	submit(s.sim, "a", "Attack", 2)
	run(s.sim, 30)
	Assert.count(s.records, 1, "the dead are not targets")
end)

suite:case("the first hit interrupts the other side's swing", function(env)
	local s = setup(env)
	s.sim:addCombatant({
		id = "a",
		team = "players",
		position = pos(0, 0, 0),
		facing = pos(0, 0, -1),
	})
	s.sim:addCombatant({
		id = "b",
		team = "enemies",
		position = pos(0, 0, -3),
		facing = pos(0, 0, 1),
	})
	submit(s.sim, "a", "Attack", 1)
	submit(s.sim, "b", "Attack", 1)
	run(s.sim, 30)
	Assert.count(s.records, 1, "only one hit landed")
	Assert.equal(s.records[1].hit.attackerId, "a", "a resolved first in id order")
	Assert.equal(snap(s.sim, "a").health, 200, "b's swing was interrupted before its active frames")
	Assert.equal(snap(s.sim, "b").health, 172.73, "b took the hit")
end)

return suite:cases()
