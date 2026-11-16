--!strict
-- Shared content fixtures: a small, consistent test registry with Cant and
-- Verse catalogs over it. Test IDs only; not canon.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CantCatalog = require(ServerScriptService.Server.Content.CantCatalog)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)
local VerseCatalog = require(ServerScriptService.Server.Content.VerseCatalog)

local ContentFixtures = {}

function ContentFixtures.registry(): ContentRegistry.Registry
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

function ContentFixtures.cantDefs(): { any }
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

function ContentFixtures.verseDefs(): { any }
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

function ContentFixtures.catalogs(): (CantCatalog.Catalog, VerseCatalog.Catalog)
	local registry = ContentFixtures.registry()
	return CantCatalog.build(ContentFixtures.cantDefs() :: any, registry),
		VerseCatalog.build(ContentFixtures.verseDefs() :: any, registry)
end

return ContentFixtures
