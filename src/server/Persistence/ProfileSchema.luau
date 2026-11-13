--!strict
-- Profile schema: defaults and catalog-backed validation (BM-021, BM-022).
--
-- `ProfileSchema.default()` builds a fresh profile at the current schema
-- version. `ProfileSchema.validate(value)` checks an untrusted value (a
-- loaded DataStore record, or a candidate about to be saved) against the
-- structural types in shared/Types/Profile AND the runtime bounds in
-- Limits.PROFILE AND the canonical registry: every quest, Cant, Verse,
-- Burden and Waymark key must be a known ID. A profile that fails here is
-- never served and never saved.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)

type PlayerProfile = Profile.PlayerProfile

local P = Limits.PROFILE
local MAX_OPAQUE = Limits.MAX_OPAQUE_ID_BYTES
local MAX_BALANCE = 2 ^ 53
local MAX_QUANTITY = 2 ^ 31 - 1
local MAX_DISSONANCE = 1000

local ProfileSchema = {}

function ProfileSchema.default(): PlayerProfile
	return {
		schemaVersion = Profile.SCHEMA_VERSION,
		revision = 0,
		lease = nil,
		chapterId = "",
		quests = { active = {}, completed = {} },
		cants = { unlocked = {}, equipped = nil, verses = {} },
		burdens = { discovered = {}, active = {}, dissonance = 0 },
		waymarks = {},
		inventory = {},
		balances = {},
		descents = { unlockedTiers = {}, bestClears = {} },
		receipts = { permanent = {}, seasonal = {}, pending = {} },
	}
end

-- Validation helpers -------------------------------------------------------

type Ctx = { errors: { string } }

local function fail(ctx: Ctx, path: string, message: string)
	table.insert(ctx.errors, path .. ": " .. message)
end

local function isInt(value: unknown, min: number, max: number): boolean
	return type(value) == "number"
		and value == value
		and value >= min
		and value <= max
		and value % 1 == 0
end

local function isFiniteNumber(value: unknown, min: number, max: number): boolean
	return type(value) == "number" and value == value and value >= min and value <= max
end

