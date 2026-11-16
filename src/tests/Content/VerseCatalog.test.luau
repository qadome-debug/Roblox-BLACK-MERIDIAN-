--!strict
-- BM-065: Verse catalog integrity, missing references, invalid cost data,
-- prerequisite cycles and compatibility. Test IDs only; not canon.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)
local Suite = require(ServerStorage.Tests.Support.Suite)
local VerseCatalog = require(ServerScriptService.Server.Content.VerseCatalog)

local suite = Suite.new("VerseCatalog")

local function registry(): ContentRegistry.Registry
	return ContentRegistry.build({
		chapters = {
			{ id = "chapter-t1", name = "Test Chapter", launchRequired = true, order = 1 },
		},
		regions = {
			{
				id = "region-ta",
				name = "Test Region",
				launchRequired = true,
				waymarkIds = { "waymark-ta1" },
				travelLinkIds = {},
			},
		},
		quests = {
			{
				id = "quest-t1",
				name = "Test Quest",
				launchRequired = true,
				chapterId = "chapter-t1",
				regionId = "region-ta",
			},
		},
		cants = {
			{
				id = "cant-ta",
				name = "Test Cant A",
				launchRequired = true,
				starterEligible = true,
				verseIds = { "verse-ta1", "verse-ta2" },
			},
			{
				id = "cant-tb",
				name = "Test Cant B",
				launchRequired = true,
				starterEligible = false,
				verseIds = {},
			},
			{
				id = "cant-tc",
				name = "Test Cant C",
				launchRequired = false,
				starterEligible = false,
				verseIds = { "verse-tc1" },
			},
		},
		verses = {
			{ id = "verse-ta1", name = "Test Verse A1", launchRequired = true, cantId = "cant-ta" },
			{ id = "verse-ta2", name = "Test Verse A2", launchRequired = true, cantId = "cant-ta" },
			{
				id = "verse-tc1",
				name = "Test Verse C1",
				launchRequired = false,
				cantId = "cant-tc",
			},
		},
		burdens = {},
		waymarks = {
			{
				id = "waymark-ta1",
				name = "Test Waymark",
				launchRequired = true,
				rank = 1,
				regionId = "region-ta",
			},
		},
		bosses = {},
		descents = {},
	})
end

local function defs(): { any }
	return {
		{
			id = "verse-ta1",
			cantId = "cant-ta",
			costs = { { pool = "stamina", amount = 20 } },
			castSteps = 6,
			cooldownSteps = 30,
			prerequisites = { verseIds = {} },
			mechanics = "canonical",
		},
		{
			id = "verse-ta2",
			cantId = "cant-ta",
			costs = { { pool = "stamina", amount = 30 }, { pool = "posture", amount = 10 } },
			castSteps = 12,
			cooldownSteps = 90,
			prerequisites = { verseIds = { "verse-ta1" }, waymarkId = "waymark-ta1" },
			mechanics = "provisional",
		},
		{
			id = "verse-tc1",
			cantId = "cant-tc",
			costs = {},
			castSteps = 0,
			cooldownSteps = 0,
			prerequisites = { verseIds = {}, questId = "quest-t1" },
			mechanics = "provisional",
		},
	}
end

local function expectProblem(data: unknown, needle: string)
	local problems = VerseCatalog.validate(data, registry())
	for _, p in problems do
		if string.find(p, needle, 1, true) then
			return
		end
	end
	error("expected a problem containing '" .. needle .. "', got: " .. table.concat(problems, "; "))
end

suite:case("the fixture catalog validates and builds", function()
	Assert.deepEqual(VerseCatalog.validate(defs(), registry()), {}, "no problems")
	local catalog = VerseCatalog.build(defs() :: any, registry())
	Assert.deepEqual(catalog:ids(), { "verse-ta1", "verse-ta2", "verse-tc1" }, "ids")
	Assert.deepEqual(catalog:forCant("cant-ta"), { "verse-ta1", "verse-ta2" }, "by Cant")
	Assert.deepEqual(catalog:forCant("cant-tb"), {}, "none")
end)

