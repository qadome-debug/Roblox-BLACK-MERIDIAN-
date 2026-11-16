--!strict
-- Cant catalog (BM-062).
--
-- Typed gameplay definitions for every canonical Cant: how it is unlocked,
-- which loadout slots may hold it, which Cants it excludes, and which
-- Verses are compatible with it. Identity (IDs, names, the Verse list)
-- comes from the canonical content registry (BM-004); this catalog adds
-- behaviour and must agree with it exactly:
--
--   * every canonical Cant has exactly one definition, and no definition
--     names a Cant the registry does not know (no fabricated IDs);
--   * a definition's `verseIds` are exactly the registry's Verse list for
--     that Cant;
--   * unlock references (Waymarks, quests) are canonical IDs.
--
-- FROM THE DESIGN (approved 2026-11-16): there are two Cant slots. A
-- player begins with one; Waymark II unlocks the second. Only the first
-- slot is implemented for the vertical slice, and the saved profile holds
-- a single equipped Cant. Nearness is acquired during the introductory
-- story (unlock kind "story"), which is a different moment from earning
-- Waymark I. How Embers, Second Voice and Still Water are acquired is not
-- yet established, so their unlock is "undetermined": it can never be
-- satisfied and is allowed only on a provisional definition.
--
-- STILL AN ASSUMPTION: the slot names, the "waymark" and "quest" unlock
-- kinds, and the exclusion list.
--
-- `mechanics` records whether the Cant's mechanical values are canonical
-- yet. A "provisional" Cant has its rules wired but its tuning waits on the
-- design inventory; launch validation (BM-130) refuses provisional Cants
-- that are launch-required.
--
-- `resolve` is the entry point for client input: it returns a Cant ID only
-- when the value names a defined Cant, so unknown or fabricated IDs never
-- reach gameplay code.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)

export type Slot = "primary" | "secondary"

export type Unlock =
	{ kind: "starter" }
	-- Granted by the story through RewardService; ownership is read from
	-- the profile, never derived from other progress.
	| { kind: "story" }
	-- Not yet established by the design. Never unlocks.
	| { kind: "undetermined" }
	| { kind: "waymark", waymarkId: string }
	| { kind: "quest", questId: string }

export type Mechanics = "canonical" | "provisional"

export type Definition = {
	id: string,
	unlock: Unlock,
	slots: { Slot },
	exclusiveWith: { string },
	verseIds: { string },
	mechanics: Mechanics,
}

-- What the server knows about a player when judging unlocks. Built from
-- the profile; never from anything a client sends.
export type Facts = {
	waymarks: { [string]: boolean },
	quests: { [string]: boolean },
}

export type Loadout = { [Slot]: string }

export type Catalog = {
	get: (self: Catalog, id: string) -> Definition?,
	resolve: (self: Catalog, value: unknown) -> string?,
	ids: (self: Catalog) -> { string },
	isUnlocked: (self: Catalog, id: string, facts: Facts) -> boolean,
	unlocked: (self: Catalog, facts: Facts) -> { string },
	canSlot: (self: Catalog, id: string, slot: Slot) -> boolean,
	isVerseCompatible: (self: Catalog, cantId: string, verseId: string) -> boolean,
	checkLoadout: (self: Catalog, loadout: Loadout, facts: Facts) -> (boolean, string?),
}

local CantCatalog = {}

CantCatalog.SLOTS = table.freeze({ "primary", "secondary" } :: { Slot })

local SLOT_SET: { [string]: boolean } = { primary = true, secondary = true }
local UNLOCK_KINDS: { [string]: { [string]: string } } = {
	starter = {},
	story = {},
	undetermined = {},
	waymark = { waymarkId = "waymark" },
	quest = { questId = "quest" },
}
local DEFINITION_FIELDS: { [string]: boolean } = {
	id = true,
	unlock = true,
	slots = true,
	exclusiveWith = true,
	verseIds = true,
	mechanics = true,
}

