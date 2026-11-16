--!strict
-- BM-063: Cant activation, cooldown, resource and combat-state cases. All
-- outcomes are resolved by the server simulation.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local CantCatalog = require(ServerScriptService.Server.Content.CantCatalog)
local Cants = require(ServerScriptService.Server.Combat.Cants)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Cants")

type Setup = { sim: Simulation.Simulation, cants: Cants.Layer, effects: { string } }

local function pos(x: number, y: number, z: number)
	return { x = x, y = y, z = z }
end

-- A test kit: 10-step cooldown, 30 stamina, usable while Idle.
local function setup(env: Suite.Env): Setup
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork("combat") })
	local effects: { string } = {}
	local cants = Cants.attach(sim, {
		kits = {
			["cant-test"] = {
				cooldownSteps = 10,
				cost = { pool = "stamina", amount = 30 },
				usableIn = { "Idle" },
				effect = function(ctx: Cants.Context)
					table.insert(effects, ctx.caster.id .. "@" .. ctx.step)
				end,
				provisional = false,
			},
		},
	})
	sim:addCombatant({ id = "a", team = "players", position = pos(0, 0, 0) })
	return { sim = sim, cants = cants, effects = effects }
end

local function reason(outcome: any): string?
	return if outcome.ok then nil else outcome.reason
end

suite:case("an equipped Cant activates, spends its cost and runs its effect", function(env)
	local s = setup(env)
	Assert.equal(reason(s.cants:equip("a", "cant-test")), nil, "equipped")
	local a = s.sim:get("a") :: any
	local before = a.resources.stamina
	Assert.equal(reason(s.cants:activate("a")), nil, "activated")
	Assert.equal(a.resources.stamina, before - 30, "cost spent")
	Assert.deepEqual(s.effects, { "a@0" }, "effect ran once on the server")
	local events = s.sim:drainEvents()
	local saw = false
	for _, e in events do
		if e.kind == "cant_activated" and (e.data :: any).cantId == "cant-test" then
			saw = true
		end
	end
	Assert.isTrue(saw, "activation event emitted")
end)

suite:case("cooldown is counted in steps and swapping does not reset it", function(env)
	local s = setup(env)
	s.cants:equip("a", "cant-test")
	s.cants:activate("a")
	Assert.equal(s.cants:cooldownRemaining("a"), 10, "full cooldown")
	for _ = 1, 9 do
		s.sim:step()
	end
	Assert.equal(reason(s.cants:activate("a")), "cooldown", "one step early")
	s.cants:equip("a", nil)
	s.cants:equip("a", "cant-test")
	Assert.equal(reason(s.cants:activate("a")), "cooldown", "re-equip keeps the timer")
	s.sim:step()
	Assert.equal(s.cants:cooldownRemaining("a"), 0, "ready")
	Assert.equal(reason(s.cants:activate("a")), nil, "activates on the exact step")
	Assert.equal(#s.effects, 2, "two effects")
end)

suite:case("activation without resources fails and spends nothing", function(env)
	local s = setup(env)
	s.cants:equip("a", "cant-test")
	local a = s.sim:get("a") :: any
	a.resources.stamina = 29
	Assert.equal(reason(s.cants:activate("a")), "cannot afford", "too poor")
	Assert.equal(a.resources.stamina, 29, "nothing spent")
	Assert.equal(s.cants:cooldownRemaining("a"), 0, "no cooldown started")
	Assert.equal(#s.effects, 0, "no effect")
end)

suite:case("combat state gates activation", function(env)
	local s = setup(env)
	s.cants:equip("a", "cant-test")
	Assert.isTrue(s.sim:submit("a", { kind = "Attack", sequence = 1 }).ok, "queued attack")
	s.sim:step()
	Assert.equal((s.sim:get("a") :: any).action.state, "Attacking", "attacking")
	Assert.equal(reason(s.cants:activate("a")), "not usable now", "not while attacking")
	Assert.equal(reason(s.cants:equip("a", "cant-test")), "busy", "no equip mid-action")
	s.sim:damage("a", 100000)
	s.sim:step()
	Assert.equal(reason(s.cants:activate("a")), "dead", "never while dead")
	Assert.equal(#s.effects, 0, "no effect")
end)

suite:case("unknown, unavailable and unequipped Cants are refused", function(env)
	local s = setup(env)
	Assert.equal(reason(s.cants:activate("a")), "no cant equipped", "nothing equipped")
	Assert.equal(reason(s.cants:equip("a", "cant-fake")), "cant not available", "no kit")
	Assert.equal(reason(s.cants:equip("ghost", "cant-test")), "unknown combatant", "ghost")
	Assert.equal(reason(s.cants:activate("ghost")), "unknown combatant", "ghost activate")
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork("c2") })
	sim:addCombatant({ id = "a", team = "players" })
	local catalog = CantCatalog.production()
	local layer = Cants.attach(sim, {
		kits = Cants.PRODUCTION_KITS,
		resolve = function(value)
			return catalog:resolve(value)
		end,
	})
	Assert.equal(reason(layer:equip("a", "cant-invented")), "unknown cant", "catalog refuses")
	Assert.equal(reason(layer:equip("a", "cant-nearness")), nil, "Nearness equips")
	Assert.equal(reason(layer:activate("a")), nil, "Nearness activates")
end)

suite:case("invalid kits are refused at attach", function(env)
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork("c3") })
	local function kitWith(overrides: { [string]: any }): any
		local kit: { [string]: any } = {
			cooldownSteps = 10,
			usableIn = { "Idle" },
			effect = function() end,
			provisional = true,
		}
		for k, v in overrides do
			kit[k] = v
		end
		return kit
	end
	Assert.equal(#Cants.validateKit(kitWith({})), 0, "base kit valid")
	Assert.isTrue(#Cants.validateKit(kitWith({ cooldownSteps = -1 })) > 0, "negative cooldown")
	Assert.isTrue(#Cants.validateKit(kitWith({ cooldownSteps = 1.5 })) > 0, "fractional")
	Assert.isTrue(
		#Cants.validateKit(kitWith({ cost = { pool = "mana", amount = 5 } })) > 0,
		"unknown pool"
	)
	Assert.isTrue(
		#Cants.validateKit(kitWith({ cost = { pool = "stamina", amount = 0 / 0 } })) > 0,
		"NaN cost"
	)
	Assert.isTrue(#Cants.validateKit(kitWith({ usableIn = { "Dead" } })) > 0, "dead usable")
	Assert.isTrue(#Cants.validateKit(kitWith({ usableIn = {} })) > 0, "no states")
	Assert.throws(function()
		Cants.attach(sim, { kits = { ["cant-x"] = kitWith({ effect = 5 }) } })
	end, "is invalid")
end)

suite:case("every production kit names a catalog Cant and validates", function()
	local catalog = CantCatalog.production()
	for cantId, kit in Cants.PRODUCTION_KITS do
		Assert.notNil(catalog:resolve(cantId), cantId .. " in catalog")
		Assert.deepEqual(Cants.validateKit(kit), {}, cantId .. " valid")
		local def = catalog:get(cantId) :: CantCatalog.Definition
		Assert.equal(kit.provisional, def.mechanics == "provisional", "provisional flags agree")
	end
end)

return suite:cases()
