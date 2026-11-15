--!strict
-- BM-058: enemies aggro, chase, attack on a schedule, give up on lost
-- targets, path failures and leashes, and reset at home. They act only
-- through the simulation's intent API; nothing here reads a client.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local ActionMachine = require(ServerScriptService.Server.Combat.ActionMachine)
local Ai = require(ServerScriptService.Server.Combat.Ai)
local Assert = require(ServerStorage.Tests.Support.Assert)
local Damage = require(ServerScriptService.Server.Combat.Damage)
local Hitboxes = require(ServerScriptService.Server.Combat.Hitboxes)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Ai")

type Vec3 = { x: number, y: number, z: number }

type World = {
	sim: Simulation.Simulation,
	ai: Ai.Ai,
	records: { Damage.Record },
	tick: (steps: number) -> (),
	events: (kind: string) -> number,
}

local function pos(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

local function world(env: Suite.Env, navigator: Ai.Navigator?, seed: string?): World
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork(seed or "combat") })
	local holder: { damage: Damage.Damage? } = {}
	local hitboxes = Hitboxes.attach(sim, {
		canHit = function(attacker, target)
			local d = holder.damage
			return d == nil or d.canHit(attacker, target)
		end,
	})
	local damage = Damage.attach(sim, hitboxes)
	holder.damage = damage
	local records: { Damage.Record } = {}
	damage:onDamage(function(record)
		table.insert(records, record)
	end)
	local ai = Ai.attach(sim, { logger = env.logger, navigator = navigator, damage = damage })
	local w = {} :: World
	w.sim = sim
	w.ai = ai
	w.records = records
	w.tick = function(steps: number)
		for _ = 1, steps do
			sim:step()
			ai:tick()
		end
	end
	w.events = function(kind: string): number
		local n = 0
		for _, event in sim:drainEvents() do
			if event.kind == kind then
				n += 1
			end
		end
		return n
	end
	return w
end

local function brain(w: World, id: string): Ai.Brain
	return w.ai:brain(id) :: Ai.Brain
end

local function combatant(w: World, id: string): Simulation.Combatant
	return w.sim:get(id) :: Simulation.Combatant
end

