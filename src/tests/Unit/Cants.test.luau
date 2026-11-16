--!strict
-- BM-063: a Cant is an equipped discipline with no ability of its own.
-- Equipping is server-owned, catalog-checked and refused mid-action.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local CantCatalog = require(ServerScriptService.Server.Content.CantCatalog)
local Cants = require(ServerScriptService.Server.Combat.Cants)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

local suite = Suite.new("Cants")

local BASE = { vigor = 10, might = 10, grace = 10, will = 10 }

local function setup(env: Suite.Env)
	local sim = Simulation.new({ logger = env.logger, rng = env.rng })
	sim:addCombatant({ id = "a", team = "players", base = BASE, position = Vec3.new(0, 0, 0) })
	local known: { [string]: boolean } = { ["cant.test"] = true, ["cant.other"] = true }
	local cants = Cants.attach(sim, {
		resolve = function(value: unknown): string?
			return if type(value) == "string" and known[value] then value else nil
		end,
	})
	return sim, cants
end

local function reason(outcome: any): string?
	return if outcome.ok then nil else outcome.reason
end

suite:case("a known Cant equips, swaps and unequips", function(env)
	local _, cants = setup(env)
	Assert.isNil(cants:equipped("a"), "nothing equipped at first")
	Assert.isTrue(cants:equip("a", "cant.test").ok, "equip")
	Assert.equal(cants:equipped("a"), "cant.test", "equipped")
	Assert.isTrue(cants:equip("a", "cant.other").ok, "swap")
	Assert.equal(cants:equipped("a"), "cant.other", "swapped")
	Assert.isTrue(cants:equip("a", nil).ok, "unequip")
	Assert.isNil(cants:equipped("a"), "cleared")
end)

suite:case("unknown Cants and unknown combatants are refused", function(env)
	local _, cants = setup(env)
	Assert.equal(reason(cants:equip("a", "cant.invented")), "unknown cant", "not in the catalog")
	Assert.isNil(cants:equipped("a"), "nothing equipped")
	Assert.equal(reason(cants:equip("ghost", "cant.test")), "unknown combatant", "no combatant")
	Assert.equal(reason(cants:equip("ghost", nil)), "unknown combatant", "no combatant to clear")
end)

suite:case("a discipline cannot be swapped in the middle of an action", function(env)
	local sim, cants = setup(env)
	Assert.isTrue(cants:equip("a", "cant.test").ok, "equip while idle")
	Assert.isTrue(sim:submit("a", { kind = "Attack", sequence = 1 }).ok, "attack")
	sim:step()
	Assert.equal(reason(cants:equip("a", "cant.other")), "busy", "refused mid-action")
	Assert.equal(cants:equipped("a"), "cant.test", "unchanged")
end)

suite:case("forget clears the combatant's Cant", function(env)
	local _, cants = setup(env)
	cants:equip("a", "cant.test")
	cants:forget("a")
	Assert.isNil(cants:equipped("a"), "forgotten")
end)

suite:case("a Cant has no ability of its own", function(env)
	local _, cants = setup(env)
	-- The layer offers equipping only. There is no activation, cooldown or
	-- cost on a Cant: those belong to its Verses.
	local surface: { string } = {}
	for name in cants :: any do
		table.insert(surface, name)
	end
	table.sort(surface)
	Assert.deepEqual(surface, { "equip", "equipped", "forget" }, "the whole layer")
	Assert.isNil((Cants :: any).PRODUCTION_KITS, "no activation kits")
end)

suite:case("the four launch Cants equip through the production catalog", function(env)
	local sim = Simulation.new({ logger = env.logger, rng = env.rng })
	sim:addCombatant({ id = "a", team = "players", base = BASE, position = Vec3.new(0, 0, 0) })
	local catalog = CantCatalog.production()
	local cants = Cants.attach(sim, {
		resolve = function(value: unknown): string?
			return catalog:resolve(value)
		end,
	})
	for _, cantId in { "cant.nearness", "cant.embers", "cant.second_voice", "cant.still_water" } do
		Assert.isTrue(cants:equip("a", cantId).ok, cantId .. " is a known discipline")
	end
	Assert.equal(reason(cants:equip("a", "cant-nearness")), "unknown cant", "the old ID is gone")
end)

return suite:cases()
