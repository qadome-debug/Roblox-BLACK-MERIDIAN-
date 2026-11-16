--!strict
-- Dissonance meter (BM-068).
--
-- A per-combatant meter owned by the server. It rises when the server says
-- so (for example when a Verse resolves), decays after a quiet period, and
-- crosses thresholds into numbered levels. Every change happens inside the
-- simulation step order, so transitions are deterministic for a given
-- sequence of steps. Clients never send meter values: the only client path
-- is `perform`, which names an action and is judged here.
--
-- Dissonance actions are data: minimum level, the Dissonance they consume
-- (or add), a step cooldown, and a server effect. The canonical actions,
-- thresholds and rates are not yet in the design inventory, so the
-- production tuning below is provisional and the production action list
-- is empty. No action is invented.

local ActionMachine = require(script.Parent.ActionMachine)
local Resources = require(script.Parent.Resources)
local Simulation = require(script.Parent.Simulation)

export type Tuning = {
	max: number,
	-- Ascending meter values; reaching thresholds[i] means level i.
	thresholds: { number },
	decayPerStep: number,
	decayDelaySteps: number,
	provisional: boolean,
}

export type ActionContext = {
	sim: Simulation.Simulation,
	actor: Simulation.Combatant,
	actionId: string,
	level: number,
	step: number,
}

export type ActionDef = {
	minLevel: number,
	-- Positive consumes Dissonance, negative adds it.
	consume: number,
	cooldownSteps: number,
	effect: (ctx: ActionContext) -> (),
}

export type Deps = {
	tuning: Tuning?,
	actions: { [string]: ActionDef }?,
}

export type Layer = {
	add: (self: Layer, id: string, amount: number, source: string) -> number,
	value: (self: Layer, id: string) -> number,
	level: (self: Layer, id: string) -> number,
	perform: (self: Layer, id: string, actionId: string) -> ActionMachine.Outcome,
	hasAction: (self: Layer, actionId: string) -> boolean,
	forget: (self: Layer, id: string) -> (),
}

local Dissonance = {}

Dissonance.PROVISIONAL_TUNING = table.freeze({
	max = 100,
	thresholds = table.freeze({ 25, 50, 75, 100 }),
	decayPerStep = 0.25,
	decayDelaySteps = 90,
	provisional = true,
} :: Tuning)

Dissonance.PRODUCTION_ACTIONS = table.freeze({} :: { [string]: ActionDef })

local MAX_ADD = 1000

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Dissonance.validateTuning(tuning: unknown): { string }
	if type(tuning) ~= "table" then
		return { "tuning must be a table" }
	end
	local t = tuning :: { [string]: any }
	local problems: { string } = {}
	if not isFinite(t.max) or t.max <= 0 then
		table.insert(problems, "max must be positive")
	end
	if type(t.thresholds) ~= "table" or #t.thresholds == 0 then
		table.insert(problems, "thresholds must be a non-empty list")
	else
		local previous = 0
		for i, at in t.thresholds do
			if not isFinite(at) or at <= previous or (isFinite(t.max) and at > t.max) then
				table.insert(problems, "threshold " .. i .. " must ascend within (0, max]")
				break
			end
			previous = at
		end
	end
	if not isFinite(t.decayPerStep) or t.decayPerStep < 0 then
		table.insert(problems, "decayPerStep must be >= 0")
	end
	if not isFinite(t.decayDelaySteps) or t.decayDelaySteps < 0 then
		table.insert(problems, "decayDelaySteps must be >= 0")
	end
	if type(t.provisional) ~= "boolean" then
		table.insert(problems, "provisional must be a boolean")
	end
	return problems
end

function Dissonance.validateAction(def: unknown, levels: number): { string }
	if type(def) ~= "table" then
		return { "action must be a table" }
	end
	local d = def :: { [string]: any }
	local problems: { string } = {}
	if
		type(d.minLevel) ~= "number"
		or d.minLevel ~= math.floor(d.minLevel)
		or d.minLevel < 0
		or d.minLevel > levels
	then
		table.insert(problems, "minLevel must be an integer in 0.." .. levels)
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
	local tuning = (deps and deps.tuning) or Dissonance.PROVISIONAL_TUNING
	local actions = (deps and deps.actions) or Dissonance.PRODUCTION_ACTIONS
	local problems = Dissonance.validateTuning(tuning)
	for actionId, def in actions do
		for _, p in Dissonance.validateAction(def, #tuning.thresholds) do
			table.insert(problems, actionId .. ": " .. p)
		end
	end
	if #problems > 0 then
		error("Dissonance: invalid configuration: " .. table.concat(problems, "; "), 2)
	end

	local meters: { [string]: number } = {}
	local levels: { [string]: number } = {}
	local lastRise: { [string]: number } = {}
	local readyAt: { [string]: { [string]: number } } = {}

	local function levelFor(value: number): number
		local level = 0
		for i, at in tuning.thresholds do
			if value >= at then
				level = i
			end
		end
		return level
	end

	local function set(id: string, value: number, source: string)
		local clamped = math.clamp(value, 0, tuning.max)
		meters[id] = clamped
		local previous = levels[id] or 0
		local level = levelFor(clamped)
		if level ~= previous then
			levels[id] = level
			sim:emit(
				"dissonance_level_changed",
				id,
				{ level = level, previous = previous, source = source }
			)
		end
	end

	local layer = {} :: Layer

	function layer:value(id: string): number
		return meters[id] or 0
	end

	function layer:level(id: string): number
		return levels[id] or 0
	end

	function layer:hasAction(actionId: string): boolean
		return actions[actionId] ~= nil
	end

	function layer:add(id: string, amount: number, source: string): number
		local combatant = sim:get(id)
		if combatant == nil or not isFinite(amount) or amount <= 0 then
			return self:value(id)
		end
		lastRise[id] = sim:stepNumber()
		set(id, self:value(id) + math.min(amount, MAX_ADD), source)
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
		if def.consume > 0 then
			set(id, self:value(id) - def.consume, actionId)
		elseif def.consume < 0 then
			lastRise[id] = step
			set(id, self:value(id) - def.consume, actionId)
		end
		sim:emit("dissonance_action", id, { actionId = actionId, level = level })
		def.effect({ sim = sim, actor = actor, actionId = actionId, level = level, step = step })
		return { ok = true } :: any
	end

	sim:onStep(function(step: number)
		local ids: { string } = {}
		for id in meters do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			if sim:get(id) == nil then
				meters[id] = nil
				levels[id] = nil
				lastRise[id] = nil
				continue
			end
			local value = meters[id]
			if value > 0 and step - (lastRise[id] or 0) >= tuning.decayDelaySteps then
				set(id, value - tuning.decayPerStep, "decay")
			end
		end
	end)

	function layer:forget(id: string)
		meters[id] = nil
		levels[id] = nil
		lastRise[id] = nil
		readyAt[id] = nil
	end

	return table.freeze(layer) :: any
end

return table.freeze(Dissonance)
