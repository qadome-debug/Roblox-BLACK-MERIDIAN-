--!strict
-- Burden catalog (BM-069).
--
-- FROM THE DESIGN (22-part report, approved 2026-11-16): a Burden is tied
-- to a Cant. It is not a generic pickup and it does not stack. A Cant has
-- one default Burden and may have alternate Burdens reached through
-- mastery. For Nearness the default is Unwanted Company and the alternate
-- mastery Burden is Long Way Home.
--
-- This catalog therefore records, for every canonical Burden:
--
--   * the Cant it belongs to (must match the content registry);
--   * its role: "default" or "mastery";
--   * the server effect that implements it and that effect's parameters.
--
-- Validation:
--
--   * every canonical Burden has exactly one definition, and no definition
--     names a Burden the registry does not know;
--   * a Cant has at most one default Burden, and a mastery Burden only
--     exists beside a default;
--   * an effect is a name, never a function, and parameters are a small
--     set of bounded finite numbers, so a definition is plain data;
--   * a canonical Burden names its effect. A provisional one may leave it
--     unset, and then it has no gameplay consequence at all.
--
-- NOT YET ESTABLISHED: the numbers behind Unwanted Company and Long Way
-- Home, what mastery requires, and the machine IDs of both Burdens. Until
-- the IDs are approved the production catalog is empty and valid; see
-- docs/id-proposals.md and docs/decision-sheet.md.
--
-- An earlier version of this catalog assumed Burdens were acquired from
-- Descents, bosses, quests or Waymarks, stacked up to five times and only
-- changed stats. None of that is in the design; it was removed.
--
-- `resolve` is the entry point for client input.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)

export type Role = "default" | "mastery"

export type Definition = {
	id: string,
	cantId: string,
	role: Role,
	effect: string?,
	params: { [string]: number }?,
	mechanics: "canonical" | "provisional",
}

export type CantBurdens = { default: string?, mastery: { string } }

export type Catalog = {
	get: (self: Catalog, id: string) -> Definition?,
	resolve: (self: Catalog, value: unknown) -> string?,
	ids: (self: Catalog) -> { string },
	-- The Burdens of one Cant.
	forCant: (self: Catalog, cantId: string) -> CantBurdens,
	belongsTo: (self: Catalog, burdenId: string, cantId: string) -> boolean,
	-- The Burden in force for an equipped Cant. `chosen` is the player's
	-- saved choice of a mastery Burden; it is honoured only when it belongs
	-- to the Cant and the server says mastery is unlocked. Otherwise the
	-- default applies. Returns nil when the Cant has no Burden defined.
	activeFor: (
		self: Catalog,
		cantId: string,
		chosen: string?,
		masteryUnlocked: boolean
	) -> string?,
}

local BurdenCatalog = {}

BurdenCatalog.MAX_PARAMS = 8
BurdenCatalog.MAX_PARAM = 1000000
BurdenCatalog.EFFECT_PATTERN = "^[a-z][a-z0-9_]*$"
BurdenCatalog.MAX_EFFECT_BYTES = 48

