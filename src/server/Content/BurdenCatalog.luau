--!strict
-- Burden catalog (BM-069).
--
-- Typed gameplay definitions for every canonical Burden: where it can be
-- acquired, which Burdens it cannot coexist with, how it stacks, and the
-- gameplay modifiers it applies. Validated against the canonical content
-- registry like the Cant and Verse catalogs:
--
--   * every canonical Burden has exactly one definition, and no definition
--     names a Burden the registry does not know;
--   * incompatibilities are canonical, symmetric and never self-referential;
--   * modifiers target known derived stats and stay inside tighter bounds
--     than the general attribute limits, so no Burden can trivialise or
--     zero out a stat.
--
-- `resolve` is the entry point for client input. The canonical Burden
-- list is not yet in the design inventory, so the production catalog is
-- empty and valid.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ServerScriptService.Server.Combat.Attributes)
local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)

export type Source = "descent" | "boss" | "quest" | "waymark"

export type Modifier = { stat: Attributes.DerivedKey, add: number?, mul: number? }

export type Definition = {
	id: string,
	sources: { Source },
	incompatibleWith: { string },
	maxStacks: number,
	modifiers: { Modifier },
	mechanics: "canonical" | "provisional",
}

export type Catalog = {
	get: (self: Catalog, id: string) -> Definition?,
	resolve: (self: Catalog, value: unknown) -> string?,
	ids: (self: Catalog) -> { string },
	compatible: (self: Catalog, held: { string }, candidate: string) -> (boolean, string?),
	-- Attribute modifiers for a held set, `stacks[id]` copies each, clamped
	-- to the definition's maxStacks.
	modifiersFor: (self: Catalog, stacks: { [string]: number }) -> { Attributes.Modifier },
}

local BurdenCatalog = {}

BurdenCatalog.MAX_ADD_FRACTION = 0.5 -- of the stat's cap
BurdenCatalog.MIN_MUL = 0.5
BurdenCatalog.MAX_MUL = 1.5
BurdenCatalog.MAX_STACKS = 5
BurdenCatalog.MAX_MODIFIERS = 4

local SOURCES: { [string]: boolean } = { descent = true, boss = true, quest = true, waymark = true }
local FIELDS: { [string]: boolean } = {
	id = true,
	sources = true,
	incompatibleWith = true,
	maxStacks = true,
	modifiers = true,
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
		if registry:resolve("burden", id) == nil then
			problem(id .. ": not a canonical Burden ID")
			continue
		end
		if defined[id] ~= nil then
			problem(id .. ": defined more than once")
			continue
		end
		defined[id] = def

		if not isArray(def.sources) or #def.sources == 0 then
			problem(id .. ": sources must be a non-empty list")
		else
			local seen: { [string]: boolean } = {}
			for _, source in def.sources do
				if not SOURCES[source] then
					problem(id .. ": unknown source " .. tostring(source))
				elseif seen[source] then
					problem(id .. ": source " .. source .. " listed twice")
				end
				seen[source] = true
			end
		end

		if not isArray(def.incompatibleWith) then
			problem(id .. ": incompatibleWith must be a list")
		else
			for _, other in def.incompatibleWith do
				if other == id then
					problem(id .. ": cannot be incompatible with itself")
				elseif registry:resolve("burden", other) == nil then
					problem(
						id
							.. ": incompatibleWith "
							.. tostring(other)
							.. " is not a canonical Burden"
					)
				end
			end
		end

		local stacks = def.maxStacks
		if
			type(stacks) ~= "number"
			or stacks ~= math.floor(stacks)
			or stacks < 1
			or stacks > BurdenCatalog.MAX_STACKS
		then
			problem(id .. ": maxStacks must be an integer in 1.." .. BurdenCatalog.MAX_STACKS)
		end

		if not isArray(def.modifiers) or #def.modifiers > BurdenCatalog.MAX_MODIFIERS then
			problem(id .. ": modifiers must be a list of at most " .. BurdenCatalog.MAX_MODIFIERS)
		else
			for i, mod in def.modifiers do
				local where = id .. ": modifier " .. i
				if type(mod) ~= "table" or Attributes.CAPS[mod.stat] == nil then
					problem(where .. " must target a derived stat")
					continue
				end
				for key in mod :: { [string]: any } do
					if key ~= "stat" and key ~= "add" and key ~= "mul" then
						problem(where .. ": unknown field " .. tostring(key))
					end
				end
				if mod.add == nil and mod.mul == nil then
					problem(where .. ": needs add or mul")
				end
				local cap = Attributes.CAPS[mod.stat].max * BurdenCatalog.MAX_ADD_FRACTION
				if mod.add ~= nil and (not isFinite(mod.add) or math.abs(mod.add) > cap) then
					problem(where .. ": add must be finite and within +/-" .. cap)
				end
				if
					mod.mul ~= nil
					and (
						not isFinite(mod.mul)
						or mod.mul < BurdenCatalog.MIN_MUL
						or mod.mul > BurdenCatalog.MAX_MUL
					)
				then
					problem(
						where
							.. ": mul must be within "
							.. BurdenCatalog.MIN_MUL
							.. ".."
							.. BurdenCatalog.MAX_MUL
					)
				end
			end
		end

		if def.mechanics ~= "canonical" and def.mechanics ~= "provisional" then
			problem(id .. ": mechanics must be canonical or provisional")
		end
	end

	for id, def in defined do
		if isArray(def.incompatibleWith) then
			for _, other in def.incompatibleWith do
				local otherDef = defined[other]
				if
					otherDef ~= nil
					and isArray(otherDef.incompatibleWith)
					and not table.find(otherDef.incompatibleWith, id)
				then
					problem(id .. ": incompatible with " .. other .. " but not the other way round")
				end
			end
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

	function catalog:compatible(held: { string }, candidate: string): (boolean, string?)
		local def = byId[candidate]
		if def == nil then
			return false, "unknown burden"
		end
		for _, other in held do
			if table.find(def.incompatibleWith, other) then
				return false, "incompatible burden"
			end
		end
		return true, nil
	end

	function catalog:modifiersFor(stacks: { [string]: number }): { Attributes.Modifier }
		local out: { Attributes.Modifier } = {}
		local held: { string } = {}
		for id in stacks do
			table.insert(held, id)
		end
		table.sort(held)
		for _, id in held do
			local def = byId[id]
			local count = stacks[id]
			if def == nil or type(count) ~= "number" or count < 1 then
				continue
			end
			count = math.min(math.floor(count), def.maxStacks)
			for i, mod in def.modifiers do
				local entry: Attributes.Modifier = { id = id .. ":" .. i, stat = mod.stat }
				if mod.add ~= nil then
					entry.add = math.clamp(
						mod.add * count,
						-Attributes.MAX_MODIFIER_ADD,
						Attributes.MAX_MODIFIER_ADD
					)
				end
				if mod.mul ~= nil then
					entry.mul = math.clamp(
						mod.mul ^ count,
						Attributes.MIN_MODIFIER_MUL,
						Attributes.MAX_MODIFIER_MUL
					)
				end
				table.insert(out, entry)
			end
		end
		return out
	end

	return table.freeze(catalog) :: any
end

local PRODUCTION: { Definition } = {}
local production: Catalog? = nil

function BurdenCatalog.production(): Catalog
	if production == nil then
		production = BurdenCatalog.build(PRODUCTION)
	end
	return production :: Catalog
end

return table.freeze(BurdenCatalog)
