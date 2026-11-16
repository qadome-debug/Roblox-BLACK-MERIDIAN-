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

export type Targeting = "none" | "direction" | "point" | "combatant" | "pair"

export type Definition = {
	id: string,
	cantId: string,
	-- The design gives cooldowns in seconds. They are converted to whole
	-- simulation steps where the cast layer attaches (`toSteps`).
	cooldownSeconds: number,
	-- nil means "not yet established by the design". Nothing is filled in
	-- for it: a Verse with any of these missing cannot be cast at all.
	costs: { Cost }?,
	castSeconds: number?,
	-- Dissonance the caster gains when the Verse resolves.
	dissonance: number?,
	-- How the Verse is aimed, which combat states it may start from, and
	-- the server effect (a name, never a function) with its parameters.
	targeting: Targeting?,
	castFrom: { string }?,
	effect: string?,
	params: { [string]: number }?,
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
	-- False while any value the cast needs is still unset.
	isCastable: (self: Catalog, verseId: string) -> boolean,
	prerequisitesMet: (self: Catalog, verseId: string, facts: Facts) -> boolean,
}

local NearnessTuning = require(script.Parent.NearnessTuning)

local VerseCatalog = {}

VerseCatalog.MAX_COST = 1000
VerseCatalog.MAX_CAST_SECONDS = 20
VerseCatalog.MAX_COOLDOWN_SECONDS = 20 * 60
VerseCatalog.MAX_DISSONANCE = 100
VerseCatalog.MAX_COSTS = 3

local FIELDS: { [string]: boolean } = {
	id = true,
	cantId = true,
	costs = true,
	castSeconds = true,
	cooldownSeconds = true,
	dissonance = true,
	targeting = true,
	castFrom = true,
	effect = true,
	params = true,
	prerequisites = true,
	mechanics = true,
}
local PREREQ_FIELDS: { [string]: boolean } = { verseIds = true, waymarkId = true, questId = true }
local TARGETING: { [string]: boolean } =
	{ none = true, direction = true, point = true, combatant = true, pair = true }
local CAST_STATES: { [string]: boolean } = {
	Idle = true,
	Guarding = true,
	Attacking = true,
	Dodging = true,
	Parrying = true,
	AttackRecovery = true,
}
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

local function isSecondsIn(value: unknown, max: number): boolean
	return isFinite(value) and (value :: number) >= 0 and (value :: number) <= max
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
		-- nil means "not established yet"; see the completeness rule below.
		if costs ~= nil and (not isArray(costs) or #costs > VerseCatalog.MAX_COSTS) then
			problem(id .. ": costs must be a list of at most " .. VerseCatalog.MAX_COSTS)
		elseif costs ~= nil then
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

		if
			def.castSeconds ~= nil
			and not isSecondsIn(def.castSeconds, VerseCatalog.MAX_CAST_SECONDS)
		then
			problem(
				id
					.. ": castSeconds must be within 0.."
					.. VerseCatalog.MAX_CAST_SECONDS
					.. " seconds"
			)
		end
		if not isSecondsIn(def.cooldownSeconds, VerseCatalog.MAX_COOLDOWN_SECONDS) then
			problem(
				id
					.. ": cooldownSeconds must be within 0.."
					.. VerseCatalog.MAX_COOLDOWN_SECONDS
					.. " seconds"
			)
		end
		if
			def.dissonance ~= nil
			and (
				not isFinite(def.dissonance)
				or def.dissonance < 0
				or def.dissonance > VerseCatalog.MAX_DISSONANCE
			)
		then
			problem(id .. ": dissonance must be within 0.." .. VerseCatalog.MAX_DISSONANCE)
		end
		if def.targeting ~= nil and not TARGETING[def.targeting] then
			problem(id .. ": unknown targeting " .. tostring(def.targeting))
		end
		if def.castFrom ~= nil then
			if not isArray(def.castFrom) or #def.castFrom == 0 then
				problem(id .. ": castFrom must be a non-empty list")
			else
				for _, state in def.castFrom :: { any } do
					if not CAST_STATES[state] then
						problem(id .. ": castFrom lists unknown state " .. tostring(state))
					end
				end
			end
		end
		if def.effect ~= nil then
			if
				type(def.effect) ~= "string"
				or #def.effect > 48
				or string.match(def.effect, "^[a-z][a-z0-9_]*$") == nil
			then
				problem(id .. ": effect must be a lower-case effect name")
			end
		end
		if def.params ~= nil then
			if type(def.params) ~= "table" then
				problem(id .. ": params must be a table of numbers")
			else
				local n = 0
				for key, value in def.params :: { [any]: any } do
					n += 1
					if type(key) ~= "string" or not isFinite(value) or math.abs(value) > 1e6 then
						problem(id .. ": params must map names to bounded finite numbers")
						break
					end
				end
				if n > 16 then
					problem(id .. ": at most 16 params")
				end
				if def.effect == nil and n > 0 then
					problem(id .. ": params without an effect")
				end
			end
		end
		-- A canonical Verse is complete: no value it needs is left unset.
		if
			def.mechanics == "canonical"
			and (def.costs == nil or def.castSeconds == nil or def.dissonance == nil)
		then
			problem(id .. ": a canonical Verse needs costs, castSeconds and dissonance")
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

	function catalog:isCastable(verseId: string): boolean
		local def = byId[verseId]
		return def ~= nil and def.costs ~= nil and def.castSeconds ~= nil
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
-- Seconds to whole simulation steps, rounded to the nearest step.
function VerseCatalog.toSteps(seconds: number, stepSeconds: number): number
	return math.max(0, math.floor(seconds / stepSeconds + 0.5))
end

-- The production definitions: the four Nearness Verses, built from
-- Content/NearnessTuning. Cooldowns are confirmed by the design; every
-- other value is an initial balancing value approved on 2026-11-16, kept
-- in one table so it can be adjusted after play. The Verses are therefore
-- "provisional": playable, not final.
function VerseCatalog.definitionsFrom(tuning: { NearnessTuning.Verse }): { Definition }
	local out: { Definition } = {}
	for _, verse in tuning do
		local definition: Definition = {
			id = verse.id,
			cantId = "cant.nearness",
			cooldownSeconds = verse.cooldownSeconds,
			castSeconds = verse.castSeconds,
			costs = { { pool = "stamina", amount = verse.stamina } :: Cost },
			dissonance = verse.dissonance,
			targeting = verse.targeting :: any,
			castFrom = table.clone(verse.castFrom),
			effect = verse.effect,
			params = table.clone(verse.params),
			prerequisites = { verseIds = {} },
			mechanics = "provisional",
		}
		table.insert(out, definition)
	end
	return out
end

local production: Catalog? = nil

function VerseCatalog.production(): Catalog
	if production == nil then
		production = VerseCatalog.build(VerseCatalog.definitionsFrom(NearnessTuning))
	end
	return production :: Catalog
end

return table.freeze(VerseCatalog)
