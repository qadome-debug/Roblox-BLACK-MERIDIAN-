--!strict
-- Life, death and respawn of a player combatant. The regression here: a
-- combatant that died stayed "Dead" forever, because nothing revived it
-- when the character respawned, so every Verse was refused for the rest of
-- the session. Also covers the abilities across extended use, Dissonance
-- rupture, the Long Way Home penalty and isolation between players.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local CombatService = require(ServerScriptService.Server.Services.CombatService)
local FakeWorld = require(ServerStorage.Tests.Support.FakeWorld)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

local suite = Suite.new("Lifecycle")

local VERSES = { "near.close_step", "near.draw_near", "near.between_us", "near.no_farther" }

local function make(env: Suite.Env, options: any?): (any, { number })
	local opts = options or {}
	local world = FakeWorld.new(opts.world)
	local deaths: { number } = {}
	local combat = CombatService.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		send = function() end,
		world = world,
		lineOfSight = world.lineOfSight,
		teleport = function()
			return true
		end,
		chosenBurden = opts.chosen,
		masteryUnlocked = opts.mastery,
		onPlayerDied = function(userId: number)
			table.insert(deaths, userId)
		end,
	})
	for _, userId in { 1, 2 } do
		combat:addPlayer(userId)
		local id = combat:combatantId(userId)
		combat.cants:equip(id, "cant.nearness")
		local c = combat.sim:get(id) :: any
		c.position = Vec3.new(userId * 100, 3, 0)
	end
	return combat, deaths
end

local function enemy(combat: any, id: string, x: number, z: number)
	combat.sim:addCombatant({ id = id, team = "enemies", position = Vec3.new(x, 3, z) })
end

local function step(combat: any, n: number)
	for _ = 1, n do
		combat.sim:step()
	end
end

local function refill(combat: any, userId: number)
	local id = combat:combatantId(userId)
	local c = combat.sim:get(id) :: any
	c.resources.stamina = c.derived.maxStamina
	combat.verses:forget(id)
end

local function castCloseStep(combat: any, userId: number): any
	local id = combat:combatantId(userId)
	local c = combat.sim:get(id) :: any
	return combat.verses:cast(id, "near.close_step", nil, {
		aim = Vec3.new(c.position.x, 3, c.position.z + 14),
	})
end

suite:case(
	"REGRESSION: a dead player cannot cast, and a respawn lets them cast again",
	function(env)
		local combat = make(env)
		local id = combat:combatantId(1)
		Assert.isTrue(castCloseStep(combat, 1).ok, "alive: cast works")
		step(combat, 3)
		combat:killPlayer(1)
		Assert.isTrue(combat:isDead(1), "dead")
		refill(combat, 1)
		local refused = castCloseStep(combat, 1)
		Assert.isFalse(refused.ok, "a dead player is refused")
		Assert.equal(refused.reason, "dead", "for the right reason")
		-- Time passing does not bring them back (this was the permanent failure).
		step(combat, 400)
		Assert.isTrue(combat:isDead(1), "still dead after waiting")
		-- A new life does.
		Assert.isTrue(combat:respawnPlayer(1), "respawned")
		Assert.isFalse(combat:isDead(1), "alive")
		Assert.isTrue(castCloseStep(combat, 1).ok, "casting works after the respawn")
		local view: any = combat:ownView(1)
		Assert.equal(view.health, view.maxHealth, "full health")
		Assert.equal(view.state, "Idle", "idle")
		Assert.equal(id, combat:combatantId(1), "same combatant")
	end
)

