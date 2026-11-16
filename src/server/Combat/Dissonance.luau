--!strict
-- Dissonance meter (BM-068).
--
-- A per-combatant meter owned by the server. Every change happens inside
-- the simulation step order, so transitions are deterministic for a given
-- sequence of steps. Clients never send meter values.
--
-- FROM THE DESIGN (22-part report, approved 2026-11-16):
--   * The meter runs from 0 to 100 in five bands:
--       0-39   Stable or manageable, with minor Burden pressure
--       40-64  Noticeable visual and audio instability
--       65-84  Enemy and environmental reactions
--       85-99  Fractured events become possible
--       100    A controlled rupture determined by the region or encounter,
--              never arbitrary permanent inventory loss
--   * It rises through Verse use, certain Relics, unstable areas, enemy
--     attacks and failed containment interactions.
--   * It recovers through stable environments, anchors, camps, approved
--     consumables, encounter completion and certain cooperative actions.
--   * The raw value normally resets or recovers between sessions. It is not
--     saved: a combatant always starts at 0. Lasting consequences belong to
--     progression and Burdens.
--
-- NOT YET ESTABLISHED (nothing is assumed for these):
--   * how much each source adds and each recovery removes. Callers pass the
--     amount; no production caller has one until it is approved. The only
--     built-in rate, passive recovery in a stable environment, is unset in
--     production, so nothing recovers by itself yet.
--   * what each band does to the player, to enemies and to the world. This
--     layer only reports band changes.
--   * what a rupture does. Reaching 100 is announced (`dissonance_rupture`)
--     and handed to an injected region or encounter handler; this layer
--     takes nothing from the player.
--   * player-triggered Dissonance actions. The mechanism below (`perform`)
--     is kept because the DissonanceAction request exists, but the
--     production action list is empty and stays empty until a design for
--     them is approved.

local ActionMachine = require(script.Parent.ActionMachine)
local Resources = require(script.Parent.Resources)
local Simulation = require(script.Parent.Simulation)

export type Band = {
	-- Internal key, used in events and code. Not player-facing.
	key: string,
	-- The design's name for the band.
	name: string,
	-- The lowest meter value in the band.
	min: number,
}

export type GainSource = "verse" | "relic" | "unstableArea" | "enemyAttack" | "failedContainment"

export type RecoverySource =
	"stableEnvironment"
	| "anchor"
	| "camp"
	| "consumable"
	| "encounterComplete"
	| "cooperative"

-- The values the design has not fixed. Every field is optional; an unset
-- field switches its behaviour off rather than falling back to a guess.
export type Tuning = {
	-- Meter removed per second while a combatant is in a stable
	-- environment.
	stableRecoveryPerSecond: number?,
}

export type ActionContext = {
	sim: Simulation.Simulation,
	actor: Simulation.Combatant,
	actionId: string,
	level: number,
	step: number,
}

export type ActionDef = {
	-- Index of the lowest band the action needs (0 = Stable).
	minLevel: number,
	-- Positive consumes Dissonance, negative adds it.
	consume: number,
	cooldownSteps: number,
	effect: (ctx: ActionContext) -> (),
}

export type Deps = {
	tuning: Tuning?,
	actions: { [string]: ActionDef }?,
	-- Whether a combatant is in a stable environment right now. Supplied by
	-- the world layer; without it nobody is.
	inStableEnvironment: ((id: string) -> boolean)?,
	-- Region or encounter handler for a rupture.
	onRupture: ((id: string) -> ())?,
}

export type Layer = {
	add: (self: Layer, id: string, amount: number, source: GainSource) -> number,
	recover: (self: Layer, id: string, amount: number, source: RecoverySource) -> number,
	value: (self: Layer, id: string) -> number,
	-- Band index, 0 (Stable) to 4 (Controlled rupture).
	level: (self: Layer, id: string) -> number,
	band: (self: Layer, id: string) -> Band,
	perform: (self: Layer, id: string, actionId: string) -> ActionMachine.Outcome,
	hasAction: (self: Layer, actionId: string) -> boolean,
	forget: (self: Layer, id: string) -> (),
}

local Dissonance = {}

Dissonance.MAX = 100

