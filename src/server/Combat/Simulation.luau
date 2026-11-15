--!strict
-- Fixed-step authoritative combat simulation (BM-054).
--
-- The simulation owns every combatant's attributes, resources, action
-- state and position. Clients (through the CombatInput adapter, BM-061)
-- and AI (BM-058) only submit intents; the simulation decides, at step
-- boundaries, whether each intent is legal and what happens. Timing comes
-- solely from the server's step counter: an intent carries a sequence
-- number for ordering and staleness, never a time.
--
-- Determinism: combatants are processed in id order, intents in sequence
-- order, durations are whole steps, and the only randomness is the
-- injected Rng. Two simulations given the same intents at the same steps
-- produce identical events and snapshots.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionMachine = require(script.Parent.ActionMachine)
local Attributes = require(script.Parent.Attributes)
local FixedStep = require(ReplicatedStorage.Shared.Sim.FixedStep)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Resources = require(script.Parent.Resources)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

export type Intent = {
	kind: ActionMachine.ActionKind,
	-- Strictly increasing per combatant; stale or repeated values are
	-- rejected so a replayed or reordered input cannot act twice.
	sequence: number,
	target: string?,
}

export type CombatantSpec = {
	id: string,
	team: string,
	base: Attributes.Base?,
	modifiers: { Attributes.Modifier }?,
	actions: { [string]: ActionMachine.ActionDef }?,
	position: Vec3.Vec3?,
}

export type Combatant = {
	id: string,
	team: string,
	base: Attributes.Base,
	derived: Attributes.Derived,
	resources: Resources.State,
	action: ActionMachine.State,
	actions: { [string]: ActionMachine.ActionDef },
	position: Vec3.Vec3,
	lastSequence: number,
	pending: { Intent },
	-- Resolution layers (BM-055..057) keep their per-combatant data here.
	extra: { [string]: any },
}

export type Event = { step: number, kind: string, id: string, data: { [string]: any }? }

export type Snapshot = {
	id: string,
	team: string,
	state: ActionMachine.ActionState,
	phase: ActionMachine.Phase,
	health: number,
	stamina: number,
	posture: number,
	position: Vec3.Vec3,
	actionId: number,
}

export type ActiveListener = (combatant: Combatant, frame: number, step: number) -> ()

export type Simulation = {
	stepSeconds: number,
	addCombatant: (self: Simulation, spec: CombatantSpec) -> Combatant,
	removeCombatant: (self: Simulation, id: string) -> boolean,
	get: (self: Simulation, id: string) -> Combatant?,
	ids: (self: Simulation) -> { string },
	-- Queues an intent for the next step. Structural and sequence checks
	-- happen now; state and resource checks happen at the step.
	submit: (self: Simulation, id: string, intent: unknown) -> ActionMachine.Outcome,
	-- Converts elapsed wall time into whole steps and runs them.
	advance: (self: Simulation, elapsed: number) -> number,
	step: (self: Simulation) -> (),
	stepNumber: (self: Simulation) -> number,
	now: (self: Simulation) -> number,
	-- Raw health loss with the death transition. Damage resolution
	-- (BM-056) computes the amount; nothing else calls this.
	damage: (self: Simulation, id: string, amount: number) -> number,
	onActive: (self: Simulation, listener: ActiveListener) -> (),
	drainEvents: (self: Simulation) -> { Event },
	snapshot: (self: Simulation, id: string) -> Snapshot?,
	rng: Rng.Rng,
}

export type Deps = {
	logger: Logger.Logger,
	rng: Rng.Rng,
	stepSeconds: number?,
	maxStepsPerAdvance: number?,
}

local Simulation = {}

Simulation.DEFAULT_STEP_SECONDS = 1 / 30
Simulation.MAX_INTENTS_PER_STEP = 4
Simulation.MAX_COMBATANTS = 256
Simulation.MAX_EVENTS = 4096

local function isId(value: unknown): boolean
	return type(value) == "string" and #(value :: string) > 0 and #(value :: string) <= 64
end