suite:case("the production catalog matches the canonical Verse list", function()
	local catalog = VerseCatalog.production()
	Assert.equal(#catalog:ids(), #Canon:ids("verse"), "one definition per canonical Verse")
end)

suite:case("undefined, fabricated and incompatible Verses are rejected", function()
	local catalog = VerseCatalog.build(defs() :: any, registry())
	for _, value: any in { "verse-fake", "", 3, {} } :: { any } do
		Assert.isNil(catalog:resolve(value), "rejected")
	end
	Assert.isTrue(catalog:isCompatible("verse-ta1", "cant-ta"), "compatible")
	Assert.isFalse(catalog:isCompatible("verse-ta1", "cant-tc"), "other Cant")
	Assert.isFalse(catalog:isCompatible("verse-fake", "cant-ta"), "unknown")
	local data = defs()
	data[1].id = "verse-invented"
	expectProblem(data, "verse-invented: not a canonical Verse ID")
	local wrongCant = defs()
	wrongCant[1].cantId = "cant-tc"
	expectProblem(wrongCant, "cantId must be cant-ta")
end)

suite:case("missing references are problems", function()
	local missing = defs()
	table.remove(missing, 3)
	expectProblem(missing, "verse-tc1: canonical Verse has no definition")
	local prereq = defs()
	prereq[2].prerequisites = { verseIds = { "verse-nope" } }
	expectProblem(prereq, "prerequisite verse-nope is not a canonical Verse")
	local foreign = defs()
	foreign[2].prerequisites = { verseIds = { "verse-tc1" } }
	expectProblem(foreign, "belongs to another Cant")
	local way = defs()
	way[2].prerequisites = { verseIds = {}, waymarkId = "waymark-nope" }
	expectProblem(way, "prerequisite waymark waymark-nope is not canonical")
	local quest = defs()
	quest[3].prerequisites = { verseIds = {}, questId = "quest-nope" }
	expectProblem(quest, "prerequisite quest quest-nope is not canonical")
	local selfReq = defs()
	selfReq[1].prerequisites = { verseIds = { "verse-ta1" } }
	expectProblem(selfReq, "cannot require itself")
	local cycle = defs()
	cycle[1].prerequisites = { verseIds = { "verse-ta2" } }
	expectProblem(cycle, "prerequisite cycle")
end)

suite:case("invalid cost and timing data are problems", function()
	local cases: { { field: string, value: any, needle: string } } = {
		{ field = "costs", value = { { pool = "mana", amount = 5 } }, needle = "each cost needs" },
		{
			field = "costs",
			value = { { pool = "stamina", amount = 0 } },
			needle = "each cost needs",
		},
		{
			field = "costs",
			value = { { pool = "stamina", amount = -5 } },
			needle = "each cost needs",
		},
		{
			field = "costs",
			value = { { pool = "stamina", amount = 0 / 0 } },
			needle = "each cost needs",
		},
		{
			field = "costs",
			value = { { pool = "stamina", amount = math.huge } },
			needle = "each cost needs",
		},
		{
			field = "costs",
			value = { { pool = "stamina", amount = 1001 } },
			needle = "each cost needs",
		},
		{
			field = "costs",
			value = { { pool = "stamina", amount = 1 }, { pool = "stamina", amount = 2 } },
			needle = "costed twice",
		},
		{ field = "costs", value = "free", needle = "costs must be a list" },
		{ field = "castSteps", value = 1.5, needle = "castSteps must be an integer" },
		{ field = "castSteps", value = -1, needle = "castSteps must be an integer" },
		{ field = "cooldownSteps", value = 10 ^ 9, needle = "cooldownSteps must be an integer" },
		{ field = "mechanics", value = "done", needle = "mechanics must be" },
		{ field = "damage", value = 50, needle = "unknown field damage" },
	}
	for _, c in cases do
		local data = defs()
		data[1][c.field] = c.value
		expectProblem(data, c.needle)
	end
	expectProblem("x", "definitions must be an array")
	Assert.throws(function()
		local data = defs()
		data[1].castSteps = -1
		VerseCatalog.build(data :: any, registry())
	end, "definitions are invalid")
end)

suite:case("prerequisites read only server facts", function()
	local catalog = VerseCatalog.build(defs() :: any, registry())
	local facts: VerseCatalog.Facts = { verses = {}, waymarks = {}, quests = {} }
	Assert.isTrue(catalog:prerequisitesMet("verse-ta1", facts), "no prerequisites")
	Assert.isFalse(catalog:prerequisitesMet("verse-ta2", facts), "needs verse and waymark")
	facts.verses["verse-ta1"] = true
	Assert.isFalse(catalog:prerequisitesMet("verse-ta2", facts), "still needs the waymark")
	facts.waymarks["waymark-ta1"] = true
	Assert.isTrue(catalog:prerequisitesMet("verse-ta2", facts), "met")
	Assert.isFalse(catalog:prerequisitesMet("verse-tc1", facts), "needs quest")
	Assert.isFalse(catalog:prerequisitesMet("verse-fake", facts), "unknown")
end)

return suite:cases()
