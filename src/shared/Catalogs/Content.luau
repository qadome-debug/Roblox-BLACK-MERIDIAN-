--!strict
-- Canonical Black Meridian content IDs.
--
-- Every entry here is an established item from the Black Meridian design.
-- Nothing is invented to fill a gap: when the design names an item, it is
-- added here with its canonical ID; until then the list stays short. See
-- docs/content-registry.md for the ID rules and docs/task-log.md for the
-- inventory still to be supplied.
--
-- Changing an ID is a breaking change for saved profiles and receipts. IDs
-- are never renamed or reused; a retired entry keeps its ID with
-- launchRequired = false.

local ContentRegistry = require(script.Parent.ContentRegistry)

local Content: ContentRegistry.ContentData = {
	chapters = {},

	regions = {},

	quests = {},

	cants = {
		{
			id = "cant-nearness",
			name = "Nearness",
			launchRequired = true,
			starterEligible = true,
			-- The Nearness Verses required by the vertical slice are added by
			-- BM-066 once their canonical names are in the inventory.
			verseIds = {},
		},
	},

	verses = {},

	burdens = {},

	waymarks = {
		{
			id = "waymark-i",
			name = "Waymark I",
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
