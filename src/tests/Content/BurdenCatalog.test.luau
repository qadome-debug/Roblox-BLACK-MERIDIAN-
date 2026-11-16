--!strict
-- BM-069: a Burden belongs to a Cant, as a default or a mastery Burden.
-- Catalog integrity and the rule for which Burden is in force. Test IDs
-- only; not canon.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local BurdenCatalog = require(ServerScriptService.Server.Content.BurdenCatalog)
local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local ContentFixtures = require(ServerStorage.Tests.Support.ContentFixtures)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("BurdenCatalog")

-- Fixture registry: burden.ta and burden.tb belong to cant.ta, burden.tc
-- belongs to cant.tc.
local function defs(): { any }
	return {
		{
			id = "burden.ta",
			cantId = "cant.ta",
			role = "default",
			effect = "test_pressure",
			params = { threshold = 40, factor = 1.25 },
			mechanics = "canonical",
		},
		{
			id = "burden.tb",
			cantId = "cant.ta",
			role = "mastery",
			mechanics = "provisional",
		},
		{
			id = "burden.tc",
			cantId = "cant.tc",
			role = "default",
			mechanics = "provisional",
		},
	}
end

local function problemsWith(change: (list: { any }) -> ()): string
	local list = defs()
	change(list)
	return table.concat(BurdenCatalog.validate(list, ContentFixtures.registry()), "\n")
end

suite:case("the fixture catalog validates and the production one matches canon", function()
	Assert.deepEqual(BurdenCatalog.validate(defs(), ContentFixtures.registry()), {}, "fixtures")
	local production = BurdenCatalog.production()
	Assert.equal(#production:ids(), #Canon:ids("burden"), "one definition per canonical Burden")
end)

suite:case("only canonical Burden IDs are accepted", function()
	local catalog = BurdenCatalog.build(defs(), ContentFixtures.registry())
	Assert.equal(catalog:resolve("burden.ta"), "burden.ta", "known")
	for _, value: any in { "burden.invented", "cant.ta", "", 7, {}, true } :: { any } do
		Assert.isNil(catalog:resolve(value), "rejected " .. tostring(value))
	end
	Assert.contains(
		problemsWith(function(list)
			list[1].id = "burden.invented"
		end),
		"not a canonical Burden ID",
		"fabricated"
	)
	Assert.contains(
		problemsWith(function(list)
			table.remove(list, 3)
		end),
		"burden.tc: canonical Burden has no definition",
		"missing"
	)
	Assert.contains(
		problemsWith(function(list)
			table.insert(list, table.clone(list[1]))
		end),
		"defined more than once",
		"duplicate"
	)
end)

suite:case("a Burden is bound to its Cant and has one role", function()
	Assert.contains(
		problemsWith(function(list)
			list[1].cantId = "cant.tc"
		end),
		"burden.ta: cantId must be cant.ta (registry)",
		"wrong Cant"
	)
	Assert.contains(
		problemsWith(function(list)
			list[2].role = "default"
		end),
		"cant.ta already has the default Burden burden.ta",
		"two defaults"
	)
	Assert.contains(
		problemsWith(function(list)
			list[1].role = "mastery"
		end),
		"a mastery Burden needs cant.ta to have a default Burden",
		"mastery without a default"
	)
	Assert.contains(
		problemsWith(function(list)
			list[1].role = "pickup"
		end),
		"role must be default or mastery",
		"unknown role"
	)
end)

suite:case("the old pickup model is gone: no sources, stacks or stat modifiers", function()
	for _, field in { "sources", "maxStacks", "modifiers", "incompatibleWith" } do
		Assert.contains(
			problemsWith(function(list)
				list[1][field] = {}
			end),
			"unknown field " .. field,
			field
		)
	end
end)

suite:case("effects are names and parameters are bounded numbers", function()
	local bad: { [string]: (def: any) -> () } = {
		["effect must be a lower-case effect name"] = function(def)
			def.effect = "Do Things!"
		end,
		["param factor must be a bounded finite number"] = function(def)
			def.params.factor = 0 / 0
		end,
		["param threshold must be a bounded finite number"] = function(def)
			def.params.threshold = math.huge
		end,
		["params must be a table of numbers"] = function(def)
			def.params = 5
		end,
		["a canonical Burden names its effect"] = function(def)
			def.effect = nil
			def.params = nil
		end,
		["params without an effect"] = function(def)
			def.effect = nil
			def.mechanics = "provisional"
		end,
		["mechanics must be canonical or provisional"] = function(def)
			def.mechanics = "final"
		end,
	}
	for expected, change in bad do
		Assert.contains(
			problemsWith(function(list)
				change(list[1])
			end),
			expected,
			expected
		)
	end
	Assert.contains(
		problemsWith(function(list)
			list[1].effect = function() end
		end),
		"effect must be a lower-case effect name",
		"a function is never an effect"
	)
	Assert.contains(
		problemsWith(function(list)
			for i = 1, BurdenCatalog.MAX_PARAMS + 1 do
				list[1].params["p" .. i] = i
			end
		end),
		"at most " .. BurdenCatalog.MAX_PARAMS .. " params",
		"too many params"
	)
	Assert.throws(function()
		BurdenCatalog.build({ { id = "burden.invented" } } :: any, ContentFixtures.registry())
	end, "definitions are invalid", "build refuses")
end)

suite:case("the Burden in force comes from the equipped Cant", function()
	local catalog = BurdenCatalog.build(defs(), ContentFixtures.registry())
	local forA = catalog:forCant("cant.ta")
	Assert.equal(forA.default, "burden.ta", "default of cant.ta")
	Assert.deepEqual(forA.mastery, { "burden.tb" }, "mastery of cant.ta")
	Assert.isNil(catalog:forCant("cant.tb").default, "a Cant without Burdens")
	Assert.isTrue(catalog:belongsTo("burden.tb", "cant.ta"), "belongs")
	Assert.isFalse(catalog:belongsTo("burden.tc", "cant.ta"), "another Cant's Burden")

	Assert.equal(catalog:activeFor("cant.ta", nil, false), "burden.ta", "default applies")
	Assert.equal(
		catalog:activeFor("cant.ta", "burden.tb", false),
		"burden.ta",
		"a mastery choice without mastery falls back to the default"
	)
	Assert.equal(catalog:activeFor("cant.ta", "burden.tb", true), "burden.tb", "mastery choice")
	Assert.equal(
		catalog:activeFor("cant.ta", "burden.tc", true),
		"burden.ta",
		"another Cant's Burden is never in force"
	)
	Assert.equal(
		catalog:activeFor("cant.ta", "burden.ta", true),
		"burden.ta",
		"choosing the default is the default"
	)
	Assert.equal(catalog:activeFor("cant.tc", nil, true), "burden.tc", "other Cant")
	Assert.isNil(catalog:activeFor("cant.tb", nil, true), "no Burden defined")
	Assert.isNil(catalog:activeFor("cant.invented", "burden.ta", true), "unknown Cant")
end)

return suite:cases()