local function isArray(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for _ in value :: { [any]: any } do
		count += 1
	end
	return count == #(value :: { any })
end

local function stringList(value: unknown): { string }?
	if not isArray(value) then
		return nil
	end
	for _, item in value :: { any } do
		if type(item) ~= "string" then
			return nil
		end
	end
	return value :: { string }
end

local function sameSet(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	local seen: { [string]: boolean } = {}
	for _, item in a do
		seen[item] = true
	end
	for _, item in b do
		if not seen[item] then
			return false
		end
	end
	return true
end

local function hasDuplicates(list: { string }): string?
	local seen: { [string]: boolean } = {}
	for _, item in list do
		if seen[item] then
			return item
		end
		seen[item] = true
	end
	return nil
end

-- Returns every problem with `definitions` against `canon`; empty when the
-- catalog is complete and consistent.
function CantCatalog.validate(definitions: unknown, canon: ContentRegistry.Registry?): { string }
	local registry: ContentRegistry.Registry = canon or Canon
	local problems: { string } = {}
	local function problem(message: string)
		table.insert(problems, message)
	end

	if not isArray(definitions) then
		problem("definitions must be an array")
		return problems
	end

	local defined: { [string]: any } = {}
	for index, raw in definitions :: { any } do
		local where = "definition " .. index
		if type(raw) ~= "table" then
			problem(where .. ": not a table")
			continue
		end
		local def = raw :: { [string]: any }
		for key in def do
			if type(key) ~= "string" or not DEFINITION_FIELDS[key] then
				problem(where .. ": unknown field " .. tostring(key))
			end
		end

		local id = def.id
		if type(id) ~= "string" then
			problem(where .. ": id must be a string")
			continue
		end
		where = id
		if registry:resolve("cant", id) == nil then
			problem(id .. ": not a canonical Cant ID")
			continue
		end
		if defined[id] ~= nil then
			problem(id .. ": defined more than once")
			continue
		end
		defined[id] = def

		-- Unlock rule.
		local unlock = def.unlock
		if type(unlock) ~= "table" or type(unlock.kind) ~= "string" then
			problem(where .. ": unlock must be a table with a kind")
		else
			local refs = UNLOCK_KINDS[unlock.kind]
			if refs == nil then
				problem(where .. ": unknown unlock kind " .. tostring(unlock.kind))
			else
				for key in unlock :: { [string]: any } do
					if key ~= "kind" and refs[key] == nil then
						problem(where .. ": unknown unlock field " .. tostring(key))
					end
				end
				for field, category in refs do
					local ref = unlock[field]
					if registry:resolve(category :: any, ref) == nil then
						problem(
							where
								.. ": unlock "
								.. field
								.. " "
								.. tostring(ref)
								.. " is not a canonical "
								.. category
						)
					end
				end
			end
			if unlock.kind == "undetermined" and def.mechanics ~= "provisional" then
				problem(where .. ": an undetermined unlock is only allowed on a provisional Cant")
			end
			local entry = registry:getCant(id)
			if entry ~= nil and entry.starterEligible and unlock.kind ~= "starter" then
				problem(
					where .. ": the registry marks it starter eligible but unlock is not starter"
				)
			elseif entry ~= nil and not entry.starterEligible and unlock.kind == "starter" then
				problem(
					where
						.. ": unlock is starter but the registry does not mark it starter eligible"
				)
			end
		end

		-- Slots.
		local slots = stringList(def.slots)
		if slots == nil or #slots == 0 then
			problem(where .. ": slots must be a non-empty list of slot names")
		else
			for _, slot in slots do
				if not SLOT_SET[slot] then
					problem(where .. ": unknown slot " .. slot)
				end
			end
			local dup = hasDuplicates(slots)
			if dup ~= nil then
				problem(where .. ": slot " .. dup .. " listed twice")
			end
		end

		-- Exclusions.
		local exclusive = stringList(def.exclusiveWith)
		if exclusive == nil then
			problem(where .. ": exclusiveWith must be a list of Cant IDs")
		else
			for _, other in exclusive do
				if other == id then
					problem(where .. ": cannot exclude itself")
				elseif registry:resolve("cant", other) == nil then
					problem(where .. ": exclusiveWith " .. other .. " is not a canonical Cant")
				end
			end
			local dup = hasDuplicates(exclusive)
			if dup ~= nil then
				problem(where .. ": exclusiveWith lists " .. dup .. " twice")
			end
		end

		-- Compatible Verses: exactly the registry's list.
		local verses = stringList(def.verseIds)
		if verses == nil then
			problem(where .. ": verseIds must be a list of Verse IDs")
		else
			for _, verseId in verses do
				local verse = registry:getVerse(verseId)
				if verse == nil then
					problem(where .. ": verse " .. verseId .. " is not a canonical Verse")
				elseif verse.cantId ~= id then
					problem(where .. ": verse " .. verseId .. " belongs to " .. verse.cantId)
				end
			end
			local entry = registry:getCant(id)
			if entry ~= nil and not sameSet(verses, entry.verseIds) then
				problem(where .. ": verseIds differ from the registry's Verse list")
			end
		end

		if def.mechanics ~= "canonical" and def.mechanics ~= "provisional" then
			problem(where .. ": mechanics must be canonical or provisional")
		end
	end

	-- Exclusion is symmetric, so a loadout check never depends on order.
	for id, def in defined do
		local exclusive = stringList(def.exclusiveWith)
		if exclusive == nil then
			continue
		end
		for _, other in exclusive do
			local otherDef = defined[other]
			local back = if otherDef ~= nil then stringList(otherDef.exclusiveWith) else nil
			if back ~= nil and not table.find(back, id) then
				problem(id .. ": excludes " .. other .. " but not the other way round")
			end
		end
	end

	-- Completeness: every canonical Cant is defined.
	for _, id in registry:ids("cant") do
		if defined[id] == nil then
			problem(id .. ": canonical Cant has no definition")
		end
	end

	table.sort(problems)
	return problems
end

local function deepFreeze(value: any)
	if type(value) == "table" and not table.isfrozen(value) then
		table.freeze(value)
		for _, child in value do
			deepFreeze(child)
		end
	end
end

-- Validates and freezes `definitions`; errors on any problem so a server
-- never starts with a bad catalog.
function CantCatalog.build(definitions: { Definition }, canon: ContentRegistry.Registry?): Catalog
	local problems = CantCatalog.validate(definitions, canon)
	if #problems > 0 then
		error("CantCatalog: definitions are invalid:\n  " .. table.concat(problems, "\n  "), 2)
	end
	deepFreeze(definitions)

	local byId: { [string]: Definition } = {}
	local ids: { string } = {}
	for _, def in definitions do
		byId[def.id] = def
		table.insert(ids, def.id)
	end
	table.sort(ids)
	table.freeze(ids)

	local catalog = {} :: Catalog

	function catalog:get(id: string): Definition?
		return byId[id]
	end

	function catalog:resolve(value: unknown): string?
		if type(value) == "string" and byId[value] ~= nil then
			return value
		end
		return nil
	end

	function catalog:ids(): { string }
		return ids
	end

	function catalog:isUnlocked(id: string, facts: Facts): boolean
		local def = byId[id]
		if def == nil then
			return false
		end
		local unlock = def.unlock :: any
		if unlock.kind == "starter" then
			return true
		elseif unlock.kind == "waymark" then
			return facts.waymarks[unlock.waymarkId] == true
		elseif unlock.kind == "quest" then
			return facts.quests[unlock.questId] == true
		end
		return false
	end

	function catalog:unlocked(facts: Facts): { string }
		local result: { string } = {}
		for _, id in ids do
			if self:isUnlocked(id, facts) then
				table.insert(result, id)
			end
		end
		return result
	end

	function catalog:canSlot(id: string, slot: Slot): boolean
		local def = byId[id]
		return def ~= nil and table.find(def.slots, slot) ~= nil
	end

	function catalog:isVerseCompatible(cantId: string, verseId: string): boolean
		local def = byId[cantId]
		return def ~= nil and table.find(def.verseIds, verseId) ~= nil
	end

	-- Judges a whole loadout. Reasons are short fixed strings safe to log.
	function catalog:checkLoadout(loadout: Loadout, facts: Facts): (boolean, string?)
		if type(loadout) ~= "table" then
			return false, "loadout must be a table"
		end
		local equipped: { string } = {}
		for slot, id in loadout :: { [any]: any } do
			if type(slot) ~= "string" or not SLOT_SET[slot] then
				return false, "unknown slot"
			end
			if self:resolve(id) == nil then
				return false, "unknown cant"
			end
			if not self:canSlot(id, slot :: Slot) then
				return false, "cant not allowed in slot"
			end
			if not self:isUnlocked(id, facts) then
				return false, "cant not unlocked"
			end
			if table.find(equipped, id) then
				return false, "cant equipped twice"
			end
			table.insert(equipped, id)
		end
		for _, id in equipped do
			for _, other in (byId[id] :: Definition).exclusiveWith do
				if table.find(equipped, other) then
					return false, "cants are exclusive"
				end
			end
		end
		return true, nil
	end

	return table.freeze(catalog) :: any
end

-- The production definitions: the four launch Cants.
local PRODUCTION: { Definition } = {
	{
		id = "cant.nearness",
		-- Acquired during the introductory story, in Lantern Vault. This is
		-- not Waymark I, which is earned later, after the required Descent
		-- objectives and the return with the discovered evidence.
		unlock = { kind = "story" },
		slots = { "primary", "secondary" },
		exclusiveWith = {},
		verseIds = {
			"near.close_step",
			"near.draw_near",
			"near.between_us",
			"near.no_farther",
		},
		-- The discipline and its Verse list are canon. The Verses carry
		-- their own status in VerseCatalog.
		mechanics = "canonical",
	},
	{
		id = "cant.embers",
		unlock = { kind = "undetermined" },
		slots = { "primary", "secondary" },
		exclusiveWith = {},
		verseIds = {},
		mechanics = "provisional",
	},
	{
		id = "cant.second_voice",
		unlock = { kind = "undetermined" },
		slots = { "primary", "secondary" },
		exclusiveWith = {},
		verseIds = {},
		mechanics = "provisional",
	},
	{
		id = "cant.still_water",
		unlock = { kind = "undetermined" },
		slots = { "primary", "secondary" },
		exclusiveWith = {},
		verseIds = {},
		mechanics = "provisional",
	},
}

local production: Catalog? = nil

function CantCatalog.production(): Catalog
	if production == nil then
		production = CantCatalog.build(PRODUCTION :: any)
	end
	return production :: Catalog
end

return table.freeze(CantCatalog)
