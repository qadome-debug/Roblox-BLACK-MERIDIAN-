--!strict
-- BM-062: Cant catalog integrity, invalid references, unlock rules, slots
-- and loadout checks. Test IDs only; not canon.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local CantCatalog = require(ServerScriptService.Server.Content.CantCatalog)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("CantCatalog")

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
			id = "cant-ta",
			unlock = { kind = "starter" },
			slots = { "primary", "secondary" },
			exclusiveWith = {},
			verseIds = { "verse-ta2", "verse-ta1" },
			mechanics = "canonical",
		},
		{
			id = "cant-tb",
			unlock = { kind = "waymark", waymarkId = "waymark-ta1" },
			slots = { "secondary" },
			exclusiveWith = { "cant-tc" },
			verseIds = {},
			mechanics = "provisional",
		},
		{
			id = "cant-tc",
			unlock = { kind = "quest", questId = "quest-t1" },
			slots = { "primary", "secondary" },
			exclusiveWith = { "cant-tb" },
			verseIds = { "verse-tc1" },
			mechanics = "provisional",
		},
	}
end

local function expectProblem(data: unknown, needle: string)
	local problems = CantCatalog.validate(data, registry())
	for _, p in problems do
		if string.find(p, needle, 1, true) then
			return
		end
	end
	error("expected a problem containing '" .. needle .. "', got: " .. table.concat(problems, "; "))
end

local NONE: CantCatalog.Facts = { waymarks = {}, quests = {} }

suite:case("the fixture catalog validates and builds", function()
	Assert.deepEqual(CantCatalog.validate(defs(), registry()), {}, "no problems")
	local catalog = CantCatalog.build(defs() :: any, registry())
	Assert.deepEqual(catalog:ids(), { "cant-ta", "cant-tb", "cant-tc" }, "sorted ids")
	Assert.isTrue(table.isfrozen(catalog:get("cant-ta") :: any), "frozen")
end)

