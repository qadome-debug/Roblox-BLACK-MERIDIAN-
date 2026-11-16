--!strict
-- Canonical Black Meridian content IDs.
--
-- Every entry here is an established item from the Black Meridian design
-- (the 22-part design report, as confirmed by the designer). Nothing is
-- invented to fill a gap: an item is added when the design names it AND
-- its machine ID is approved. See docs/content-registry.md for the ID
-- rules, docs/design-integration-checklist.md for the confirmed canon and
-- docs/id-proposals.md for established names whose IDs await approval
-- (Ash Quay, Lantern Vault, Lantern Maw, the Nearness Burdens).
--
-- Changing an ID is a breaking change for saved profiles and receipts. IDs
-- are never renamed or reused without a profile migration; a retired entry
-- keeps its ID with launchRequired = false.

local ContentRegistry = require(script.Parent.ContentRegistry)

local Content: ContentRegistry.ContentData = {
	chapters = {},

	regions = {},

	quests = {},

	-- The four launch Cants (IDs approved 2026-11-16). A Cant is a
	-- supernatural discipline; its Verses are the techniques. No Cant is
	-- owned at character creation: Nearness is acquired during the
	-- introductory story, so none is marked starter eligible.
	cants = {
		{
			id = "cant.nearness",
			name = "Nearness",
			launchRequired = true,
			starterEligible = false,
			verseIds = {
				"near.close_step",
				"near.draw_near",
				"near.between_us",
				"near.no_farther",
			},
		},
		{
			id = "cant.embers",
			name = "Embers",
			launchRequired = true,
			starterEligible = false,
			-- Verses are added when the design supplies them.
			verseIds = {},
		},
		{
			id = "cant.second_voice",
			name = "Second Voice",
			launchRequired = true,
			starterEligible = false,
			verseIds = {},
		},
		{
			id = "cant.still_water",
			name = "Still Water",
			launchRequired = true,
			starterEligible = false,
			verseIds = {},
		},
	},

	-- The four Nearness Verses (names and IDs approved 2026-11-16).
	verses = {
		{
			id = "near.close_step",
			name = "Close Step",
			launchRequired = true,
			cantId = "cant.nearness",
		},
		{
			id = "near.draw_near",
			name = "Draw Near",
			launchRequired = true,
			cantId = "cant.nearness",
		},
		{
			id = "near.between_us",
			name = "Between Us",
			launchRequired = true,
			cantId = "cant.nearness",
		},
		{
			id = "near.no_farther",
			name = "No Farther",
			launchRequired = true,
			cantId = "cant.nearness",
		},
	},

	-- Unwanted Company and Long Way Home are established Nearness Burdens.
	-- They are registered when their machine IDs are approved.
	burdens = {},

	waymarks = {
		{
			-- Legacy-style ID kept until the report's ID is approved.
			id = "waymark-i",
			name = "Waymark I — Branded",
			launchRequired = true,
			rank = 1,
			-- regionId is set when the first playable region's canonical name
			-- is in the inventory (BM-083).
		},
	},

	bosses = {},

	descents = {},
}

return Content
