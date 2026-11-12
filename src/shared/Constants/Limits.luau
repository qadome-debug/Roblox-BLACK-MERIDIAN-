--!strict
-- Shared numeric limits from Technical Plan 2.0. Sections 3.4, 3.7, 4.2.
-- These are design budgets; changing one is a reviewed change to the plan.

local Limits = table.freeze({
	-- Canonical content IDs (regions, quests, Cants, Verses, ...).
	MAX_CANONICAL_ID_BYTES = 48,
	-- Server-issued opaque IDs (offers, tickets).
	MAX_OPAQUE_ID_BYTES = 64,
	-- Human-readable display names in catalogs.
	MAX_CONTENT_NAME_BYTES = 64,
})

return Limits