local FIELDS: { [string]: boolean } = {
	id = true,
	cantId = true,
	role = true,
	effect = true,
	params = true,
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

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function BurdenCatalog.validate(definitions: unknown, canon: ContentRegistry.Registry?): { string }
	local registry: ContentRegistry.Registry = canon or Canon
	local problems: { string } = {}
	local function problem(message: string)
		table.insert(problems, message)
	end
	if not isArray(definitions) then
		return { "definitions must be an array" }
	end

	local defined: { [string]: { [string]: any } } = {}
	local defaults: { [string]: string } = {}
	local mastery: { [string]: { string } } = {}

	for index, raw in definitions :: { any } do
		if type(raw) ~= "table" or type(raw.id) ~= "string" then
			problem("definition " .. index .. ": needs a string id")
			continue
		end
		local def = raw :: { [string]: any }
		local id = def.id :: string
		for key in def do
			if type(key) ~= "string" or not FIELDS[key] then
				problem(id .. ": unknown field " .. tostring(key))
			end
		end
		local entry = registry:getBurden(id)
		if entry == nil then
			problem(id .. ": not a canonical Burden ID")
			continue
		end
		if defined[id] ~= nil then
			problem(id .. ": defined more than once")
			continue
		end
		defined[id] = def

		if def.cantId ~= entry.cantId then
			problem(id .. ": cantId must be " .. entry.cantId .. " (registry)")
		end

		if def.role == "default" then
			local existing = defaults[entry.cantId]
			if existing ~= nil then
				problem(
					id .. ": " .. entry.cantId .. " already has the default Burden " .. existing
				)
			else
				defaults[entry.cantId] = id
			end
		elseif def.role == "mastery" then
			local list = mastery[entry.cantId] or {}
			table.insert(list, id)
			mastery[entry.cantId] = list
		else
			problem(id .. ": role must be default or mastery")
		end

		local effect = def.effect
		if effect ~= nil then
			if
				type(effect) ~= "string"
				or #effect > BurdenCatalog.MAX_EFFECT_BYTES
				or string.match(effect, BurdenCatalog.EFFECT_PATTERN) == nil
			then
				problem(id .. ": effect must be a lower-case effect name")
			end
		end

		local params = def.params
		if params ~= nil then
			if type(params) ~= "table" then
				problem(id .. ": params must be a table of numbers")
			else
				local count = 0
				for key, value in params :: { [any]: any } do
					count += 1
					if type(key) ~= "string" then
						problem(id .. ": params keys must be strings")
					elseif not isFinite(value) or math.abs(value) > BurdenCatalog.MAX_PARAM then
						problem(id .. ": param " .. key .. " must be a bounded finite number")
					end
				end
				if count > BurdenCatalog.MAX_PARAMS then
					problem(id .. ": at most " .. BurdenCatalog.MAX_PARAMS .. " params")
				end
				if effect == nil and count > 0 then
					problem(id .. ": params without an effect")
				end
			end
		end

		if def.mechanics ~= "canonical" and def.mechanics ~= "provisional" then
			problem(id .. ": mechanics must be canonical or provisional")
		elseif def.mechanics == "canonical" and effect == nil then
			problem(id .. ": a canonical Burden names its effect")
		end
	end

	for cantId, list in mastery do
		if defaults[cantId] == nil then
			table.sort(list)
			problem(list[1] .. ": a mastery Burden needs " .. cantId .. " to have a default Burden")
		end
	end

	for _, id in registry:ids("burden") do
		if defined[id] == nil then
			problem(id .. ": canonical Burden has no definition")
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

function BurdenCatalog.build(definitions: { Definition }, canon: ContentRegistry.Registry?): Catalog
	local problems = BurdenCatalog.validate(definitions, canon)
	if #problems > 0 then
		error("BurdenCatalog: definitions are invalid:\n  " .. table.concat(problems, "\n  "), 2)
	end
	deepFreeze(definitions)
	local byId: { [string]: Definition } = {}
	local ids: { string } = {}
	local byCant: { [string]: CantBurdens } = {}
	for _, def in definitions do
		byId[def.id] = def
		table.insert(ids, def.id)
		local entry = byCant[def.cantId]
		if entry == nil then
			entry = { default = nil, mastery = {} }
			byCant[def.cantId] = entry
		end
		if def.role == "default" then
			entry.default = def.id
		else
			table.insert(entry.mastery, def.id)
		end
	end
	table.sort(ids)
	table.freeze(ids)
	for _, entry in byCant do
		table.sort(entry.mastery)
		table.freeze(entry.mastery)
		table.freeze(entry)
	end
	local NONE: CantBurdens = table.freeze({ default = nil, mastery = table.freeze({}) }) :: any

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

	function catalog:forCant(cantId: string): CantBurdens
		return byCant[cantId] or NONE
	end

	function catalog:belongsTo(burdenId: string, cantId: string): boolean
		local def = byId[burdenId]
		return def ~= nil and def.cantId == cantId
	end

	function catalog:activeFor(cantId: string, chosen: string?, masteryUnlocked: boolean): string?
		local entry = byCant[cantId]
		if entry == nil then
			return nil
		end
		if chosen ~= nil and masteryUnlocked == true then
			local def = byId[chosen]
			if def ~= nil and def.cantId == cantId and def.role == "mastery" then
				return chosen
			end
		end
		return entry.default
	end

	return table.freeze(catalog) :: any
end

-- Empty until the machine IDs of Unwanted Company and Long Way Home are
-- approved and registered.
local PRODUCTION: { Definition } = {}
local production: Catalog? = nil

function BurdenCatalog.production(): Catalog
	if production == nil then
		production = BurdenCatalog.build(PRODUCTION)
	end
	return production :: Catalog
end

return table.freeze(BurdenCatalog)