suite:case("the production catalog covers every canonical Cant", function()
	local catalog = CantCatalog.production()
	for _, id in Canon:ids("cant") do
		Assert.notNil(catalog:get(id), id .. " defined")
	end
	Assert.equal(#catalog:ids(), #Canon:ids("cant"), "nothing extra")
	Assert.notNil(catalog:get("cant-nearness"), "Nearness defined")
	Assert.isTrue(catalog:isUnlocked("cant-nearness", NONE), "Nearness is a starter Cant")
end)

suite:case("unknown and fabricated Cant IDs are rejected", function()
	local catalog = CantCatalog.build(defs() :: any, registry())
	for _, value: any in
		{ "cant-fake", "cant-nearness", "", 42, false, {} :: any, "CANT-TA" } :: { any }
	do
		Assert.isNil(catalog:resolve(value), "rejected " .. tostring(value))
	end
	Assert.equal(catalog:resolve("cant-ta"), "cant-ta", "known")
	local data = defs()
	data[1].id = "cant-invented"
	expectProblem(data, "cant-invented: not a canonical Cant ID")
end)

suite:case("a missing or duplicate definition is a problem", function()
	local data = defs()
	table.remove(data, 3)
	data[2].exclusiveWith = {}
	expectProblem(data, "cant-tc: canonical Cant has no definition")
	local dup = defs()
	table.insert(dup, table.clone(dup[1]))
	expectProblem(dup, "cant-ta: defined more than once")
end)

suite:case("invalid Verse references are problems", function()
	local unknown = defs()
	unknown[1].verseIds = { "verse-ta1", "verse-nope" }
	expectProblem(unknown, "verse verse-nope is not a canonical Verse")
	local foreign = defs()
	foreign[1].verseIds = { "verse-ta1", "verse-ta2", "verse-tc1" }
	expectProblem(foreign, "verse verse-tc1 belongs to cant-tc")
	local missing = defs()
	missing[1].verseIds = { "verse-ta1" }
	expectProblem(missing, "verseIds differ from the registry")
end)

suite:case("invalid unlock rules are problems", function()
	local bad = defs()
	bad[2].unlock = { kind = "waymark", waymarkId = "waymark-nope" }
	expectProblem(bad, "is not a canonical waymark")
	local kind = defs()
	kind[2].unlock = { kind = "purchase" }
	expectProblem(kind, "unknown unlock kind purchase")
	local extra = defs()
	extra[3].unlock = { kind = "quest", questId = "quest-t1", bonus = true }
	expectProblem(extra, "unknown unlock field bonus")
	local starter = defs()
	starter[1].unlock = { kind = "quest", questId = "quest-t1" }
	expectProblem(starter, "starter eligible but unlock is not starter")
	local notStarter = defs()
	notStarter[2].unlock = { kind = "starter" }
	expectProblem(notStarter, "does not mark it starter eligible")
end)

suite:case("invalid slots, exclusions and fields are problems", function()
	local slots = defs()
	slots[1].slots = { "tertiary" }
	expectProblem(slots, "unknown slot tertiary")
	local empty = defs()
	empty[1].slots = {}
	expectProblem(empty, "slots must be a non-empty list")
	local twice = defs()
	twice[1].slots = { "primary", "primary" }
	expectProblem(twice, "slot primary listed twice")
	local selfEx = defs()
	selfEx[1].exclusiveWith = { "cant-ta" }
	expectProblem(selfEx, "cannot exclude itself")
	local oneWay = defs()
	oneWay[3].exclusiveWith = {}
	expectProblem(oneWay, "excludes cant-tc but not the other way round")
	local field = defs()
	field[1].damage = 500
	expectProblem(field, "unknown field damage")
	local mech = defs()
	mech[1].mechanics = "final"
	expectProblem(mech, "mechanics must be canonical or provisional")
	expectProblem("nope", "definitions must be an array")
end)

suite:case("build refuses an invalid catalog", function()
	local data = defs()
	data[1].slots = {}
	Assert.throws(function()
		CantCatalog.build(data :: any, registry())
	end, "definitions are invalid")
end)

suite:case("unlock rules read only server facts", function()
	local catalog = CantCatalog.build(defs() :: any, registry())
	Assert.deepEqual(catalog:unlocked(NONE), { "cant-ta" }, "starter only")
	local facts: CantCatalog.Facts = { waymarks = { ["waymark-ta1"] = true }, quests = {} }
	Assert.deepEqual(catalog:unlocked(facts), { "cant-ta", "cant-tb" }, "waymark unlocks B")
	facts.quests["quest-t1"] = true
	Assert.isTrue(catalog:isUnlocked("cant-tc", facts), "quest unlocks C")
	Assert.isFalse(catalog:isUnlocked("cant-fake", facts), "unknown never unlocked")
end)

suite:case("loadouts respect slots, unlocks, duplicates and exclusions", function()
	local catalog = CantCatalog.build(defs() :: any, registry())
	local all: CantCatalog.Facts =
		{ waymarks = { ["waymark-ta1"] = true }, quests = { ["quest-t1"] = true } }
	local function check(loadout: any, facts: CantCatalog.Facts): string?
		local ok, reason = catalog:checkLoadout(loadout, facts)
		return if ok then nil else reason
	end
	Assert.isNil(check({ primary = "cant-ta", secondary = "cant-tb" }, all), "legal")
	Assert.isNil(check({}, all), "empty loadout is legal")
	Assert.equal(check({ primary = "cant-tb" }, all), "cant not allowed in slot", "slot")
	Assert.equal(check({ secondary = "cant-tb" }, NONE), "cant not unlocked", "locked")
	Assert.equal(check({ primary = "cant-fake" }, all), "unknown cant", "forged")
	Assert.equal(check({ third = "cant-ta" }, all), "unknown slot", "slot name")
	Assert.equal(
		check({ primary = "cant-ta", secondary = "cant-ta" }, all),
		"cant equipped twice",
		"duplicate"
	)
	Assert.equal(
		check({ primary = "cant-tc", secondary = "cant-tb" }, all),
		"cants are exclusive",
		"exclusive"
	)
	Assert.isTrue(catalog:isVerseCompatible("cant-ta", "verse-ta1"), "compatible")
	Assert.isFalse(catalog:isVerseCompatible("cant-ta", "verse-tc1"), "incompatible")
	Assert.isFalse(catalog:isVerseCompatible("cant-fake", "verse-ta1"), "unknown cant")
end)

return suite:cases()