suite:case(
	"an enemy aggros, closes in at its own speed, and attacks without any client input",
	function(env)
		local w = world(env)
		w.sim:addCombatant({ id = "p", team = "players", position = pos(0, 0, -12) })
		w.sim:addCombatant({ id = "e", team = "enemies", position = pos(0, 0, 0) })
		w.ai:adopt("e")
		Assert.equal(brain(w, "e").state, "Idle", "idle at first")
		w.tick(1)
		Assert.equal(brain(w, "e").state, "Chase", "aggro")
		Assert.equal(brain(w, "e").targetId, "p", "targets the player")
		Assert.equal(w.events("ai_aggro"), 1, "aggro logged")
		-- Move speed 16.5 studs/s at 30 steps/s = 0.55 studs per step. The
		-- enemy needs to cover 7 studs to enter the 5-stud attack range.
		w.tick(12)
		Assert.equal(brain(w, "e").state, "Chase", "still closing")
		w.tick(2)
		Assert.equal(brain(w, "e").state, "Attack", "in range")
		local e = combatant(w, "e")
		Assert.isTrue(
			e.position.z < -6.5 and e.position.z > -7.5,
			"moved toward the player, not teleported"
		)
		Assert.isTrue(e.facing.z < -0.99, "facing the player")
		w.tick(30)
		Assert.isTrue(#w.records >= 1, "the player was hit")
		Assert.equal(w.records[1].hit.attackerId, "e", "by the enemy")
		Assert.equal(w.records[1].hit.targetId, "p", "the player")
		Assert.equal(w.ai:lootOwner("e"), nil, "no damage dealt to the enemy yet")
	end
)

suite:case("attacks are scheduled with a cooldown and never while out of range", function(env)
	local w = world(env)
	w.sim:addCombatant({
		id = "p",
		team = "players",
		position = pos(0, 0, -3),
		base = { vigor = 99, might = 10, grace = 10, will = 10 },
	})
	w.sim:addCombatant({ id = "e", team = "enemies", position = pos(0, 0, 0) })
	w.ai:adopt("e", {
		aggroRange = 20,
		attackRange = 5,
		leashRange = 40,
		maxPathFailures = 3,
		attackCooldownSteps = 30,
		attackJitterSteps = 0,
		repathSteps = 10,
	})
	w.tick(300)
	local started = 0
	for _, event in w.sim:drainEvents() do
		if event.kind == "action_started" and event.id == "e" then
			started += 1
		end
	end
	-- A swing takes 20 steps and the cooldown starts at the swing's
	-- start, so at most one swing per 30 steps.
	Assert.isTrue(started >= 8 and started <= 10, "about one swing per cooldown, got " .. started)

	local p = combatant(w, "p")
	p.position = pos(0, 0, -15)
	w.tick(1)
	Assert.equal(brain(w, "e").state, "Chase", "out of range: chase again")
	p.position = pos(0, 0, -100)
	w.tick(30)
	Assert.equal(brain(w, "e").state, "Chase", "chasing within the leash")
end)

suite:case(
	"target loss: a removed or dead target sends the enemy home, where it resets",
	function(env)
		local w = world(env)
		w.sim:addCombatant({ id = "p", team = "players", position = pos(0, 0, -10) })
		local e = w.sim:addCombatant({ id = "e", team = "enemies", position = pos(0, 0, 0) })
		w.ai:adopt("e")
		w.tick(10)
		Assert.equal(brain(w, "e").state, "Chase", "chasing")
		e.resources.health = 50
		w.sim:removeCombatant("p")
		w.tick(1)
		Assert.equal(brain(w, "e").state, "Return", "returning")
		Assert.isNil(brain(w, "e").targetId, "target cleared")
		w.tick(30)
		Assert.equal(brain(w, "e").state, "Idle", "home again")
		Assert.equal(e.position.z, 0, "back at home")
		Assert.equal(e.resources.health, 200, "health reset")
		Assert.equal(w.events("ai_reset"), 1, "reset logged")

		w.sim:addCombatant({ id = "q", team = "players", position = pos(0, 0, -6) })
		w.tick(1)
		Assert.equal(brain(w, "e").state, "Chase", "re-aggro on a new target")
		w.sim:damage("q", 10000)
		w.tick(1)
		Assert.equal(brain(w, "e").state, "Return", "a dead target is lost")
	end
)

suite:case("path failure: after the allowed failures the enemy gives up and returns", function(env)
	local blocked = true
	local navigator: Ai.Navigator = {
		pathTo = function(_, to)
			if blocked then
				return nil
			end
			return { to }
		end,
	}
	local w = world(env, navigator)
	w.sim:addCombatant({ id = "p", team = "players", position = pos(0, 0, -10) })
	local e = w.sim:addCombatant({ id = "e", team = "enemies", position = pos(0, 0, 0) })
	w.ai:adopt("e", {
		aggroRange = 20,
		attackRange = 5,
		leashRange = 40,
		maxPathFailures = 2,
		attackCooldownSteps = 30,
		attackJitterSteps = 0,
		repathSteps = 5,
	})
	w.tick(1) -- aggro
	w.tick(1) -- failure 1
	Assert.equal(brain(w, "e").state, "Chase", "one failure tolerated")
	Assert.equal(e.position.z, 0, "did not move without a path")
	w.tick(5) -- failure 2 at step 7
	Assert.equal(brain(w, "e").state, "Chase", "two failures tolerated")
	w.tick(5) -- failure 3 at step 12
	Assert.equal(brain(w, "e").state, "Return", "gave up")
	Assert.equal(w.events("ai_path_failed"), 3, "each failure logged")
	-- Returning home also fails to path; it snaps home rather than stay stuck.
	local p = combatant(w, "p")
	p.position = pos(0, 0, -50) -- out of aggro range while it resets
	w.tick(20)
	Assert.equal(brain(w, "e").state, "Idle", "reset at home")
	blocked = false
	p.position = pos(0, 0, -10)
	w.tick(2)
	Assert.equal(brain(w, "e").state, "Chase", "chasing again once a path exists")
	w.tick(10)
	Assert.isTrue(e.position.z < -4, "moving now")
end)

suite:case("the leash: an enemy dragged too far from home returns and resets", function(env)
	local w = world(env)
	local p = w.sim:addCombatant({ id = "p", team = "players", position = pos(0, 0, -10) })
	local e = w.sim:addCombatant({ id = "e", team = "enemies", position = pos(0, 0, 0) })
	w.ai:adopt("e", {
		aggroRange = 20,
		attackRange = 5,
		leashRange = 15,
		maxPathFailures = 3,
		attackCooldownSteps = 30,
		attackJitterSteps = 0,
		repathSteps = 1,
	})
	e.resources.health = 20
	-- Kite: keep the player ten studs ahead of the enemy.
	for _ = 1, 35 do
		p.position = pos(0, 0, e.position.z - 10)
		w.tick(1)
	end
	Assert.equal(brain(w, "e").state, "Return", "leashed")
	p.position = pos(0, 0, -100) -- out of aggro range while it returns
	w.tick(60)
	Assert.equal(brain(w, "e").state, "Idle", "home")
	Assert.equal(e.resources.health, 200, "reset")
	Assert.isTrue(math.abs(e.position.x) < 0.01 and math.abs(e.position.z) < 0.01, "exactly home")
end)

suite:case(
	"loot ownership comes from server-resolved damage, and dead enemies do nothing",
	function(env)
		local w = world(env)
		w.sim:addCombatant({
			id = "a",
			team = "players",
			position = pos(0, 0, -3),
			facing = pos(0, 0, 1),
		})
		w.sim:addCombatant({
			id = "b",
			team = "players",
			position = pos(3, 0, 0),
			facing = pos(-1, 0, 0),
		})
		local actions = table.clone(ActionMachine.DEFAULT_ACTIONS)
		local attack = table.clone(ActionMachine.DEFAULT_ACTIONS.Attack)
		attack.cost = { pool = "stamina", amount = 1e6 } -- this enemy cannot swing back
		actions.Attack = attack
		local e = w.sim:addCombatant({
			id = "e",
			team = "enemies",
			position = pos(0, 0, 0),
			actions = actions,
		})
		w.ai:adopt("e")
		Assert.isTrue(w.sim:submit("a", { kind = "Attack", sequence = 1 }).ok, "a attacks")
		w.tick(30)
		Assert.isTrue(w.sim:submit("b", { kind = "Attack", sequence = 1 }).ok, "b attacks")
		w.tick(30)
		Assert.isTrue(w.sim:submit("b", { kind = "Attack", sequence = 3 }).ok, "b attacks again")
		w.tick(30)
		Assert.equal(w.ai:lootOwner("e"), "b", "most damage wins")
		Assert.isTrue((brain(w, "e").damageBy.b or 0) > (brain(w, "e").damageBy.a or 0), "tallied")
		w.sim:damage("e", 10000)
		w.tick(5)
		Assert.equal(brain(w, "e").state, "Dead", "dead brain")
		local before = e.position.z
		w.tick(30)
		Assert.equal(e.position.z, before, "a corpse does not move")
		Assert.equal(w.ai:lootOwner("e"), "b", "ownership survives death")
		w.ai:forget("e")
		Assert.isNil(w.ai:brain("e"), "forgotten")
		Assert.throws(function()
			w.ai:adopt("ghost")
		end, "unknown combatant")
	end
)

suite:case("two worlds with the same seed behave identically", function(env)
	local function play(): { string }
		local w = world(env, nil, "same")
		w.sim:addCombatant({ id = "p", team = "players", position = pos(2, 0, -8) })
		w.sim:addCombatant({ id = "e1", team = "enemies", position = pos(0, 0, 0) })
		w.sim:addCombatant({ id = "e2", team = "enemies", position = pos(-6, 0, 2) })
		w.ai:adopt("e1")
		w.ai:adopt("e2")
		w.tick(200)
		local lines = {}
		for _, event in w.sim:drainEvents() do
			table.insert(lines, event.step .. ":" .. event.id .. ":" .. event.kind)
		end
		for _, id in w.sim:ids() do
			local c = combatant(w, id)
			table.insert(
				lines,
				id .. "@" .. c.position.x .. "," .. c.position.z .. " hp " .. c.resources.health
			)
		end
		return lines
	end
	Assert.deepEqual(play(), play(), "identical")
end)

suite:case("profiles are validated", function()
	Assert.count(Ai.validateProfile(Ai.DEFAULT_PROFILE), 0, "default valid")
	local bad = table.clone(Ai.DEFAULT_PROFILE)
	bad.attackRange = 30
	Assert.contains(
		table.concat(Ai.validateProfile(bad), ";"),
		"attackRange must not exceed",
		"range order"
	)
	bad = table.clone(Ai.DEFAULT_PROFILE)
	bad.repathSteps = 0
	Assert.contains(
		table.concat(Ai.validateProfile(bad), ";"),
		"repathSteps",
		"whole positive steps"
	)
end)

return suite:cases()
