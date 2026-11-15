--!strict
-- Stamina, posture, health: consumption and regeneration (BM-053).
--
-- Pure functions over a resource state. The server checks a cost before an
-- action and spends it only when the action is accepted; regeneration runs
-- per fixed step with a delay after spending, so two actions in the same
-- step compete for the same pool and the second fails if the first drained
-- it. Values never go below zero or above their cap.

local Attributes = require(script.Parent.Attributes)

export type Pool = "stamina" | "posture" | "health"

export type State = {
	health: number,
	stamina: number,
	posture: number,
	-- Simulation time of the last spend per pool; regen waits REGEN_DELAY.
	lastSpent: { stamina: number, posture: number },
	-- Set when posture hit zero; cleared by recovery (BM-057).
	postureBroken: boolean,
}

local Resources = {}

-- Seconds after spending before a pool regenerates.
Resources.REGEN_DELAY = { stamina = 1.0, posture = 2.0 }

local function round2(value: number): number
	return math.floor(value * 100 + 0.5) / 100
end

function Resources.new(derived: Attributes.Derived): State
	return {
		health = derived.maxHealth,
		stamina = derived.maxStamina,
		posture = derived.maxPosture,
		lastSpent = { stamina = -math.huge, posture = -math.huge },
		postureBroken = false,
	}
end

local function isCost(value: unknown): boolean
	return type(value) == "number" and value == value and value >= 0 and value ~= math.huge
end

function Resources.canAfford(state: State, pool: Pool, cost: number): boolean
	if not isCost(cost) then
		return false
	end
	return (state :: any)[pool] >= cost
end

-- Spends from a pool. Returns false and leaves the state untouched when
-- the pool cannot cover the cost.
function Resources.spend(state: State, pool: Pool, cost: number, now: number): boolean
	if not Resources.canAfford(state, pool, cost) then
		return false
	end
	local s = state :: any
	s[pool] = round2(s[pool] - cost)
	if pool == "stamina" or pool == "posture" then
		state.lastSpent[pool] = now
		if pool == "posture" and state.posture <= 0 then
			state.posture = 0
			state.postureBroken = true
		end
	end
	return true
end

-- Applies damage to health; returns the amount actually applied.
function Resources.damage(state: State, amount: number): number
	if not isCost(amount) then
		return 0
	end
	local applied = math.min(state.health, amount)
	state.health = round2(state.health - applied)
	return applied
end

function Resources.isDead(state: State): boolean
	return state.health <= 0
end

-- Restores a pool up to its cap; returns the amount actually restored.
function Resources.restore(
	state: State,
	pool: Pool,
	amount: number,
	derived: Attributes.Derived
): number
	if not isCost(amount) then
		return 0
	end
	local caps =
		{ health = derived.maxHealth, stamina = derived.maxStamina, posture = derived.maxPosture }
	local s = state :: any
	local before = s[pool]
	s[pool] = round2(math.min(caps[pool], before + amount))
	if pool == "posture" and state.posture >= derived.maxPosture * 0.5 then
		state.postureBroken = false
	end
	return s[pool] - before
end

-- One fixed step of regeneration. Health does not regenerate here (that
-- is a Verse or rest effect); stamina and posture do, after their delays.
function Resources.regen(state: State, derived: Attributes.Derived, now: number, dt: number)
	if dt <= 0 then
		return
	end
	if now - state.lastSpent.stamina >= Resources.REGEN_DELAY.stamina then
		Resources.restore(state, "stamina", derived.staminaRegen * dt, derived)
	end
	if now - state.lastSpent.posture >= Resources.REGEN_DELAY.posture then
		Resources.restore(state, "posture", derived.postureRegen * dt, derived)
	end
end

-- Clamps a state to the given caps (after derived stats change, for
-- example when a Burden is removed). Never raises a value.
function Resources.clamp(state: State, derived: Attributes.Derived)
	state.health = math.clamp(state.health, 0, derived.maxHealth)
	state.stamina = math.clamp(state.stamina, 0, derived.maxStamina)
	state.posture = math.clamp(state.posture, 0, derived.maxPosture)
end

function Resources.validate(state: unknown, derived: Attributes.Derived): { string }
	local problems = {}
	if type(state) ~= "table" then
		return { "resource state must be a table" }
	end
	local s = state :: any
	local caps: { [string]: number } =
		{ health = derived.maxHealth, stamina = derived.maxStamina, posture = derived.maxPosture }
	for pool: string, cap: number in caps do
		local value = s[pool]
		if type(value) ~= "number" or value ~= value or value < 0 or value > cap then
			table.insert(problems, pool .. " out of range")
		end
	end
	return problems
end

return table.freeze(Resources)