-- Canon. Ascending; BANDS[i + 1] is band index i.
Dissonance.BANDS = table.freeze({
	table.freeze({ key = "stable", name = "Stable", min = 0 }),
	table.freeze({ key = "instability", name = "Noticeable instability", min = 40 }),
	table.freeze({ key = "reactions", name = "Enemy and environmental reactions", min = 65 }),
	table.freeze({ key = "fracture", name = "Fractured event risk", min = 85 }),
	table.freeze({ key = "rupture", name = "Controlled rupture", min = 100 }),
} :: { Band })

Dissonance.RUPTURE_LEVEL = #Dissonance.BANDS - 1

Dissonance.GAIN_SOURCES = table.freeze({
	verse = true,
	relic = true,
	unstableArea = true,
	enemyAttack = true,
	failedContainment = true,
} :: { [string]: boolean })

Dissonance.RECOVERY_SOURCES = table.freeze({
	stableEnvironment = true,
	anchor = true,
	camp = true,
	consumable = true,
	encounterComplete = true,
	cooperative = true,
} :: { [string]: boolean })

-- No values are approved yet, so production tuning sets nothing.
Dissonance.PRODUCTION_TUNING = table.freeze({} :: Tuning)

-- Empty until a design for player-triggered actions is approved.
Dissonance.PRODUCTION_ACTIONS = table.freeze({} :: { [string]: ActionDef })

local MAX_CHANGE = 1000

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Band index for a meter value.
function Dissonance.levelFor(value: number): number
	local level = 0
	for index, band in Dissonance.BANDS do
		if value >= band.min then
			level = index - 1
		end
	end
	return level
end

function Dissonance.validateTuning(tuning: unknown): { string }
	if type(tuning) ~= "table" then
		return { "tuning must be a table" }
	end
	local t = tuning :: { [string]: any }
	local problems: { string } = {}
	for key in t do
		if key ~= "stableRecoveryPerSecond" then
			table.insert(problems, "unknown tuning field " .. tostring(key))
		end
	end
	local rate = t.stableRecoveryPerSecond
	if rate ~= nil and (not isFinite(rate) or rate <= 0 or rate > Dissonance.MAX) then
		table.insert(
			problems,
			"stableRecoveryPerSecond must be within (0, " .. Dissonance.MAX .. "]"
		)
	end
	return problems
end

function Dissonance.validateAction(def: unknown): { string }
	if type(def) ~= "table" then
		return { "action must be a table" }
	end
	local d = def :: { [string]: any }
	local problems: { string } = {}
	local top = Dissonance.RUPTURE_LEVEL
	if
		type(d.minLevel) ~= "number"
		or d.minLevel ~= math.floor(d.minLevel)
		or d.minLevel < 0
		or d.minLevel > top
	then
		table.insert(problems, "minLevel must be an integer in 0.." .. top)
	end
	if not isFinite(d.consume) then
		table.insert(problems, "consume must be finite")
	end
	if
		type(d.cooldownSteps) ~= "number"
		or d.cooldownSteps < 0
		or d.cooldownSteps ~= math.floor(d.cooldownSteps)
	then
		table.insert(problems, "cooldownSteps must be a non-negative integer")
	end
	if type(d.effect) ~= "function" then
		table.insert(problems, "effect must be a function")
	end
	return problems
end

