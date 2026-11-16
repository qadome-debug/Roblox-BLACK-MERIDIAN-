--!strict
-- BM-069/BM-071 (the part that exists): the Burden in force follows the
-- equipped Cant; Long Way Home lowers stamina regeneration by 10% per
-- Close Step up to 50%, and clears on stable ground. Unwanted Company has
-- no effect until a behaviour-based version is approved.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local BurdenCatalog = require(ServerScriptService.Server.Content.BurdenCatalog)
local CombatService = require(ServerScriptService.Server.Services.CombatService)
local FakeWorld = require(ServerStorage.Tests.Support.FakeWorld)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

local suite = Suite.new("BurdenEffects")

local function service(env: Suite.Env, options: any?)
	local opts = options or {}
	local world = FakeWorld.new()
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
		inStableEnvironment = opts.stable,
	})
	combat:addPlayer(1)
	return combat, combat:combatantId(1)
end

local function closeStep(combat: any, id: string)
	local caster = combat.sim:get(id)
	caster.position = Vec3.new(0, 3, 0)
	caster.resources.stamina = caster.derived.maxStamina
	combat.verses.forget(combat.verses, id)
	local outcome = combat.verses:cast(id, "near.close_step", nil, { aim = Vec3.new(0, 3, 30) })
	Assert.isTrue(outcome.ok, "cast")
	combat.sim:step()
	combat.sim:step()
end

suite:case("the default Burden follows the equipped Cant, and unequipping clears it", function(env)
	local combat, id = service(env)
	Assert.isNil(combat.burdens:active(id), "no Cant, no Burden")
	combat.cants:equip(id, "cant.nearness")
	Assert.equal(combat.burdens:active(id), "burden.unwanted_company", "Nearness default")
	combat.cants:equip(id, "cant.embers")
	Assert.isNil(combat.burdens:active(id), "a Cant with no Burden defined has none")
	combat.cants:equip(id, "cant.nearness")
	combat.cants:equip(id, nil)
	Assert.isNil(combat.burdens:active(id), "cleared")
	combat:removePlayer(1)
	Assert.isNil(combat.burdens:active(id), "forgotten on leave")
end)

suite:case(
	"Unwanted Company has no effect yet, and does not change stamina regeneration",
	function(env)
		local combat, id = service(env)
		combat.cants:equip(id, "cant.nearness")
		local caster = combat.sim:get(id) :: any
		local regen = caster.derived.staminaRegen
		for _ = 1, 3 do
			closeStep(combat, id)
			combat.sim:step()
		end
		Assert.equal(combat.burdens:penalty(id), 0, "no penalty")
		Assert.equal(caster.derived.staminaRegen, regen, "unchanged")
		Assert.equal(combat.burdens:moves(id), 0, "moves are not even counted")
	end
)

suite:case("a mastery Burden needs both the choice and unlocked mastery", function(env)
	local chosen = "burden.long_way_home"
	local unlocked = false
	local combat, id = service(env, {
		chosen = function()
			return chosen
		end,
		mastery = function()
			return unlocked
		end,
	})
	combat.cants:equip(id, "cant.nearness")
	Assert.equal(combat.burdens:active(id), "burden.unwanted_company", "locked: the default stays")
	unlocked = true
	combat.cants:equip(id, "cant.embers")
	combat.cants:equip(id, "cant.nearness")
	Assert.equal(combat.burdens:active(id), "burden.long_way_home", "unlocked and chosen")
	chosen = "burden.unwanted_company"
	combat.cants:equip(id, "cant.embers")
	combat.cants:equip(id, "cant.nearness")
	Assert.equal(combat.burdens:active(id), "burden.unwanted_company", "choosing the default")
end)

suite:case(
	"Long Way Home: 10% less stamina regeneration per Close Step, capped at 50%",
	function(env)
		local combat, id = service(env, {
			chosen = function()
				return "burden.long_way_home"
			end,
			mastery = function()
				return true
			end,
		})
		combat.cants:equip(id, "cant.nearness")
		local caster = combat.sim:get(id) :: any
		local base = caster.derived.staminaRegen
		Assert.equal(combat.burdens:active(id), "burden.long_way_home", "active")
		for count = 1, 7 do
			combat.sim:step()
			-- Let the cooldown pass so every Close Step is a real cast.
			for _ = 1, 215 do
				combat.sim:step()
			end
			closeStep(combat, id)
			local expected = math.min(0.5, 0.1 * count)
			Assert.equal(combat.burdens:moves(id), count, "move " .. count .. " counted")
			Assert.isTrue(
				math.abs(combat.burdens:penalty(id) - expected) < 1e-9,
				"penalty after " .. count .. " moves is " .. expected
			)
			Assert.isTrue(
				math.abs(caster.derived.staminaRegen - base * (1 - expected)) < 1e-9,
				"regeneration follows"
			)
		end
		-- Other Nearness Verses are not Nearness movement.
		local before = combat.burdens:moves(id)
		local enemy =
			combat.sim:addCombatant({ id = "e1", team = "enemies", position = Vec3.new(15, 3, 0) })
		caster.resources.stamina = caster.derived.maxStamina
		caster.position = Vec3.new(0, 3, 0)
		combat.verses:cast(id, "near.draw_near", "e1")
		for _ = 1, 30 do
			combat.sim:step()
		end
		Assert.equal(enemy.position.x < 15, true, "the pull happened")
		Assert.equal(combat.burdens:moves(id), before, "a pull is not a qualifying move")
	end
)

suite:case("the penalty clears on stable ground and when the Cant is swapped", function(env)
	local stable = false
	local combat, id = service(env, {
		chosen = function()
			return "burden.long_way_home"
		end,
		mastery = function()
			return true
		end,
		stable = function(_id: string): boolean
			return stable
		end,
	})
	combat.cants:equip(id, "cant.nearness")
	local caster = combat.sim:get(id) :: any
	local base = caster.derived.staminaRegen
	closeStep(combat, id)
	Assert.isTrue(combat.burdens:penalty(id) > 0.09, "penalised")
	combat.sim:step()
	Assert.isTrue(combat.burdens:penalty(id) > 0.09, "not stable: it stays")
	stable = true
	combat.sim:step()
	Assert.equal(combat.burdens:moves(id), 0, "stable ground clears the count")
	Assert.equal(caster.derived.staminaRegen, base, "regeneration restored")

	stable = false
	closeStep(combat, id)
	combat.cants:equip(id, "cant.embers")
	Assert.equal(caster.derived.staminaRegen, base, "swapping the Cant restores it")
end)

suite:case("the production catalog shapes: one default, one mastery, no pickup model", function()
	local catalog = BurdenCatalog.production()
	local nearness = catalog:forCant("cant.nearness")
	Assert.equal(nearness.default, "burden.unwanted_company", "default")
	Assert.deepEqual(nearness.mastery, { "burden.long_way_home" }, "mastery")
	local lwh = catalog:get("burden.long_way_home") :: any
	Assert.equal(lwh.effect, "stamina_regen_penalty", "effect name")
	Assert.equal(lwh.params.perMove, 0.1, "10% per move")
	Assert.equal(lwh.params.cap, 0.5, "capped at 50%")
	Assert.equal(lwh.mechanics, "provisional", "initial test values")
	Assert.isNil(
		(catalog:get("burden.unwanted_company") :: any).effect,
		"Unwanted Company has no effect yet"
	)
end)

return suite:cases()
