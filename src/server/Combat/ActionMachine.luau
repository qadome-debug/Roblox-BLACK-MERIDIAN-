--!strict
-- Combat action state machine (BM-054).
--
-- Every combatant is in exactly one action state, and every timed state
-- moves through Windup -> Active -> Recovery in whole simulation steps.
-- Durations are counted in steps, never in seconds, so a client cannot
-- shorten them by manipulating timing, and two servers stepping the same
-- inputs reach the same state. Transitions are a fixed table: anything
-- not listed is impossible and is rejected with a reason.
--
-- The machine is pure: it changes the state table it is given and returns
-- outcomes. Resource costs, hit resolution and defensive outcomes live
-- in their own modules (BM-053, BM-055..057) and consult this one.

export type ActionKind = "Attack" | "Dodge" | "Guard" | "Parry" | "Release"

-- Busy states correspond to kinds; Hit and Staggered are entered by damage
-- resolution (BM-056/BM-057), never by an intent.
export type ActionState =
	"Idle"
	| "Attacking"
	| "Dodging"
	| "Guarding"
	| "Parrying"
	| "Hit"
	| "Staggered"
	| "Dead"

export type Phase = "None" | "Windup" | "Active" | "Recovery"

export type Cost = { pool: "stamina" | "posture", amount: number }

export type ActionDef = {
	kind: ActionKind,
	-- Steps per phase. `active = HELD` means the phase lasts until Release.
	windup: number,
	active: number,
	recovery: number,
	cost: Cost?,
	-- Kinds that may interrupt this action, and from which phase/frame.
	-- Cancelling during Active is allowed only for held actions.
	cancelInto: { ActionKind },
	cancelFromRecoveryFrame: number,
}

export type State = {
	state: ActionState,
	phase: Phase,
	-- Definition of the action in progress (nil while Idle/Hit/Dead).
	def: ActionDef?,
	-- Step at which the current action started and the current phase ends.
	startedStep: number,
	phaseEndsStep: number,
	-- Monotonic count of actions started; lets hit resolution tell two
	-- swings apart (one hit per swing).
	actionId: number,
}

export type Outcome = { ok: true } | { ok: false, reason: string }

local ActionMachine = {}

ActionMachine.HELD = math.huge

local KINDS: { ActionKind } = { "Attack", "Dodge", "Guard", "Parry", "Release" }
ActionMachine.KINDS = table.freeze(KINDS)

local BUSY_STATE: { [string]: ActionState } = {
	Attack = "Attacking",
	Dodge = "Dodging",
	Guard = "Guarding",
	Parry = "Parrying",
}

-- Placeholder tuning for the vertical slice at 30 steps per second. Real
-- values come from weapon and Cant definitions (BM-061, BM-063) and the
-- balance harness (BM-072); these keep the machine testable.
local DEFAULT_ACTIONS: { [string]: ActionDef } = {
	Attack = {
		kind = "Attack",
		windup = 6,
		active = 4,
		recovery = 10,
		cost = { pool = "stamina", amount = 20 },
		cancelInto = { "Dodge", "Guard" },
		cancelFromRecoveryFrame = 5,
	},
	Dodge = {
		kind = "Dodge",
		windup = 0,
		active = 8,
		recovery = 6,
		cost = { pool = "stamina", amount = 25 },
		cancelInto = {},
		cancelFromRecoveryFrame = math.huge,
	},
	Guard = {
		kind = "Guard",
		windup = 2,
		active = ActionMachine.HELD,
		recovery = 4,
		cost = nil,
		cancelInto = { "Attack", "Dodge", "Parry", "Release" },
		cancelFromRecoveryFrame = math.huge,
	},
	Parry = {
		kind = "Parry",
		windup = 2,
		active = 5,
		recovery = 12,
		cost = { pool = "stamina", amount = 15 },
		cancelInto = {},
		cancelFromRecoveryFrame = math.huge,
	},
}

