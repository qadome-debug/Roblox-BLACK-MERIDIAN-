--!strict
-- Verse catalog (BM-065).
--
-- Typed gameplay definitions for every canonical Verse: the Cant it
-- belongs to, its resource cost, cast and cooldown timing in simulation
-- steps, and its unlock prerequisites. Like the Cant catalog it must agree
-- exactly with the canonical content registry:
--
--   * every canonical Verse has exactly one definition, and no definition
--     names a Verse the registry does not know;
--   * `cantId` is the registry's Cant for that Verse (compatibility);
--   * prerequisites name canonical Verses of the same Cant, Waymarks or
--     quests, with no prerequisite cycles;
--   * costs and timings are finite, positive where required, and bounded.
--
-- SCHEMA ASSUMPTIONS (not canon): cost pools, cast and cooldown timing and
-- the prerequisite kinds are this catalog's working shape until the design
-- states what a Verse costs and how it is unlocked.
--
-- `resolve` is the entry point for client input. Production definitions
-- are added by BM-066 as canonical Verse names arrive; until then the
-- production catalog is empty and valid.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)

export type Pool = "stamina" | "posture" | "health"

export type Cost = { pool: Pool, amount: number }

export type Prerequisites = {
	verseIds: { string },
	waymarkId: string?,
	questId: string?,
}

export type Mechanics = "canonical" | "provisional"

export type Definition = {
	id: string,
	cantId: string,
	costs: { Cost },
	castSteps: number,
	cooldownSteps: number,
	prerequisites: Prerequisites,
	mechanics: Mechanics,
}

-- Server-known facts about a player when judging prerequisites.
export type Facts = {
	verses: { [string]: boolean },
	waymarks: { [string]: boolean },
	quests: { [string]: boolean },
}

export type Catalog = {
	get: (self: Catalog, id: string) -> Definition?,
	resolve: (self: Catalog, value: unknown) -> string?,
	ids: (self: Catalog) -> { string },
	forCant: (self: Catalog, cantId: string) -> { string },
	isCompatible: (self: Catalog, verseId: string, cantId: string) -> boolean,
	prerequisitesMet: (self: Catalog, verseId: string, facts: Facts) -> boolean,
}

local VerseCatalog = {}

VerseCatalog.MAX_COST = 1000
VerseCatalog.MAX_CAST_STEPS = 60 * 10
VerseCatalog.MAX_COOLDOWN_STEPS = 60 * 60 * 10
VerseCatalog.MAX_COSTS = 3

local FIELDS: { [string]: boolean } = {
	id = true,
	cantId = true,
	costs = true,
	castSteps = true,
	cooldownSteps = true,
	prerequisites = true,
	mechanics = true,
}
local PREREQ_FIELDS: { [string]: boolean } = { verseIds = true, waymarkId = true, questId = true }
local POOLS: { [string]: boolean } = { stamina = true, posture = true, health = true }

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

local function isIntegerIn(value: unknown, min: number, max: number): boolean
	return isFinite(value)
		and (value :: number) == math.floor(value :: number)
		and (value :: number) >= min
		and (value :: number) <= max
end