function Simulation.new(deps: Deps): Simulation
	local stepSeconds = deps.stepSeconds or Simulation.DEFAULT_STEP_SECONDS
	local fixed = FixedStep.new(stepSeconds, deps.maxStepsPerAdvance)
	local combatants: { [string]: Combatant } = {}
	local order: { string } = {}
	local events: { Event } = {}
	local listeners: { ActiveListener } = {}
	local currentStep = 0

	local sim = {} :: Simulation
	sim.stepSeconds = stepSeconds
	sim.rng = deps.rng

	local function emit(kind: string, id: string, data: { [string]: any }?)
		if #events >= Simulation.MAX_EVENTS then
			table.remove(events, 1)
		end
		table.insert(events, { step = currentStep, kind = kind, id = id, data = data })
	end

	function sim:addCombatant(spec: CombatantSpec): Combatant
		if not isId(spec.id) then
			error("Simulation:addCombatant: invalid id", 2)
		end
		if combatants[spec.id] ~= nil then
			error("Simulation:addCombatant: duplicate id " .. spec.id, 2)
		end
		if #order >= Simulation.MAX_COMBATANTS then
			error("Simulation:addCombatant: too many combatants", 2)
		end
		if not isId(spec.team) then
			error("Simulation:addCombatant: invalid team", 2)
		end
		local actions = spec.actions or ActionMachine.DEFAULT_ACTIONS
		for name, def in actions do
			local problems = ActionMachine.validateDef(def)
			if #problems > 0 or def.kind ~= name then
				error(
					"Simulation:addCombatant: action "
						.. tostring(name)
						.. ": "
						.. table.concat(problems, "; "),
					2
				)
			end
		end
		local base = spec.base or Attributes.DEFAULT_BASE
		local derived = Attributes.derive(base, spec.modifiers)
		local position = spec.position or Vec3.new(0, 0, 0)
		if not Vec3.isFinite(position) then
			error("Simulation:addCombatant: position must be finite", 2)
		end
		local combatant: Combatant = {
			id = spec.id,
			team = spec.team,
			base = base,
			derived = derived,
			resources = Resources.new(derived),
			action = ActionMachine.new(),
			actions = actions,
			position = Vec3.copy(position),
			lastSequence = 0,
			pending = {},
			extra = {},
		}
		combatants[spec.id] = combatant
		table.insert(order, spec.id)
		table.sort(order)
		emit("combatant_added", spec.id, { team = spec.team })
		return combatant
	end

	function sim:removeCombatant(id: string): boolean
		if combatants[id] == nil then
			return false
		end
		combatants[id] = nil
		local index = table.find(order, id)
		if index ~= nil then
			table.remove(order, index)
		end
		emit("combatant_removed", id)
		return true
	end

	function sim:get(id: string): Combatant?
		return combatants[id]
	end

	function sim:ids(): { string }
		return table.clone(order)
	end

	function sim:submit(id: string, value: unknown): ActionMachine.Outcome
		local combatant = combatants[id]
		if combatant == nil then
			return { ok = false, reason = "unknown combatant" }
		end
		if type(value) ~= "table" then
			return { ok = false, reason = "intent must be a table" }
		end
		local raw = value :: { [any]: unknown }
		for key in raw do
			if key ~= "kind" and key ~= "sequence" and key ~= "target" then
				return { ok = false, reason = "unknown intent field" }
			end
		end
		if
			type(raw.kind) ~= "string"
			or table.find(ActionMachine.KINDS, raw.kind :: ActionMachine.ActionKind) == nil
		then
			return { ok = false, reason = "unknown action kind" }
		end
		local sequence = raw.sequence
		if
			type(sequence) ~= "number"
			or sequence ~= sequence
			or sequence % 1 ~= 0
			or sequence <= 0
		then
			return { ok = false, reason = "sequence must be a positive integer" }
		end
		if raw.target ~= nil and not isId(raw.target) then
			return { ok = false, reason = "invalid target" }
		end
		local last = combatant.lastSequence
		local queued = combatant.pending[#combatant.pending]
		if queued ~= nil then
			last = math.max(last, queued.sequence)
		end
		if sequence <= last then
			return { ok = false, reason = "stale sequence" }
		end
		if #combatant.pending >= Simulation.MAX_INTENTS_PER_STEP then
			return { ok = false, reason = "too many intents this step" }
		end
		table.insert(combatant.pending, {
			kind = raw.kind :: ActionMachine.ActionKind,
			sequence = sequence,
			target = raw.target :: string?,
		})
		return { ok = true }
	end

	local function reject(combatant: Combatant, intent: Intent, reason: string)
		emit(
			"intent_rejected",
			combatant.id,
			{ kind = intent.kind, sequence = intent.sequence, reason = reason }
		)
		deps.logger:log("debug", "gameplay", "combat_intent_rejected", {
			combatant = combatant.id,
			kind = intent.kind,
			reason = reason,
		})
	end

	local function processIntents(combatant: Combatant)
		local pending = combatant.pending
		combatant.pending = {}
		for _, intent in pending do
			combatant.lastSequence = math.max(combatant.lastSequence, intent.sequence)
			local can = ActionMachine.canStart(combatant.action, intent.kind, currentStep)
			if not can.ok then
				reject(combatant, intent, (can :: any).reason)
				continue
			end
			local def = combatant.actions[intent.kind]
			local cost = if def ~= nil then def.cost else nil
			if
				cost ~= nil and not Resources.canAfford(combatant.resources, cost.pool, cost.amount)
			then
				reject(combatant, intent, "cannot afford " .. cost.pool)
				continue
			end
			local applied =
				ActionMachine.apply(combatant.action, intent.kind, combatant.actions, currentStep)
			if not applied.ok then
				reject(combatant, intent, (applied :: any).reason)
				continue
			end
			if cost ~= nil then
				Resources.spend(combatant.resources, cost.pool, cost.amount, sim:now())
			end
			emit("action_started", combatant.id, {
				kind = intent.kind,
				sequence = intent.sequence,
				actionId = combatant.action.actionId,
				phase = combatant.action.phase,
				target = intent.target,
			})
			if combatant.action.phase == "Active" then
				emit(
					"phase_entered",
					combatant.id,
					{ phase = "Active", actionId = combatant.action.actionId }
				)
			end
		end
	end

	local function advanceAction(combatant: Combatant)
		local action = combatant.action
		local entered = ActionMachine.advance(action, currentStep)
		for _, phase in entered do
			if phase == "None" then
				emit("action_ended", combatant.id, { actionId = action.actionId })
			else
				emit("phase_entered", combatant.id, { phase = phase, actionId = action.actionId })
			end
		end
	end

	function sim:step()
		currentStep += 1
		local now = sim:now()
		for _, id in order do
			local combatant = combatants[id]
			if combatant.action.state == "Dead" then
				combatant.pending = {}
				continue
			end
			-- Phase boundaries first, so a cancel window that opens this
			-- step is visible to this step's intents.
			advanceAction(combatant)
			processIntents(combatant)
			if combatant.action.phase == "Active" then
				local frame = ActionMachine.phaseFrame(combatant.action, currentStep)
				for _, listener in listeners do
					listener(combatant, frame, currentStep)
				end
			end
			Resources.regen(combatant.resources, combatant.derived, now, stepSeconds)
		end
	end

	function sim:advance(elapsed: number): number
		local steps = fixed:accumulate(elapsed)
		for _ = 1, steps do
			sim:step()
		end
		return steps
	end

	function sim:stepNumber(): number
		return currentStep
	end

	function sim:now(): number
		return currentStep * stepSeconds
	end

	function sim:damage(id: string, amount: number): number
		local combatant = combatants[id]
		if combatant == nil or combatant.action.state == "Dead" then
			return 0
		end
		local applied = Resources.damage(combatant.resources, amount)
		if applied > 0 then
			emit("health_changed", id, { applied = applied, health = combatant.resources.health })
		end
		if Resources.isDead(combatant.resources) then
			ActionMachine.kill(combatant.action)
			combatant.pending = {}
			emit("died", id)
		end
		return applied
	end

	function sim:onActive(listener: ActiveListener)
		table.insert(listeners, listener)
	end

	function sim:drainEvents(): { Event }
		local drained = events
		events = {}
		return drained
	end

	function sim:snapshot(id: string): Snapshot?
		local combatant = combatants[id]
		if combatant == nil then
			return nil
		end
		return {
			id = combatant.id,
			team = combatant.team,
			state = combatant.action.state,
			phase = combatant.action.phase,
			health = combatant.resources.health,
			stamina = combatant.resources.stamina,
			posture = combatant.resources.posture,
			position = Vec3.copy(combatant.position),
			actionId = combatant.action.actionId,
		}
	end

	return table.freeze(sim)
end

return table.freeze(Simulation)