for _, def in DEFAULT_ACTIONS do
	table.freeze(def.cancelInto)
	table.freeze(def)
end
ActionMachine.DEFAULT_ACTIONS = table.freeze(DEFAULT_ACTIONS)

local function isStepCount(value: unknown, allowHeld: boolean): boolean
	if type(value) ~= "number" or value ~= value or value < 0 then
		return false
	end
	if value == math.huge then
		return allowHeld
	end
	return value % 1 == 0 and value <= 10000
end

function ActionMachine.validateDef(value: unknown): { string }
	local problems = {}
	if type(value) ~= "table" then
		return { "action definition must be a table" }
	end
	local d = value :: { [any]: unknown }
	if table.find(KINDS, d.kind :: ActionKind) == nil or d.kind == "Release" then
		table.insert(problems, "kind must be a timed action kind")
	end
	if not isStepCount(d.windup, false) then
		table.insert(problems, "windup must be a whole number of steps")
	end
	if not isStepCount(d.active, true) then
		table.insert(problems, "active must be a whole number of steps or HELD")
	end
	if not isStepCount(d.recovery, false) then
		table.insert(problems, "recovery must be a whole number of steps")
	end
	if d.windup == 0 and d.active == 0 and d.recovery == 0 then
		table.insert(problems, "an action must take at least one step")
	end
	if d.cost ~= nil then
		local cost = d.cost :: { [any]: unknown }
		if type(cost) ~= "table" or (cost.pool ~= "stamina" and cost.pool ~= "posture") then
			table.insert(problems, "cost pool must be stamina or posture")
		elseif
			type(cost.amount) ~= "number"
			or cost.amount ~= cost.amount
			or (cost.amount :: number) < 0
		then
			table.insert(problems, "cost amount must be a nonnegative number")
		end
	end
	if type(d.cancelInto) ~= "table" then
		table.insert(problems, "cancelInto must be a list")
	else
		for _, kind in d.cancelInto :: { unknown } do
			if table.find(KINDS, kind :: ActionKind) == nil then
				table.insert(problems, "cancelInto has an unknown kind " .. tostring(kind))
			end
		end
	end
	if not isStepCount(d.cancelFromRecoveryFrame, true) then
		table.insert(problems, "cancelFromRecoveryFrame must be a step count or HELD")
	end
	return problems
end

function ActionMachine.new(): State
	return {
		state = "Idle",
		phase = "None",
		def = nil,
		startedStep = 0,
		phaseEndsStep = 0,
		actionId = 0,
	}
end

local function enterPhase(state: State, phase: Phase, length: number, step: number)
	state.phase = phase
	state.phaseEndsStep = if length == math.huge then math.huge else step + length
end

-- Enters the first non-empty phase of `def` at `step`.
local function start(state: State, def: ActionDef, step: number)
	local busy: ActionState = BUSY_STATE[def.kind] :: any
	state.state = busy
	state.def = def
	state.startedStep = step
	state.actionId += 1
	if def.windup > 0 then
		enterPhase(state, "Windup", def.windup, step)
	elseif def.active > 0 then
		enterPhase(state, "Active", def.active, step)
	else
		enterPhase(state, "Recovery", def.recovery, step)
	end
end

local function finish(state: State)
	state.state = "Idle"
	state.phase = "None"
	state.def = nil
	state.phaseEndsStep = 0
end

