--!strict
-- Verse cast pipeline (BM-067).
--
-- Server-resolved Verse casting inside the combat simulation. A cast is
-- judged entirely from server state when it is requested:
--
--   * the caster exists, is alive and is not mid-action;
--   * it is not already casting;
--   * the Verse is defined and compatible with the caster's equipped Cant;
--   * that Verse's cooldown for this caster has elapsed;
--   * every cost is affordable (all are spent together, or none);
--   * a target, when given, exists, is alive, is not the caster and is in
--     range. The target is a hint the server verifies, never a claim.
--
-- A started cast resolves after the Verse's cast steps. Being hit,
-- staggered or killed first interrupts it: the cast fizzles, costs stay
-- spent and the cooldown stays running, so interrupting is never a free
-- retry. Effects run only on the server, with simulation state in hand.

local ActionMachine = require(script.Parent.ActionMachine)
local Cants = require(script.Parent.Cants)
local Resources = require(script.Parent.Resources)
local Simulation = require(script.Parent.Simulation)
local Vec3 = require(game:GetService("ReplicatedStorage").Shared.Sim.Vec3)

export type Context = {
	sim: Simulation.Simulation,
	caster: Simulation.Combatant,
	target: Simulation.Combatant?,
	verseId: string,
	step: number,
}

export type Effect = (ctx: Context) -> ()

-- The parts of a Verse catalog the pipeline reads (VerseCatalog satisfies
-- it; the simulation layer does not depend on Content).
export type VerseDef = {
	costs: { { pool: Resources.Pool, amount: number } },
	castSteps: number,
	cooldownSteps: number,
}

export type Catalog = {
	get: (self: any, id: string) -> any,
	isCompatible: (self: any, verseId: string, cantId: string) -> boolean,
}

export type Deps = {
	catalog: Catalog,
	cants: Cants.Layer,
	effects: { [string]: Effect }?,
	maxTargetRange: number?,
}

export type Cast = { verseId: string, target: string?, startedStep: number, resolveStep: number }

export type Layer = {
	cast: (self: Layer, id: string, verseId: string, target: string?) -> ActionMachine.Outcome,
	casting: (self: Layer, id: string) -> Cast?,
	cooldownRemaining: (self: Layer, id: string, verseId: string) -> number,
	forget: (self: Layer, id: string) -> (),
}

local Verses = {}

Verses.DEFAULT_TARGET_RANGE = 40
local CASTABLE_STATES: { [string]: boolean } = { Idle = true, Guarding = true }

local function fail(reason: string): ActionMachine.Outcome
	return { ok = false, reason = reason } :: any
end

local OK: ActionMachine.Outcome = { ok = true } :: any

function Verses.attach(sim: Simulation.Simulation, deps: Deps): Layer
	local effects = deps.effects or {}
	local range = deps.maxTargetRange or Verses.DEFAULT_TARGET_RANGE
	local casts: { [string]: Cast } = {}
	local readyAt: { [string]: { [string]: number } } = {}

	local layer = {} :: Layer

	function layer:casting(id: string): Cast?
		return casts[id]
	end

	function layer:cooldownRemaining(id: string, verseId: string): number
		local byVerse = readyAt[id]
		local at = if byVerse ~= nil then byVerse[verseId] else nil
		if at == nil then
			return 0
		end
		return math.max(0, at - sim:stepNumber())
	end

	function layer:cast(id: string, verseId: string, targetId: string?): ActionMachine.Outcome
		local caster = sim:get(id)
		if caster == nil then
			return fail("unknown combatant")
		end
		if (caster.action.state :: string) == "Dead" or Resources.isDead(caster.resources) then
			return fail("dead")
		end
		if not CASTABLE_STATES[caster.action.state :: string] then
			return fail("busy")
		end
		if casts[id] ~= nil then
			return fail("already casting")
		end
		local def: VerseDef? = deps.catalog:get(verseId)
		if def == nil then
			return fail("unknown verse")
		end
		local equipped = deps.cants:equipped(id)
		if equipped == nil then
			return fail("no cant equipped")
		end
		if not deps.catalog:isCompatible(verseId, equipped) then
			return fail("incompatible cant")
		end
		if self:cooldownRemaining(id, verseId) > 0 then
			return fail("cooldown")
		end
		for _, cost in def.costs do
			if not Resources.canAfford(caster.resources, cost.pool, cost.amount) then
				return fail("cannot afford")
			end
		end
		if targetId ~= nil then
			if targetId == id then
				return fail("cannot target yourself")
			end
			local target = sim:get(targetId)
			if target == nil then
				return fail("unknown target")
			end
			if (target.action.state :: string) == "Dead" or Resources.isDead(target.resources) then
				return fail("target is dead")
			end
			if Vec3.distance(caster.position, target.position) > range then
				return fail("target out of range")
			end
		end

		local step = sim:stepNumber()
		for _, cost in def.costs do
			Resources.spend(caster.resources, cost.pool, cost.amount, sim:now())
		end
		local byVerse = readyAt[id] or {}
		byVerse[verseId] = step + def.cooldownSteps
		readyAt[id] = byVerse
		casts[id] = {
			verseId = verseId,
			target = targetId,
			startedStep = step,
			resolveStep = step + def.castSteps,
		}
		sim:emit("verse_cast_started", id, { verseId = verseId, target = targetId })
		return OK
	end

	local function resolve(id: string, cast: Cast, step: number)
		casts[id] = nil
		local caster = sim:get(id)
		if caster == nil then
			return
		end
		local target = if cast.target ~= nil then sim:get(cast.target) else nil
		if
			cast.target ~= nil and (target == nil or Resources.isDead((target :: any).resources))
		then
			sim:emit("verse_fizzled", id, { verseId = cast.verseId, reason = "target lost" })
			return
		end
		sim:emit("verse_resolved", id, { verseId = cast.verseId, target = cast.target })
		local effect = effects[cast.verseId]
		if effect ~= nil then
			effect({
				sim = sim,
				caster = caster,
				target = target,
				verseId = cast.verseId,
				step = step,
			})
		end
	end

	sim:onStep(function(step: number)
		local ids: { string } = {}
		for id in casts do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local cast = casts[id]
			local caster = sim:get(id)
			if caster == nil then
				casts[id] = nil
				continue
			end
			local state = caster.action.state :: string
			if state == "Hit" or state == "Staggered" or state == "Dead" then
				casts[id] = nil
				sim:emit("verse_interrupted", id, { verseId = cast.verseId })
			elseif step >= cast.resolveStep then
				resolve(id, cast, step)
			end
		end
	end)

	function layer:forget(id: string)
		casts[id] = nil
		readyAt[id] = nil
	end

	return table.freeze(layer) :: any
end

return table.freeze(Verses)
