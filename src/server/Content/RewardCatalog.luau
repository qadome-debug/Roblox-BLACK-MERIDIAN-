--!strict
-- Authoritative reward catalog and receipt ID rules (BM-035).
--
-- Every grant the game can make is a catalog entry checked in here. A
-- grant request names an entry by ID; nothing at runtime, and nothing from
-- a client, defines what a reward contains. Receipt IDs are derived
-- deterministically from the authoritative source (which quest, which
-- Waymark, which run) and the reward entry, so the same event always maps
-- to the same receipt and can never pay twice.
--
-- Receipt ID formats:
--   permanent  p:<sourceKind>:<sourceId>:<rewardId>
--   seasonal   s:<season>:<runId>:<slot>:<rewardId>
-- Both stay under Limits.MAX_OPAQUE_ID_BYTES; `receiptId` refuses inputs
-- that would not.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)

export type Kind = "permanent" | "repeatable"

export type SourceKind =
	"quest"
	| "waymark"
	| "boss"
	| "chapter"
	| "descent"
	| "collectible"
	| "event"

export type Grants = {
	currencies: { [string]: number }?,
	items: { { itemId: string, quantity: number } }?,
	-- Instanced equipment; one instance per entry, ID issued by the server.
	instances: { string }?,
	cants: { string }?,
	verses: { string }?,
	waymarks: { string }?,
}

export type Definition = {
	id: string,
	kind: Kind,
	-- Which source kinds may issue this reward.
	sources: { SourceKind },
	grants: Grants,
}

export type Catalog = {
	get: (self: Catalog, id: string) -> Definition?,
	ids: (self: Catalog) -> { string },
}

local SOURCE_KINDS: { [string]: boolean } = {
	quest = true,
	waymark = true,
	boss = true,
	chapter = true,
	descent = true,
	collectible = true,
	event = true,
}

local UNLOCK_FIELDS: { [string]: string } =
	{ cants = "cant", verses = "verse", waymarks = "waymark" }

local MAX_GRANT_ENTRIES = 16
local MAX_CURRENCY_AMOUNT = 100_000
local MAX_ITEM_QUANTITY = 999

local RewardCatalog = {}

local function describe(value: unknown): string
	return if type(value) == "string" then string.format("%q", value) else typeof(value)
end

local function isPositiveInt(value: unknown, max: number): boolean
	return type(value) == "number"
		and value == value
		and value >= 1
		and value <= max
		and value % 1 == 0
end