-- Whether an intent of `kind` may start now. Pure: does not change state.
function ActionMachine.canStart(state: State, kind: ActionKind, step: number): Outcome
	if table.find(KINDS, kind) == nil then
		return { ok = false, reason = "unknown action kind" }
	end
	if state.state == "Dead" then
		return { ok = false, reason = "dead" }
	end
	if state.state == "Hit" or state.state == "Staggered" then
		return { ok = false, reason = "interrupted" }
	end
	if state.state == "Idle" then
		if kind == "Release" then
			return { ok = false, reason = "nothing to release" }
		end
		return { ok = true }
	end
	local def = state.def
	if def == nil then
		return { ok = false, reason = "corrupt state" }
	end
	if table.find(def.cancelInto, kind) == nil then
		return { ok = false, reason = "cannot interrupt " .. state.state }
	end
	if state.phase == "Windup" then
		return { ok = false, reason = "committed to windup" }
	end
	if state.phase == "Active" then
		if def.active == math.huge then
			return { ok = true }
		end
		return { ok = false, reason = "committed to active frames" }
	end
	-- Recovery: cancel only once enough recovery frames have passed.
	local recoveryStart = state.phaseEndsStep - def.recovery
	if step - recoveryStart < def.cancelFromRecoveryFrame then
		return { ok = false, reason = "too early to cancel recovery" }
	end
	return { ok = true }
end

-- Starts an action (or releases a held one) if the transition is legal.
function ActionMachine.apply(
	state: State,
	kind: ActionKind,
	defs: { [string]: ActionDef },
	step: number
): Outcome
	local outcome = ActionMachine.canStart(state, kind, step)
	if not outcome.ok then
		return outcome
	end
	if kind == "Release" then
		local def = state.def :: ActionDef
		enterPhase(state, "Recovery", def.recovery, step)
		if def.recovery == 0 then
			finish(state)
		end
		return { ok = true }
	end
	local def = defs[kind]
	if def == nil then
		return { ok = false, reason = "no definition for " .. kind }
	end
	start(state, def, step)
	return { ok = true }
end

-- Forces an interruption (hit stun or stagger) for `steps`. Used by
-- damage resolution; never by an intent.
function ActionMachine.interrupt(
	state: State,
	kind: "Hit" | "Staggered",
	steps: number,
	step: number
)
	if state.state == "Dead" then
		return
	end
	state.state = kind
	state.def = nil
	state.startedStep = step
	state.actionId += 1
	enterPhase(state, "Recovery", math.max(1, steps), step)
end

function ActionMachine.kill(state: State)
	state.state = "Dead"
	state.phase = "None"
	state.def = nil
	state.phaseEndsStep = math.huge
end

-- Advances to `step`, moving through phase boundaries that have passed.
-- Returns the phases entered during this advance, in order, so the
-- simulation can emit events ("Active" means hit frames began).
function ActionMachine.advance(state: State, step: number): { Phase }
	local entered: { Phase } = {}
	if state.state == "Idle" or state.state == "Dead" then
		return entered
	end
	while state.phaseEndsStep ~= math.huge and step >= state.phaseEndsStep do
		local def = state.def
		if def == nil then
			-- Hit/Staggered: a single recovery phase.
			finish(state)
			table.insert(entered, "None")
			break
		end
		local boundary = state.phaseEndsStep
		if state.phase == "Windup" then
			if def.active > 0 then
				enterPhase(state, "Active", def.active, boundary)
				table.insert(entered, "Active")
			else
				enterPhase(state, "Recovery", def.recovery, boundary)
				table.insert(entered, "Recovery")
			end
		elseif state.phase == "Active" then
			enterPhase(state, "Recovery", def.recovery, boundary)
			table.insert(entered, "Recovery")
		else
			finish(state)
			table.insert(entered, "None")
			break
		end
	end
	return entered
end

-- Frame index within the current phase (0 on the phase's first step).
function ActionMachine.phaseFrame(state: State, step: number): number
	if state.phase == "None" or state.def == nil then
		return 0
	end
	local def = state.def :: ActionDef
	local length = if state.phase == "Windup"
		then def.windup
		elseif state.phase == "Active" then def.active
		else def.recovery
	if length == math.huge then
		return step - state.startedStep - def.windup
	end
	return step - (state.phaseEndsStep - length)
end

function ActionMachine.isBusy(state: State): boolean
	return state.state ~= "Idle"
end

return table.freeze(ActionMachine)