local function isOpaque(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= MAX_OPAQUE
		and string.match(value, "^[%w%-_:.]+$") ~= nil
end

local function expectTable(ctx: Ctx, path: string, value: unknown): { [any]: unknown }?
	if type(value) ~= "table" then
		fail(ctx, path, "must be a table, got " .. typeof(value))
		return nil
	end
	return value :: { [any]: unknown }
end

-- Exact-key check: nothing beyond `allowed` may be present.
local function expectKeys(
	ctx: Ctx,
	path: string,
	t: { [any]: unknown },
	allowed: { [string]: boolean }
)
	for key in t do
		if type(key) ~= "string" or not allowed[key] then
			fail(ctx, path, "unexpected field " .. tostring(key))
		end
	end
end

local function countKeys(t: { [any]: unknown }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function isArray(t: { [any]: unknown }): boolean
	return countKeys(t) == #t
end

-- A map keyed by canonical IDs of `category`, bounded by `max` entries,
-- with `checkValue` applied to each value.
local function expectIdMap(
	ctx: Ctx,
	path: string,
	value: unknown,
	category: ContentRegistry.Category,
	max: number,
	checkValue: (path: string, value: unknown) -> ()
)
	local t = expectTable(ctx, path, value)
	if t == nil then
		return
	end
	if countKeys(t) > max then
		fail(ctx, path, "more than " .. max .. " entries")
	end
	for key, item in t do
		if Canon:resolve(category, key) == nil then
			fail(ctx, path, "unknown " .. category .. " id " .. tostring(key))
		else
			checkValue(path .. "." .. (key :: string), item)
		end
	end
end

local function expectTrue(path: string, value: unknown, ctx: Ctx)
	if value ~= true then
		fail(ctx, path, "must be true")
	end
end

-- Sections -----------------------------------------------------------------

local QUEST_STATUS = { Locked = true, Active = true, Completed = true, Failed = true }

local function validateQuests(ctx: Ctx, value: unknown)
	local quests = expectTable(ctx, "quests", value)
	if quests == nil then
		return
	end
	expectKeys(ctx, "quests", quests, { active = true, completed = true })

	expectIdMap(
		ctx,
		"quests.active",
		quests.active,
		"quest",
		P.MAX_ACTIVE_QUESTS,
		function(path, item)
			local progress = expectTable(ctx, path, item)
			if progress == nil then
				return
			end
			expectKeys(ctx, path, progress, {
				questId = true,
				nodeId = true,
				status = true,
				revision = true,
				flags = true,
				choices = true,
			})
			local questId = string.match(path, "([^%.]+)$")
			if progress.questId ~= questId then
				fail(ctx, path, "questId does not match its key")
			end
			if not ContentRegistry.isValidId(progress.nodeId) then
				fail(ctx, path, "nodeId is not a canonical id")
			end
			if type(progress.status) ~= "string" or not QUEST_STATUS[progress.status :: string] then
				fail(ctx, path, "invalid status")
			end
			if not isInt(progress.revision, 0, Limits.MAX_REVISION) then
				fail(ctx, path, "invalid revision")
			end
			local flags = expectTable(ctx, path .. ".flags", progress.flags)
			if flags ~= nil then
				if countKeys(flags) > P.MAX_FLAGS_PER_QUEST then
					fail(ctx, path .. ".flags", "more than " .. P.MAX_FLAGS_PER_QUEST .. " flags")
				end
				for key, flag in flags do
					if not ContentRegistry.isValidId(key) or type(flag) ~= "boolean" then
						fail(ctx, path .. ".flags", "flags must map canonical ids to booleans")
					end
				end
			end
			local choices = expectTable(ctx, path .. ".choices", progress.choices)
			if choices ~= nil then
				if countKeys(choices) > P.MAX_CHOICES_PER_QUEST then
					fail(
						ctx,
						path .. ".choices",
						"more than " .. P.MAX_CHOICES_PER_QUEST .. " choices"
					)
				end
				for key, choice in choices do
					if
						not ContentRegistry.isValidId(key) or not ContentRegistry.isValidId(choice)
					then
						fail(
							ctx,
							path .. ".choices",
							"choices must map canonical node ids to canonical choice ids"
						)
					end
				end
			end
		end
	)

	expectIdMap(
		ctx,
		"quests.completed",
		quests.completed,
		"quest",
		P.MAX_COMPLETED_QUESTS,
		function(path, item)
			expectTrue(path, item, ctx)
		end
	)
end

local function validateCants(ctx: Ctx, value: unknown)
	local cants = expectTable(ctx, "cants", value)
	if cants == nil then
		return
	end
	expectKeys(ctx, "cants", cants, { unlocked = true, equipped = true, verses = true })
	expectIdMap(
		ctx,
		"cants.unlocked",
		cants.unlocked,
		"cant",
		P.MAX_UNLOCKED_CANTS,
		function(path, item)
			expectTrue(path, item, ctx)
		end
	)
	if cants.equipped ~= nil then
		if Canon:resolve("cant", cants.equipped) == nil then
			fail(ctx, "cants.equipped", "unknown cant id " .. tostring(cants.equipped))
		elseif
			type(cants.unlocked) == "table"
			and (cants.unlocked :: { [string]: unknown })[cants.equipped :: string] ~= true
		then
			fail(ctx, "cants.equipped", "equipped cant is not unlocked")
		end
	end
	local total = 0
	expectIdMap(
		ctx,
		"cants.verses",
		cants.verses,
		"cant",
		P.MAX_UNLOCKED_CANTS,
		function(path, item)
			local cantId = string.match(path, "([^%.]+)$") :: string
			local t = expectTable(ctx, path, item)
			if t == nil then
				return
			end
			for verseId, flag in t do
				total += 1
				local verse = if type(verseId) == "string" then Canon:getVerse(verseId) else nil
				if verse == nil then
					fail(ctx, path, "unknown verse id " .. tostring(verseId))
				elseif verse.cantId ~= cantId then
					fail(
						ctx,
						path,
						"verse " .. (verseId :: string) .. " does not belong to " .. cantId
					)
				end
				if flag ~= true then
					fail(ctx, path, "verse flags must be true")
				end
			end
		end
	)
	if total > P.MAX_VERSE_UNLOCKS then
		fail(ctx, "cants.verses", "more than " .. P.MAX_VERSE_UNLOCKS .. " verse unlocks")
	end
end

local function validateBurdens(ctx: Ctx, value: unknown)
	local burdens = expectTable(ctx, "burdens", value)
	if burdens == nil then
		return
	end
	expectKeys(ctx, "burdens", burdens, { discovered = true, active = true, dissonance = true })
	expectIdMap(
		ctx,
		"burdens.discovered",
		burdens.discovered,
		"burden",
		P.MAX_DISCOVERED_BURDENS,
		function(path, item)
			expectTrue(path, item, ctx)
		end
	)
	local active = expectTable(ctx, "burdens.active", burdens.active)
	if active ~= nil then
		if not isArray(active) then
			fail(ctx, "burdens.active", "must be an array")
		elseif #active > P.MAX_ACTIVE_BURDENS then
			fail(ctx, "burdens.active", "more than " .. P.MAX_ACTIVE_BURDENS .. " active burdens")
		end
		local seen: { [string]: boolean } = {}
		for _, id in ipairs(active :: { unknown }) do
			if Canon:resolve("burden", id) == nil then
				fail(ctx, "burdens.active", "unknown burden id " .. tostring(id))
			elseif seen[id :: string] then
				fail(ctx, "burdens.active", "duplicate burden " .. (id :: string))
			else
				seen[id :: string] = true
				if
					type(burdens.discovered) == "table"
					and (burdens.discovered :: { [string]: unknown })[id :: string] ~= true
				then
					fail(
						ctx,
						"burdens.active",
						"active burden " .. (id :: string) .. " was never discovered"
					)
				end
			end
		end
	end
	if not isFiniteNumber(burdens.dissonance, 0, MAX_DISSONANCE) then
		fail(ctx, "burdens.dissonance", "must be a number in [0, " .. MAX_DISSONANCE .. "]")
	end
end

local function validateWaymarks(ctx: Ctx, value: unknown)
	expectIdMap(ctx, "waymarks", value, "waymark", P.MAX_WAYMARKS, function(path, item)
		local t = expectTable(ctx, path, item)
		if t == nil then
			return
		end
		expectKeys(ctx, path, t, { activated = true, rank = true })
		if type(t.activated) ~= "boolean" then
			fail(ctx, path, "activated must be a boolean")
		end
		if not isInt(t.rank, 0, 100) then
			fail(ctx, path, "rank must be an integer in [0, 100]")
		end
	end)
end

local function validateInventory(ctx: Ctx, value: unknown)
	local inventory = expectTable(ctx, "inventory", value)
	if inventory == nil then
		return
	end
	if not isArray(inventory) then
		fail(ctx, "inventory", "must be an array")
		return
	end
	if #inventory > P.MAX_INVENTORY_STACKS then
		fail(ctx, "inventory", "more than " .. P.MAX_INVENTORY_STACKS .. " stacks")
	end
	local instances: { [string]: boolean } = {}
	for i, item in ipairs(inventory :: { unknown }) do
		local path = "inventory[" .. i .. "]"
		local stack = expectTable(ctx, path, item)
		if stack == nil then
			continue
		end
		expectKeys(ctx, path, stack, { itemId = true, quantity = true, instanceId = true })
		if not ContentRegistry.isValidId(stack.itemId) then
			fail(ctx, path, "itemId is not a canonical id")
		end
		if not isInt(stack.quantity, 1, MAX_QUANTITY) then
			fail(ctx, path, "quantity must be a positive integer")
		end
		if stack.instanceId ~= nil then
			if not isOpaque(stack.instanceId) then
				fail(ctx, path, "instanceId is not a valid opaque id")
			elseif instances[stack.instanceId :: string] then
				fail(ctx, path, "duplicate instanceId " .. (stack.instanceId :: string))
			else
				instances[stack.instanceId :: string] = true
				if stack.quantity ~= 1 then
					fail(ctx, path, "an item instance has quantity 1")
				end
			end
		end
	end
end

local function validateBalances(ctx: Ctx, value: unknown)
	local balances = expectTable(ctx, "balances", value)
	if balances == nil then
		return
	end
	if countKeys(balances) > P.MAX_BALANCE_TYPES then
		fail(ctx, "balances", "more than " .. P.MAX_BALANCE_TYPES .. " balance types")
	end
	for key, amount in balances do
		if not ContentRegistry.isValidId(key) then
			fail(ctx, "balances", "currency id " .. tostring(key) .. " is not canonical")
		end
		if not isInt(amount, 0, MAX_BALANCE) then
			fail(ctx, "balances." .. tostring(key), "must be a nonnegative integer")
		end
	end
end

local function validateDescents(ctx: Ctx, value: unknown)
	local descents = expectTable(ctx, "descents", value)
	if descents == nil then
		return
	end
	expectKeys(ctx, "descents", descents, { unlockedTiers = true, bestClears = true })
	local total = 0
	for _, field in { "unlockedTiers", "bestClears" } do
		expectIdMap(
			ctx,
			"descents." .. field,
			descents[field],
			"descent",
			P.MAX_DESCENT_ENTRIES,
			function(path, item)
				total += 1
				if not isInt(item, 0, 1000) then
					fail(ctx, path, "must be an integer in [0, 1000]")
				end
			end
		)
	end
	if total > P.MAX_DESCENT_ENTRIES then
		fail(ctx, "descents", "more than " .. P.MAX_DESCENT_ENTRIES .. " entries")
	end
end

local function validateReceipts(ctx: Ctx, value: unknown)
	local receipts = expectTable(ctx, "receipts", value)
	if receipts == nil then
		return
	end
	expectKeys(ctx, "receipts", receipts, { permanent = true, seasonal = true, pending = true })

	local permanent = expectTable(ctx, "receipts.permanent", receipts.permanent)
	if permanent ~= nil then
		if countKeys(permanent) > P.MAX_PERMANENT_RECEIPTS then
			fail(ctx, "receipts.permanent", "more than " .. P.MAX_PERMANENT_RECEIPTS .. " receipts")
		end
		for key, flag in permanent do
			if not isOpaque(key) or flag ~= true then
				fail(ctx, "receipts.permanent", "must map receipt ids to true")
			end
		end
	end

	local seasonal = expectTable(ctx, "receipts.seasonal", receipts.seasonal)
	if seasonal ~= nil then
		if countKeys(seasonal) > P.MAX_SEASONAL_RECEIPTS then
			fail(ctx, "receipts.seasonal", "more than " .. P.MAX_SEASONAL_RECEIPTS .. " receipts")
		end
		for key, season in seasonal do
			if not isOpaque(key) or not isInt(season, 0, 100000) then
				fail(ctx, "receipts.seasonal", "must map receipt ids to season numbers")
			end
		end
	end

	local pending = expectTable(ctx, "receipts.pending", receipts.pending)
	if pending ~= nil then
		if countKeys(pending) > P.MAX_PENDING_INTENTS then
			fail(
				ctx,
				"receipts.pending",
				"more than " .. P.MAX_PENDING_INTENTS .. " pending intents"
			)
		end
		for key, intent in pending do
			local path = "receipts.pending." .. tostring(key)
			if not isOpaque(key) then
				fail(ctx, path, "intent key is not a valid opaque id")
			end
			local t = expectTable(ctx, path, intent)
			if t == nil then
				continue
			end
			expectKeys(
				ctx,
				path,
				t,
				{ grantId = true, sourceId = true, createdAt = true, rewardCatalogId = true }
			)
			if t.grantId ~= key then
				fail(ctx, path, "grantId does not match its key")
			end
			if not isOpaque(t.sourceId) then
				fail(ctx, path, "sourceId is not a valid opaque id")
			end
			if not isFiniteNumber(t.createdAt, 0, 2 ^ 40) then
				fail(ctx, path, "createdAt must be a Unix timestamp")
			end
			if not ContentRegistry.isValidId(t.rewardCatalogId) then
				fail(ctx, path, "rewardCatalogId is not a canonical id")
			end
		end
	end
end

local function validateLease(ctx: Ctx, value: unknown)
	if value == nil then
		return
	end
	local lease = expectTable(ctx, "lease", value)
	if lease == nil then
		return
	end
	expectKeys(
		ctx,
		"lease",
		lease,
		{ sessionId = true, jobId = true, fence = true, expiresAt = true }
	)
	if not isOpaque(lease.sessionId) then
		fail(ctx, "lease", "sessionId is not a valid opaque id")
	end
	if type(lease.jobId) ~= "string" or #(lease.jobId :: string) > MAX_OPAQUE then
		fail(ctx, "lease", "jobId must be a short string")
	end
	if not isInt(lease.fence, 0, 2 ^ 50) then
		fail(ctx, "lease", "fence must be a nonnegative integer")
	end
	if not isFiniteNumber(lease.expiresAt, 0, 2 ^ 40) then
		fail(ctx, "lease", "expiresAt must be a Unix timestamp")
	end
end

local TOP_LEVEL = {
	schemaVersion = true,
	revision = true,
	lease = true,
	chapterId = true,
	quests = true,
	cants = true,
	burdens = true,
	waymarks = true,
	inventory = true,
	balances = true,
	descents = true,
	receipts = true,
}

-- Returns every problem found. An empty list means `value` is a valid
-- PlayerProfile at the current schema version.
function ProfileSchema.validate(value: unknown): { string }
	local ctx: Ctx = { errors = {} }
	local profile = expectTable(ctx, "profile", value)
	if profile == nil then
		return ctx.errors
	end
	expectKeys(ctx, "profile", profile, TOP_LEVEL)

	if profile.schemaVersion ~= Profile.SCHEMA_VERSION then
		fail(
			ctx,
			"schemaVersion",
			"expected " .. Profile.SCHEMA_VERSION .. ", got " .. tostring(profile.schemaVersion)
		)
	end
	if not isInt(profile.revision, 0, 2 ^ 50) then
		fail(ctx, "revision", "must be a nonnegative integer")
	end
	if profile.chapterId ~= "" and Canon:resolve("chapter", profile.chapterId) == nil then
		fail(ctx, "chapterId", "unknown chapter id " .. tostring(profile.chapterId))
	end

	validateLease(ctx, profile.lease)
	validateQuests(ctx, profile.quests)
	validateCants(ctx, profile.cants)
	validateBurdens(ctx, profile.burdens)
	validateWaymarks(ctx, profile.waymarks)
	validateInventory(ctx, profile.inventory)
	validateBalances(ctx, profile.balances)
	validateDescents(ctx, profile.descents)
	validateReceipts(ctx, profile.receipts)

	return ctx.errors
end

function ProfileSchema.isValid(value: unknown): boolean
	return #ProfileSchema.validate(value) == 0
end

return table.freeze(ProfileSchema)
