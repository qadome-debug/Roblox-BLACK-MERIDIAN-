--!strict
-- Cant activation layer (BM-063).
--
-- Server-resolved activation for equipped Cants inside the combat
-- simulation. A request names only the activation; everything else is
-- judged here, at the step, from server state:
--
--   * the combatant has that Cant equipped (equipping is server-owned);
--   * it is alive and in a combat state the Cant allows;
--   * the Cant's cooldown has elapsed (counted in simulation steps);
--   * it can afford the cost, which is spent atomically on success.
--
-- What the Cant then does is its `effect`, resolved on the server with the
-- simulation in hand. Effects never take client data.
--
-- PLACEHOLDER: no client request for activating a Cant has been
-- specified, so `activate` is reachable only from server code today.
--
-- Tuning (cooldown, cost, usable states, effect) comes from a `Kit` per
-- Cant. Nearness's canonical mechanics are not yet in the design
-- inventory, so its production kit is marked provisional: its effect only
-- announces the activation, and its numbers are placeholders flagged for
-- replacement. No mechanic is invented for it.

local ActionMachine = require(script.Parent.ActionMachine)
local Resources = require(script.Parent.Resources)
local Simulation = require(script.Parent.Simulation)

type Combatant = Simulation.Combatant

export type Context = {
	sim: Simulation.Simulation,
	caster: Combatant,
	cantId: string,
	step: number,
}

export type Kit = {
	cooldownSteps: number,
	cost: { pool: Resources.Pool, amount: number }?,
	usableIn: { ActionMachine.ActionState },
	effect: (ctx: Context) -> (),
	provisional: boolean,
}

export type Deps = {
	kits: { [string]: Kit },
	-- Optional catalog check, e.g. CantCatalog:resolve. Unknown Cants are
	-- refused even if a kit exists for them.
	resolve: ((value: unknown) -> string?)?,
}

export type Layer = {
	equip: (self: Layer, id: string, cantId: string?) -> ActionMachine.Outcome,
	equipped: (self: Layer, id: string) -> string?,
	activate: (self: Layer, id: string) -> ActionMachine.Outcome,
	cooldownRemaining: (self: Layer, id: string) -> number,
	forget: (self: Layer, id: string) -> (),
}

local Cants = {}

local MAX_COOLDOWN_STEPS = 60 * 60 * 10

local function fail(reason: string): ActionMachine.Outcome
	return { ok = false, reason = reason } :: any
end

local OK: ActionMachine.Outcome = { ok = true } :: any

-- Returns every problem with a kit; empty when it is usable.
function Cants.validateKit(kit: unknown): { string }
	local problems: { string } = {}
	if type(kit) ~= "table" then
		return { "kit must be a table" }
	end
	local k = kit :: { [string]: any }
	local cd = k.cooldownSteps
	if type(cd) ~= "number" or cd ~= math.floor(cd) or cd < 0 or cd > MAX_COOLDOWN_STEPS then
		table.insert(problems, "cooldownSteps must be an integer in 0.." .. MAX_COOLDOWN_STEPS)
	end
	if k.cost ~= nil then
		local cost = k.cost
		if
			type(cost) ~= "table"
			or (cost.pool ~= "stamina" and cost.pool ~= "posture" and cost.pool ~= "health")
			or type(cost.amount) ~= "number"
			or cost.amount <= 0
			or cost.amount ~= cost.amount
			or cost.amount == math.huge
		then
			table.insert(problems, "cost must name a pool and a positive finite amount")
		end
	end
	if type(k.usableIn) ~= "table" or #k.usableIn == 0 then
		table.insert(problems, "usableIn must list at least one combat state")
	else
		for _, state in k.usableIn do
			if state == "Dead" then
				table.insert(problems, "a Cant can never be usable while Dead")
			end
		end
	end
	if type(k.effect) ~= "function" then
		table.insert(problems, "effect must be a function")
	end
	if type(k.provisional) ~= "boolean" then
		table.insert(problems, "provisional must be a boolean")
	end
	return problems
end

function Cants.attach(sim: Simulation.Simulation, deps: Deps): Layer
	for cantId, kit in deps.kits do
		local problems = Cants.validateKit(kit)
		if #problems > 0 then
			error("Cants: kit " .. cantId .. " is invalid: " .. table.concat(problems, "; "), 2)
		end
	end

	local equippedBy: { [string]: string } = {}
	local readyAt: { [string]: number } = {}

	local layer = {} :: Layer

	function layer:equip(id: string, cantId: string?): ActionMachine.Outcome
		local combatant = sim:get(id)
		if combatant == nil then
			return fail("unknown combatant")
		end
		if cantId == nil then
			equippedBy[id] = nil
			return OK
		end
		if deps.resolve ~= nil and deps.resolve(cantId) == nil then
			return fail("unknown cant")
		end
		if deps.kits[cantId] == nil then
			return fail("cant not available")
		end
		if (combatant.action.state :: string) ~= "Idle" then
			return fail("busy")
		end
		if equippedBy[id] ~= cantId then
			equippedBy[id] = cantId
			-- Swapping never skips a cooldown: the timer belongs to the
			-- combatant, not to the Cant.
		end
		return OK
	end

	function layer:equipped(id: string): string?
		return equippedBy[id]
	end

	function layer:cooldownRemaining(id: string): number
		local at = readyAt[id]
		if at == nil then
			return 0
		end
		return math.max(0, at - sim:stepNumber())
	end

	function layer:activate(id: string): ActionMachine.Outcome
		local caster = sim:get(id)
		if caster == nil then
			return fail("unknown combatant")
		end
		local cantId = equippedBy[id]
		if cantId == nil then
			return fail("no cant equipped")
		end
		local kit = deps.kits[cantId]
		if kit == nil then
			return fail("cant not available")
		end
		local state = caster.action.state
		if (state :: string) == "Dead" or Resources.isDead(caster.resources) then
			return fail("dead")
		end
		if table.find(kit.usableIn, state) == nil then
			return fail("not usable now")
		end
		if self:cooldownRemaining(id) > 0 then
			return fail("cooldown")
		end
		local step = sim:stepNumber()
		local cost = kit.cost
		if cost ~= nil then
			if not Resources.canAfford(caster.resources, cost.pool, cost.amount) then
				return fail("cannot afford")
			end
			Resources.spend(caster.resources, cost.pool, cost.amount, sim:now())
		end
		readyAt[id] = step + kit.cooldownSteps
		sim:emit("cant_activated", id, { cantId = cantId, provisional = kit.provisional })
		kit.effect({ sim = sim, caster = caster, cantId = cantId, step = step })
		return OK
	end

	function layer:forget(id: string)
		equippedBy[id] = nil
		readyAt[id] = nil
	end

	return table.freeze(layer) :: any
end

-- Production kits. Nearness: placeholders until its canonical mechanics
-- are supplied (see docs/task-log.md, Blockers). The effect does nothing
-- beyond the activation event.
Cants.PRODUCTION_KITS = table.freeze({
	["cant-nearness"] = table.freeze({
		cooldownSteps = 60,
		cost = { pool = "stamina", amount = 20 },
		usableIn = { "Idle", "Guarding" },
		effect = function(_: Context) end,
		provisional = true,
	} :: Kit),
} :: { [string]: Kit })

return table.freeze(Cants)