suite:case("the death callback fires once per death, only for players", function(env)
	local combat, deaths = make(env)
	enemy(combat, "e1", 0, -5)
	combat.sim:damage("e1", 100000)
	step(combat, 3)
	Assert.equal(#deaths, 0, "an enemy dying is not reported")
	combat:killPlayer(1)
	step(combat, 5)
	Assert.equal(#deaths, 1, "reported once")
	Assert.equal(deaths[1], 1, "the right player")
	combat:respawnPlayer(1)
	combat:killPlayer(1)
	step(combat, 5)
	Assert.equal(#deaths, 2, "a second life can end too")
end)

suite:case(
	"damage reaching zero health kills; stamina and casting never lower health",
	function(env)
		local combat = make(env)
		local c = combat.sim:get(combat:combatantId(1)) :: any
		local max = c.derived.maxHealth
		for _ = 1, 20 do
			refill(combat, 1)
			for _, verse in VERSES do
				local aim = Vec3.new(c.position.x, 3, c.position.z + 5)
				combat.verses:cast(combat:combatantId(1), verse, nil, { aim = aim })
				step(combat, 40)
				refill(combat, 1)
			end
		end
		Assert.equal(c.resources.health, max, "casting never costs health")
		Assert.isFalse(combat:isDead(1), "alive")
		combat.sim:damage(combat:combatantId(1), 30)
		Assert.equal(c.resources.health, max - 30, "damage lowers health")
		step(combat, 200)
		Assert.equal(c.resources.health, max - 30, "health does not regenerate by itself")
		combat.sim:damage(combat:combatantId(1), max)
		Assert.isTrue(combat:isDead(1), "zero health is death")
	end
)

suite:case(
	"respawn keeps cooldowns, Dissonance and the penalty; only the demo wipe clears them",
	function(env)
		local combat = make(env, {
			chosen = function()
				return "burden.long_way_home"
			end,
			mastery = function()
				return true
			end,
		})
		local id = combat:combatantId(1)
		combat.cants:equip(id, nil)
		combat.cants:equip(id, "cant.nearness")
		enemy(combat, "e1", 100, -10)
		enemy(combat, "e2", 100, -14)
		refill(combat, 1)
		Assert.isTrue(castCloseStep(combat, 1).ok, "close step")
		step(combat, 3)
		Assert.isTrue(combat.dissonance:value(id) > 0, "gained Dissonance")
		Assert.isTrue(combat.verses:cooldownRemaining(id, "near.close_step") > 0, "cooling down")
		local dissonanceBefore = combat.dissonance:value(id)
		local movesBefore = combat.burdens:moves(id)
		local penaltyBefore = combat.burdens:penalty(id)
		combat:killPlayer(1)
		combat:respawnPlayer(1)
		Assert.isFalse(combat:isDead(1), "alive again")
		Assert.isTrue(
			combat.dissonance:value(id) >= dissonanceBefore,
			"Dissonance NOT cleared by death"
		)
		Assert.isTrue(
			combat.verses:cooldownRemaining(id, "near.close_step") > 0,
			"cooldown NOT cleared by death"
		)
		Assert.equal(combat.burdens:moves(id), movesBefore, "Burden count NOT cleared")
		Assert.equal(combat.burdens:penalty(id), penaltyBefore, "stamina penalty NOT cleared")
		-- The Studio demo's H reset (Playtest/Server.luau) wipes it explicitly.
		combat.verses:forget(id)
		combat.dissonance:forget(id)
		if combat.verseEffects ~= nil then
			combat.verseEffects:forget(id)
		end
		combat.burdens:reset(id)
		Assert.equal(combat.dissonance:value(id), 0, "demo wipe: Dissonance")
		Assert.equal(
			combat.verses:cooldownRemaining(id, "near.close_step"),
			0,
			"demo wipe: cooldown"
		)
		Assert.equal(combat.burdens:moves(id), 0, "demo wipe: penalty")
		Assert.equal(combat.burdens:penalty(id), 0, "demo wipe: no stamina penalty")
	end
)

suite:case("rapid, repeated and alternating casts never lock the player out", function(env)
	local combat = make(env)
	local id = combat:combatantId(1)
	enemy(combat, "e1", 100, -6)
	enemy(combat, "e2", 100, -9)
	local accepted = 0
	local refusals: { [string]: number } = {}
	for round = 1, 60 do
		for _, verse in VERSES do
			local c = combat.sim:get(id) :: any
			c.resources.stamina = c.derived.maxStamina
			local extra: any = { aim = Vec3.new(100, 3, -4) }
			local target: string? = nil
			if verse == "near.draw_near" then
				target = "e1"
			elseif verse == "near.between_us" then
				target = "e1"
				extra.targetB = "e2"
			end
			local outcome = combat.verses:cast(id, verse, target, extra)
			if outcome.ok then
				accepted += 1
			else
				refusals[outcome.reason] = (refusals[outcome.reason] or 0) + 1
			end
			step(combat, 2 + (round % 3))
			c.position = Vec3.new(100, 3, 0)
		end
		step(combat, 600)
		-- A clean slate for the targets so each round starts the same.
		for _, e in { "e1", "e2" } do
			local t = combat.sim:get(e) :: any
			t.position = Vec3.new(100, 3, e == "e1" and -6 or -9)
		end
	end
	Assert.isTrue(accepted >= 120, "casts keep being accepted (" .. accepted .. ")")
	Assert.isFalse(combat:isDead(1), "never dead")
	local c = combat.sim:get(id) :: any
	Assert.isTrue(c.resources.health == c.derived.maxHealth, "health untouched")
	Assert.isTrue(
		c.resources.stamina >= 0 and c.resources.stamina <= c.derived.maxStamina,
		"bounds"
	)
	local view: any = combat:ownView(1)
	Assert.equal(view.state, "Idle", "not stuck in a cast")
	for reason in refusals do
		Assert.isTrue(
			reason == "cooldown"
				or reason == "already casting"
				or reason == "not enough stamina"
				or reason == "target out of range",
			"only ordinary refusals, got " .. reason
		)
	end
end)

suite:case("refusals are for the stated reason: cooldown, stamina, target", function(env)
	local combat = make(env)
	local id = combat:combatantId(1)
	Assert.isTrue(castCloseStep(combat, 1).ok, "first cast")
	step(combat, 3)
	local again = castCloseStep(combat, 1)
	Assert.isFalse(again.ok, "cooldown")
	Assert.equal(again.reason, "cooldown", "reason")
	local c = combat.sim:get(id) :: any
	combat.verses:forget(id)
	c.resources.stamina = 5
	local poor = castCloseStep(combat, 1)
	Assert.isFalse(poor.ok, "no stamina")
	Assert.equal(poor.reason, "cannot afford", "reason")
	c.resources.stamina = c.derived.maxStamina
	local far = combat.verses:cast(id, "near.draw_near", "ghost", nil)
	Assert.isFalse(far.ok, "invalid target")
end)

suite:case("Dissonance at every band and at rupture never kills or locks the player", function(env)
	local combat = make(env)
	local id = combat:combatantId(1)
	for _, amount in { 40, 25, 20, 15 } do
		combat.dissonance:add(id, amount, "verse")
		Assert.isFalse(combat:isDead(1), "alive in band " .. combat.dissonance:level(id))
		refill(combat, 1)
		local outcome = castCloseStep(combat, 1)
		Assert.isTrue(outcome.ok, "can cast at " .. combat.dissonance:value(id))
		step(combat, 3)
	end
	-- 40 + 25 + 20 + 15 reached 100 at some point: the rupture dropped it.
	Assert.isTrue(combat.dissonance:value(id) < 100, "ruptured and dropped")
	local c = combat.sim:get(id) :: any
	Assert.equal(c.resources.health, c.derived.maxHealth, "rupture did not hurt")
	refill(combat, 1)
	Assert.isTrue(castCloseStep(combat, 1).ok, "still able to cast after the rupture")
end)

suite:case("Long Way Home reaches its cap, never locks regeneration, and recovers", function(env)
	local combat = make(env, {
		chosen = function()
			return "burden.long_way_home"
		end,
		mastery = function()
			return true
		end,
	})
	local id = combat:combatantId(1)
	combat.cants:equip(id, nil)
	combat.cants:equip(id, "cant.nearness")
	local c = combat.sim:get(id) :: any
	local base = c.derived.staminaRegen
	for _ = 1, 12 do
		c.position = Vec3.new(100, 3, 0)
		refill(combat, 1)
		Assert.isTrue(castCloseStep(combat, 1).ok, "close step")
		step(combat, 3)
		Assert.isTrue(c.derived.staminaRegen > 0, "regeneration stays positive")
	end
	Assert.isTrue(math.abs(combat.burdens:penalty(id) - 0.5) < 1e-6, "capped at 50%")
	Assert.isTrue(math.abs(c.derived.staminaRegen - base * 0.5) < 1e-6, "half regeneration")
	c.resources.stamina = 0
	c.resources.lastSpent.stamina = -math.huge
	step(combat, 100)
	Assert.isTrue(c.resources.stamina > 0, "stamina still recovers under the full penalty")
	combat.burdens:reset(id)
	Assert.equal(c.derived.staminaRegen, base, "full regeneration after the penalty clears")
end)

suite:case("players are isolated: one's death and respawn never touch the other", function(env)
	local combat = make(env)
	local a, b = combat:combatantId(1), combat:combatantId(2)
	refill(combat, 2)
	Assert.isTrue(castCloseStep(combat, 2).ok, "player 2 casts")
	step(combat, 3)
	local cooling = combat.verses:cooldownRemaining(b, "near.close_step")
	local dissonance = combat.dissonance:value(b)
	Assert.isTrue(cooling > 0 and dissonance > 0, "player 2 has state")
	combat:killPlayer(1)
	step(combat, 5)
	Assert.isTrue(combat:isDead(1), "player 1 dead")
	Assert.isFalse(combat:isDead(2), "player 2 alive")
	Assert.equal(combat.dissonance:value(b), dissonance, "player 2 Dissonance untouched")
	local later = combat.verses:cooldownRemaining(b, "near.close_step")
	Assert.isTrue(later < cooling, "player 2's cooldown kept counting down")
	combat:respawnPlayer(1)
	Assert.equal(combat.verses:cooldownRemaining(b, "near.close_step"), later, "cooldown untouched")
	Assert.isFalse(combat:isDead(2), "still alive")
	Assert.equal(combat.dissonance:value(a), 0, "player 1 fresh")
end)

suite:case("leaving and rejoining gives a clean, living combatant", function(env)
	local combat = make(env)
	combat:killPlayer(1)
	step(combat, 3)
	combat:removePlayer(1)
	Assert.isFalse(combat:hasPlayer(1), "gone")
	combat:addPlayer(1)
	Assert.isFalse(combat:isDead(1), "alive again")
	Assert.isFalse(combat:respawnPlayer(99), "an unknown player cannot respawn")
end)

suite:case("the own view reports health and death for the HUD", function(env)
	local combat = make(env)
	local view: any = combat:ownView(1)
	Assert.equal(view.health, view.maxHealth, "full at the start")
	combat.sim:damage(combat:combatantId(1), 25)
	view = combat:ownView(1)
	Assert.equal(view.health, view.maxHealth - 25, "damage shows")
	combat:killPlayer(1)
	view = combat:ownView(1)
	Assert.equal(view.health, 0, "zero")
	Assert.equal(view.state, "Dead", "state says dead")
	combat:respawnPlayer(1)
	view = combat:ownView(1)
	Assert.equal(view.health, view.maxHealth, "restored")
	Assert.equal(view.state, "Idle", "alive")
end)

suite:case("REGRESSION: a demo dummy woken by walking through it does not follow", function(env)
	local combat = make(env)
	combat:spawnEnemy({
		id = "dummy",
		position = { x = 0, y = 3, z = 0 },
		modifiers = { { id = "demo_dummy", stat = "attackPower", add = -1000 } },
		profile = {
			aggroRange = 1,
			attackRange = 1,
			leashRange = 1,
			maxPathFailures = 3,
			attackCooldownSteps = 3000,
			attackJitterSteps = 0,
			repathSteps = 10,
		},
	})
	local player = combat.sim:get(combat:combatantId(1)) :: any
	local dummy = combat.sim:get("dummy") :: any
	player.position = Vec3.new(0.5, 3, 0)
	step(combat, 5)
	player.position = Vec3.new(60, 3, 0)
	step(combat, 400)
	Assert.isTrue(
		Vec3.flatDistance(dummy.position, Vec3.new(0, 3, 0)) < 4,
		"the dummy stayed near home ("
			.. Vec3.flatDistance(dummy.position, Vec3.new(0, 3, 0))
			.. ")"
	)
	Assert.equal(
		combat.sim:get(combat:combatantId(1)).resources.health,
		player.derived.maxHealth,
		"no damage"
	)
end)

return suite:cases()