function Dissonance.attach(sim: Simulation.Simulation, deps: Deps?): Layer
	local tuning: Tuning = (deps and deps.tuning) or Dissonance.PRODUCTION_TUNING
	local actions = (deps and deps.actions) or Dissonance.PRODUCTION_ACTIONS
	local inStableEnvironment = deps and deps.inStableEnvironment
	local onRupture = deps and deps.onRupture
	local problems = Dissonance.validateTuning(tuning)
	for actionId, def in actions do
		for _, p in Dissonance.validateAction(def) do
			table.insert(problems, actionId .. ": " .. p)
		end
	end
	if #problems > 0 then
		error("Dissonance: invalid configuration: " .. table.concat(problems, "; "), 2)
	end

	local stableRecoveryPerStep: number? = nil
	if tuning.stableRecoveryPerSecond ~= nil then
		stableRecoveryPerStep = tuning.stableRecoveryPerSecond * sim.stepSeconds
	end

	local meters: { [string]: number } = {}
	local levels: { [string]: number } = {}
	local readyAt: { [string]: { [string]: number } } = {}

	local function set(id: string, value: number, source: string)
		local clamped = math.clamp(value, 0, Dissonance.MAX)
		meters[id] = clamped
		local previous = levels[id] or 0
		local level = Dissonance.levelFor(clamped)
		if level == previous then
			return
		end
		levels[id] = level
		sim:emit("dissonance_band_changed", id, {
			level = level,
			previous = previous,
			band = Dissonance.BANDS[level + 1].key,
			source = source,
		})
		if level == Dissonance.RUPTURE_LEVEL then
			-- What a rupture does belongs to the region or encounter.
			sim:emit("dissonance_rupture", id, { source = source })
			if onRupture ~= nil then
				onRupture(id)
			end
		end
	end

	local layer = {} :: Layer

	function layer:value(id: string): number
		return meters[id] or 0
	end

	function layer:level(id: string): number
		return levels[id] or 0
	end

	function layer:band(id: string): Band
		return Dissonance.BANDS[(levels[id] or 0) + 1]
	end

	function layer:hasAction(actionId: string): boolean
		return actions[actionId] ~= nil
	end

	function layer:add(id: string, amount: number, source: GainSource): number
		if not Dissonance.GAIN_SOURCES[source] then
			error("Dissonance: unknown gain source " .. tostring(source), 2)
		end
		if sim:get(id) == nil or not isFinite(amount) or amount <= 0 then
			return self:value(id)
		end
		set(id, self:value(id) + math.min(amount, MAX_CHANGE), source)
		return self:value(id)
	end

	function layer:recover(id: string, amount: number, source: RecoverySource): number
		if not Dissonance.RECOVERY_SOURCES[source] then
			error("Dissonance: unknown recovery source " .. tostring(source), 2)
		end
		if sim:get(id) == nil or not isFinite(amount) or amount <= 0 then
			return self:value(id)
		end
		set(id, self:value(id) - math.min(amount, MAX_CHANGE), source)
		return self:value(id)
	end

	function layer:perform(id: string, actionId: string): ActionMachine.Outcome
		local actor = sim:get(id)
		if actor == nil then
			return { ok = false, reason = "unknown combatant" } :: any
		end
		local def = actions[actionId]
		if def == nil then
			return { ok = false, reason = "unknown action" } :: any
		end
		if (actor.action.state :: string) == "Dead" or Resources.isDead(actor.resources) then
			return { ok = false, reason = "dead" } :: any
		end
		local level = self:level(id)
		if level < def.minLevel then
			return { ok = false, reason = "dissonance too low" } :: any
		end
		local step = sim:stepNumber()
		local byAction = readyAt[id] or {}
		if (byAction[actionId] or 0) > step then
			return { ok = false, reason = "cooldown" } :: any
		end
		if def.consume > 0 and self:value(id) < def.consume then
			return { ok = false, reason = "dissonance too low" } :: any
		end
		byAction[actionId] = step + def.cooldownSteps
		readyAt[id] = byAction
		if def.consume ~= 0 then
			set(id, self:value(id) - def.consume, actionId)
		end
		sim:emit("dissonance_action", id, { actionId = actionId, level = level })
		def.effect({ sim = sim, actor = actor, actionId = actionId, level = level, step = step })
		return { ok = true } :: any
	end

	sim:onStep(function(_step: number)
		local ids: { string } = {}
		for id in meters do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			if sim:get(id) == nil then
				meters[id] = nil
				levels[id] = nil
				continue
			end
			-- Passive recovery happens only in a stable environment, and
			-- only once its rate has been approved.
			if
				stableRecoveryPerStep ~= nil
				and inStableEnvironment ~= nil
				and meters[id] > 0
				and inStableEnvironment(id)
			then
				set(id, meters[id] - stableRecoveryPerStep, "stableEnvironment")
			end
		end
	end)

	function layer:forget(id: string)
		meters[id] = nil
		levels[id] = nil
		readyAt[id] = nil
	end

	return table.freeze(layer) :: any
end

return table.freeze(Dissonance)