function VerseCatalog.validate(definitions: unknown, canon: ContentRegistry.Registry?): { string }
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
		if type(raw) ~= "table" then
			problem("definition " .. index .. ": not a table")
			continue
		end
		local def = raw :: { [string]: any }
		local id = def.id
		if type(id) ~= "string" then
			problem("definition " .. index .. ": id must be a string")
			continue
		end
		for key in def do
			if type(key) ~= "string" or not FIELDS[key] then
				problem(id .. ": unknown field " .. tostring(key))
			end
		end
		local verse = registry:getVerse(id)
		if verse == nil then
			problem(id .. ": not a canonical Verse ID")
			continue
		end
		if defined[id] ~= nil then
			problem(id .. ": defined more than once")
			continue
		end
		defined[id] = def

		if def.cantId ~= verse.cantId then
			problem(id .. ": cantId must be " .. verse.cantId .. " (registry)")
		end

		local costs = def.costs
		if not isArray(costs) or #costs > VerseCatalog.MAX_COSTS then
			problem(id .. ": costs must be a list of at most " .. VerseCatalog.MAX_COSTS)
		else
			local pools: { [string]: boolean } = {}
			for _, cost in costs :: { any } do
				if
					type(cost) ~= "table"
					or not POOLS[cost.pool]
					or not isFinite(cost.amount)
					or cost.amount <= 0
					or cost.amount > VerseCatalog.MAX_COST
				then
					problem(
						id
							.. ": each cost needs a pool and an amount in (0, "
							.. VerseCatalog.MAX_COST
							.. "]"
					)
				elseif pools[cost.pool] then
					problem(id .. ": pool " .. cost.pool .. " costed twice")
				else
					pools[cost.pool] = true
				end
			end
		end

		if not isIntegerIn(def.castSteps, 0, VerseCatalog.MAX_CAST_STEPS) then
			problem(id .. ": castSteps must be an integer in 0.." .. VerseCatalog.MAX_CAST_STEPS)
		end
		if not isIntegerIn(def.cooldownSteps, 0, VerseCatalog.MAX_COOLDOWN_STEPS) then
			problem(
				id .. ": cooldownSteps must be an integer in 0.." .. VerseCatalog.MAX_COOLDOWN_STEPS
			)
		end

		local prereq = def.prerequisites
		if type(prereq) ~= "table" or not isArray(prereq.verseIds) then
			problem(id .. ": prerequisites must have a verseIds list")
		else
			for key in prereq :: { [string]: any } do
				if not PREREQ_FIELDS[key] then
					problem(id .. ": unknown prerequisite " .. tostring(key))
				end
			end
			for _, other in prereq.verseIds :: { any } do
				local otherVerse = if type(other) == "string" then registry:getVerse(other) else nil
				if otherVerse == nil then
					problem(
						id .. ": prerequisite " .. tostring(other) .. " is not a canonical Verse"
					)
				elseif other == id then
					problem(id .. ": cannot require itself")
				elseif otherVerse.cantId ~= verse.cantId then
					problem(id .. ": prerequisite " .. other .. " belongs to another Cant")
				end
			end
			if prereq.waymarkId ~= nil and registry:resolve("waymark", prereq.waymarkId) == nil then
				problem(
					id
						.. ": prerequisite waymark "
						.. tostring(prereq.waymarkId)
						.. " is not canonical"
				)
			end
			if prereq.questId ~= nil and registry:resolve("quest", prereq.questId) == nil then
				problem(
					id .. ": prerequisite quest " .. tostring(prereq.questId) .. " is not canonical"
				)
			end
		end

		if def.mechanics ~= "canonical" and def.mechanics ~= "provisional" then
			problem(id .. ": mechanics must be canonical or provisional")
		end
	end

	-- No prerequisite cycles (a Verse must be reachable).
	local visiting: { [string]: boolean } = {}
	local done: { [string]: boolean } = {}
	local function visit(id: string, path: { string }): boolean
		if done[id] then
			return false
		end
		if visiting[id] then
			problem(id .. ": prerequisite cycle " .. table.concat(path, " -> ") .. " -> " .. id)
			return true
		end
		visiting[id] = true
		local def = defined[id]
		local prereq = if def ~= nil then def.prerequisites else nil
		if type(prereq) == "table" and isArray(prereq.verseIds) then
			for _, other in prereq.verseIds :: { any } do
				if type(other) == "string" and defined[other] ~= nil and other ~= id then
					local nextPath = table.clone(path)
					table.insert(nextPath, id)
					if visit(other, nextPath) then
						break
					end
				end
			end
		end
		visiting[id] = nil
		done[id] = true
		return false
	end
	for id in defined do
		visit(id, {})
	end

	for _, id in registry:ids("verse") do
		if defined[id] == nil then
			problem(id .. ": canonical Verse has no definition")
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

function VerseCatalog.build(definitions: { Definition }, canon: ContentRegistry.Registry?): Catalog
	local problems = VerseCatalog.validate(definitions, canon)
	if #problems > 0 then
		error("VerseCatalog: definitions are invalid:\n  " .. table.concat(problems, "\n  "), 2)
	end
	deepFreeze(definitions)

	local byId: { [string]: Definition } = {}
	local ids: { string } = {}
	local byCant: { [string]: { string } } = {}
	for _, def in definitions do
		byId[def.id] = def
		table.insert(ids, def.id)
		local list = byCant[def.cantId] or {}
		table.insert(list, def.id)
		byCant[def.cantId] = list
	end
	table.sort(ids)
	for _, list in byCant do
		table.sort(list)
		table.freeze(list)
	end
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

	function catalog:forCant(cantId: string): { string }
		return byCant[cantId] or table.freeze({})
	end

	function catalog:isCompatible(verseId: string, cantId: string): boolean
		local def = byId[verseId]
		return def ~= nil and def.cantId == cantId
	end

	function catalog:prerequisitesMet(verseId: string, facts: Facts): boolean
		local def = byId[verseId]
		if def == nil then
			return false
		end
		local prereq = def.prerequisites
		for _, other in prereq.verseIds do
			if facts.verses[other] ~= true then
				return false
			end
		end
		if prereq.waymarkId ~= nil and facts.waymarks[prereq.waymarkId] ~= true then
			return false
		end
		if prereq.questId ~= nil and facts.quests[prereq.questId] ~= true then
			return false
		end
		return true
	end

	return table.freeze(catalog) :: any
end

-- Production definitions: none until the canonical Verse inventory names
-- them (BM-066).
local PRODUCTION: { Definition } = {}

local production: Catalog? = nil

function VerseCatalog.production(): Catalog
	if production == nil then
		production = VerseCatalog.build(PRODUCTION)
	end
	return production :: Catalog
end

return table.freeze(VerseCatalog)