local function countKeys(t: { [any]: unknown }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- Validates a list of definitions. Returns problems; empty means valid.
function RewardCatalog.validate(definitions: unknown): { string }
	local errors: { string } = {}
	local function fail(message: string)
		table.insert(errors, message)
	end
	if type(definitions) ~= "table" then
		fail("catalog must be a table")
		return errors
	end
	local seen: { [string]: boolean } = {}
	for i, raw in ipairs(definitions :: { unknown }) do
		local where = string.format("rewards[%d]", i)
		if type(raw) ~= "table" then
			fail(where .. " must be a table")
			continue
		end
		local def = raw :: { [string]: unknown }
		for key in def do
			if key ~= "id" and key ~= "kind" and key ~= "sources" and key ~= "grants" then
				fail(where .. ": unknown field " .. describe(key))
			end
		end
		local id = def.id
		if not ContentRegistry.isValidId(id) or string.sub(id :: string, 1, 7) ~= "reward-" then
			fail(
				where .. ": id must be a canonical id starting with 'reward-', got " .. describe(id)
			)
		else
			where = where .. " (" .. (id :: string) .. ")"
			if seen[id :: string] then
				fail(where .. ": duplicate id")
			end
			seen[id :: string] = true
		end
		if def.kind ~= "permanent" and def.kind ~= "repeatable" then
			fail(where .. ": kind must be permanent or repeatable")
		end
		local sources = def.sources
		if type(sources) ~= "table" or #(sources :: { unknown }) == 0 then
			fail(where .. ": sources must be a non-empty array")
		else
			for _, source in ipairs(sources :: { unknown }) do
				if type(source) ~= "string" or not SOURCE_KINDS[source] then
					fail(where .. ": unknown source kind " .. describe(source))
				end
			end
		end
		local grants = def.grants
		if type(grants) ~= "table" then
			fail(where .. ": grants must be a table")
			continue
		end
		local g = grants :: { [string]: unknown }
		local entries = 0
		for key in g do
			if
				key ~= "currencies"
				and key ~= "items"
				and key ~= "instances"
				and key ~= "cants"
				and key ~= "verses"
				and key ~= "waymarks"
			then
				fail(where .. ": unknown grant field " .. describe(key))
			end
		end
		if g.currencies ~= nil then
			if type(g.currencies) ~= "table" then
				fail(where .. ": currencies must be a map")
			else
				for currency, amount in g.currencies :: { [any]: unknown } do
					entries += 1
					if not ContentRegistry.isValidId(currency) then
						fail(where .. ": bad currency id " .. describe(currency))
					end
					if not isPositiveInt(amount, MAX_CURRENCY_AMOUNT) then
						fail(
							where
								.. ": currency amount must be an integer in [1, "
								.. MAX_CURRENCY_AMOUNT
								.. "]"
						)
					end
				end
			end
		end
		if g.items ~= nil then
			if type(g.items) ~= "table" then
				fail(where .. ": items must be an array")
			else
				for _, item in ipairs(g.items :: { unknown }) do
					entries += 1
					if type(item) ~= "table" then
						fail(where .. ": item entry must be a table")
					else
						local it = item :: { [string]: unknown }
						if not ContentRegistry.isValidId(it.itemId) then
							fail(where .. ": bad itemId " .. describe(it.itemId))
						end
						if not isPositiveInt(it.quantity, MAX_ITEM_QUANTITY) then
							fail(
								where
									.. ": item quantity must be an integer in [1, "
									.. MAX_ITEM_QUANTITY
									.. "]"
							)
						end
					end
				end
			end
		end
		if g.instances ~= nil then
			for _, itemId in ipairs(g.instances :: { unknown }) do
				entries += 1
				if not ContentRegistry.isValidId(itemId) then
					fail(where .. ": bad instance itemId " .. describe(itemId))
				end
			end
		end
		for field, category in UNLOCK_FIELDS do
			local list = g[field]
			if list ~= nil then
				if type(list) ~= "table" then
					fail(where .. ": " .. field .. " must be an array")
				else
					for _, contentId in ipairs(list :: { unknown }) do
						entries += 1
						if
							Canon:resolve(category :: ContentRegistry.Category, contentId) == nil
						then
							fail(where .. ": unknown " .. category .. " " .. describe(contentId))
						end
					end
				end
			end
		end
		if entries == 0 then
			fail(where .. ": grants nothing")
		elseif entries > MAX_GRANT_ENTRIES then
			fail(where .. ": more than " .. MAX_GRANT_ENTRIES .. " grant entries")
		end
		if
			def.kind == "permanent"
			and g.cants == nil
			and g.verses == nil
			and g.waymarks == nil
			and countKeys(g) == 0
		then
			fail(where .. ": permanent reward grants nothing")
		end
	end
	return errors
end

local function deepFreeze(value: any)
	if type(value) == "table" and not table.isfrozen(value) then
		table.freeze(value)
		for _, child in value do
			deepFreeze(child)
		end
	end
end

function RewardCatalog.build(definitions: { Definition }): Catalog
	local problems = RewardCatalog.validate(definitions)
	if #problems > 0 then
		error("RewardCatalog: invalid definitions:\n  " .. table.concat(problems, "\n  "), 2)
	end
	deepFreeze(definitions)
	local byId: { [string]: Definition } = {}
	local ids: { string } = {}
	for _, def in definitions do
		byId[def.id] = def
		table.insert(ids, def.id)
	end
	table.sort(ids)
	local catalog = {} :: Catalog
	function catalog:get(id: string): Definition?
		return byId[id]
	end
	function catalog:ids(): { string }
		return table.clone(ids)
	end
	return table.freeze(catalog)
end

local SEGMENT = "^[%w%-_.]+$"

local function okSegment(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and string.match(value, SEGMENT) ~= nil
end

-- Deterministic receipt ID for a one-time grant.
function RewardCatalog.permanentReceiptId(
	sourceKind: SourceKind,
	sourceId: string,
	rewardId: string
): string?
	if not SOURCE_KINDS[sourceKind] or not okSegment(sourceId) or not okSegment(rewardId) then
		return nil
	end
	local id = string.format("p:%s:%s:%s", sourceKind, sourceId, rewardId)
	return if #id <= Limits.MAX_OPAQUE_ID_BYTES then id else nil
end

-- Deterministic receipt ID for a repeatable grant inside a season.
function RewardCatalog.seasonalReceiptId(
	season: number,
	runId: string,
	slot: number,
	rewardId: string
): string?
	if
		not isPositiveInt(season, 100000)
		or not okSegment(runId)
		or not isPositiveInt(slot, 64)
		or not okSegment(rewardId)
	then
		return nil
	end
	local id = string.format("s:%d:%s:%d:%s", season, runId, slot, rewardId)
	return if #id <= Limits.MAX_OPAQUE_ID_BYTES then id else nil
end

-- The checked-in catalog. Entries are added by the tasks that define the
-- rewards (BM-075 Waymark I, BM-081 first-slice items, BM-095 first boss,
-- BM-123 endgame tables) once the canonical inventory names them.
RewardCatalog.DEFINITIONS = table.freeze({} :: { Definition })

function RewardCatalog.production(): Catalog
	return RewardCatalog.build(RewardCatalog.DEFINITIONS :: any)
end

return table.freeze(RewardCatalog)
