--!strict
-- Shared numeric limits from Technical Plan 2.0 (sections 3.4, 3.7, 4.2,
-- 5.1). These are design budgets; changing one is a reviewed change to the
-- plan, and any limit that turns out too small is raised with measured
-- evidence, never worked around by truncating data.

export type RateLimit = { perSecond: number, burst: number, maxPayloadBytes: number }

local function rate(perSecond: number, burst: number, maxPayloadBytes: number): RateLimit
	return table.freeze({ perSecond = perSecond, burst = burst, maxPayloadBytes = maxPayloadBytes })
end

local Limits = table.freeze({
	-- Identifiers (3.4).
	MAX_CANONICAL_ID_BYTES = 48, -- content IDs: regions, quests, Cants, ...
	MAX_OPAQUE_ID_BYTES = 64, -- server-issued offer and ticket IDs
	MAX_REQUEST_ID_BYTES = 64, -- client-generated request IDs
	MAX_CONTENT_NAME_BYTES = 64,
	MAX_REVISION = 2147483647,

	-- Request envelope (3.2, 3.7).
	MAX_PAYLOAD_DEPTH = 4,
	MAX_PAYLOAD_FIELDS = 32,
	MAX_PAYLOAD_ARRAY_ITEMS = 64,
	MAX_STRING_BYTES = 256,

	-- Rate and payload budgets by action class (3.7).
	RATE = table.freeze({
		combat = rate(15, 20, 256),
		cant = rate(5, 8, 512),
		choice = rate(2, 4, 512), -- quest and Burden choices
		waymark = rate(2, 4, 512), -- Waymark and collectible actions
		party = rate(3, 6, 512), -- party and travel actions
		economy = rate(2, 4, 512), -- crafting and purchases
		session = rate(1, 3, 256), -- ClientHello, settings
		envelope = rate(30, 40, 1024), -- overall per-player budget
	}),

	-- Replay protection (3.6).
	DUPLICATE_RESULT_CACHE_SECONDS = 600,

	-- Profile schema bounds (4.2).
	PROFILE = table.freeze({
		MAX_ACTIVE_QUESTS = 12,
		MAX_COMPLETED_QUESTS = 512,
		MAX_FLAGS_PER_QUEST = 16,
		MAX_CHOICES_PER_QUEST = 8,
		MAX_UNLOCKED_CANTS = 32,
		MAX_VERSE_UNLOCKS = 128,
		MAX_DISCOVERED_BURDENS = 64,
		MAX_ACTIVE_BURDENS = 8,
		MAX_WAYMARKS = 128,
		MAX_INVENTORY_STACKS = 200,
		MAX_BALANCE_TYPES = 16,
		MAX_DESCENT_ENTRIES = 64,
		MAX_PERMANENT_RECEIPTS = 1024,
		MAX_SEASONAL_RECEIPTS = 512,
		MAX_PENDING_INTENTS = 32,
		SOFT_SIZE_BYTES = 128 * 1024,
		HARD_SIZE_BYTES = 192 * 1024,
	}),

	-- Session leases (5.1).
	LEASE = table.freeze({
		LIFETIME_SECONDS = 90,
		RENEWAL_INTERVAL_SECONDS = 30,
	}),
})

return Limits
