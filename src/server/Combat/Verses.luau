--!strict
-- Verse cast pipeline (BM-067).
--
-- Server-resolved Verse casting inside the combat simulation. A cast is
-- judged entirely from server state when it is requested:
--
--   * the caster exists, is alive and is in a state the Verse allows;
--   * it is not already casting;
--   * the Verse is defined and compatible with the caster's equipped Cant;
--   * that Verse's cooldown for this caster has elapsed;
--   * every cost is affordable (all are spent together, or none);
--   * targets, when needed, exist, are alive, hostile (or the caster, for
--     a pair), in range, in sight and not immune. They are hints the
--     server verifies, never claims.
--
-- A started cast resolves after the Verse's cast time. Being staggered or
-- killed first interrupts it (ordinary damage does not): the cast fizzles,
-- costs stay spent and the cooldown stays running, so interrupting is never
-- a free retry. Effects run only on the server, with simulation state in
-- hand.
--
-- An effect returns false when it could not do anything (for example no
-- valid destination). That cast also fizzles: cost and cooldown stay spent,
-- and no Dissonance is gained. Dissonance is gained only when the Verse
-- actually executes, never for an interrupted or empty cast.

local ActionMachine = require(script.Parent.ActionMachine)
local Cants = require(script.Parent.Cants)
local Resources = require(script.Parent.Resources)
local Simulation = require(script.Parent.Simulation)
local Vec3 = require(game:GetService("ReplicatedStorage").Shared.Sim.Vec3)

export type Context = {
	sim: Simulation.Simulation,
	caster: Simulation.Combatant,
	target: Simulation.Combatant?,
	targetB: Simulation.Combatant?,
	aim: Vec3.Vec3?,
	params: { [string]: number },
	verseId: string,
	step: number,
}

-- Returns false when nothing happened; nil or true is success.
export type Effect = (ctx: Context) -> boolean?

export type Extra = { targetB: string?, aim: Vec3.Vec3? }

export type Cast = {
	verseId: string,
	target: string?,
	targetB: string?,
	aim: Vec3.Vec3?,
	startedStep: number,
	resolveStep: number,
}

-- The parts of a Verse catalog the pipeline reads (VerseCatalog satisfies
-- it; the simulation layer does not depend on Content).
export type VerseDef = {
	-- nil while the design has not established the value; such a Verse
	-- cannot be cast.
	costs: { { pool: Resources.Pool, amount: number } }?,
	castSeconds: number?,
	cooldownSeconds: number,
	targeting: string?,
	castFrom: { string }?,
	effect: string?,
	params: { [string]: number }?,
}

export type Catalog = {
	get: (self: any, id: string) -> any,
	isCompatible: (self: any, verseId: string, cantId: string) -> boolean,
}

export type Deps = {
	catalog: Catalog,
	cants: Cants.Layer,
	-- By Verse ID, or by the definition's `effect` name.
	effects: { [string]: Effect }?,
	maxTargetRange: number?,
	lineOfSight: ((from: Vec3.Vec3, to: Vec3.Vec3) -> boolean)?,
	-- Called after a Verse has actually executed (to raise Dissonance).
	onResolved: ((casterId: string, verseId: string) -> ())?,
}

export type Layer = {
	cast: (
		self: Layer,
		id: string,
		verseId: string,
		target: string?,
		extra: Extra?
	) -> ActionMachine.Outcome,
	casting: (self: Layer, id: string) -> Cast?,
	cooldownRemaining: (self: Layer, id: string, verseId: string) -> number,
	forget: (self: Layer, id: string) -> (),
}

local Verses = {}

Verses.DEFAULT_TARGET_RANGE = 40
Verses.MAX_AIM = 100000
local DEFAULT_CAST_FROM = { "Idle", "Guarding" }

local function fail(reason: string): ActionMachine.Outcome
	return { ok = false, reason = reason } :: any
end

local OK: ActionMachine.Outcome = { ok = true } :: any

-- Whether a combatant can be forced to move. Bosses cannot.
function Verses.isImmune(combatant: Simulation.Combatant): boolean
	return combatant.extra.displacement == "immune"
end

function Verses.attach(sim: Simulation.Simulation, deps: Deps): Layer
	local effects = deps.effects or {}
	local defaultRange = deps.maxTargetRange or Verses.DEFAULT_TARGET_RANGE
	-- The design gives times in seconds; the simulation counts steps.
	local function toSteps(seconds: number): number
		return math.max(0, math.floor(seconds / sim.stepSeconds + 0.5))
	end
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

	local function stateAllows(caster: Simulation.Combatant, castFrom: { string }): boolean
		local state = caster.action.state :: string
		if table.find(castFrom, state) ~= nil then
			return true
		end
		return table.find(castFrom, "AttackRecovery") ~= nil
			and state == "Attacking"
			and (caster.action.phase :: string) == "Recovery"
	end

	-- Checks one target hint. Returns a refusal reason or nil.
	local function checkTarget(
		caster: Simulation.Combatant,
		targetId: string,
		range: number,
		allowSelf: boolean,
		refuseImmune: boolean
	): string?
		if targetId == caster.id then
			return if allowSelf then nil else "cannot target yourself"
		end
		local target = sim:get(targetId)
		if target == nil then
			return "unknown target"
		end
		if (target.action.state :: string) == "Dead" or Resources.isDead(target.resources) then
			return "target is dead"
		end
		if target.team == caster.team then
			return "target is not hostile"
		end
		if Vec3.distance(caster.position, target.position) > range then
			return "target out of range"
		end
		if deps.lineOfSight ~= nil and not deps.lineOfSight(caster.position, target.position) then
			return "target not in sight"
		end
		if refuseImmune and Verses.isImmune(target) then
			return "target immune"
		end
		return nil
	end

	function layer:cast(
		id: string,
		verseId: string,
		targetId: string?,
		extra: Extra?
	): ActionMachine.Outcome
		local caster = sim:get(id)
		if caster == nil then
			return fail("unknown combatant")
		end
		if (caster.action.state :: string) == "Dead" or Resources.isDead(caster.resources) then
			return fail("dead")
		end
		local def: VerseDef? = deps.catalog:get(verseId)
		if def == nil then
			return fail("unknown verse")
		end
		if not stateAllows(caster, def.castFrom or DEFAULT_CAST_FROM) then
			return fail("busy")
		end
		if casts[id] ~= nil then
			return fail("already casting")
		end
		-- A registered Verse whose costs or cast time the design has not
		-- set yet is known but not available. Nothing is assumed for it.
		local costs = def.costs
		local castSeconds = def.castSeconds
		if costs == nil or castSeconds == nil then
			return fail("verse not available")
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
		for _, cost in costs do
			if not Resources.canAfford(caster.resources, cost.pool, cost.amount) then
				return fail("cannot afford")
			end
		end

		local params: { [string]: number } = def.params or ({} :: { [string]: number })
		local range = params.range or defaultRange
		local refuseImmune = (params.refuseImmune or 0) ~= 0
		local targeting = def.targeting
		local aim = if extra ~= nil then extra.aim else nil
		local targetB = if extra ~= nil then extra.targetB else nil
		if aim ~= nil then
			if not Vec3.isFinite(aim) then
				return fail("bad aim")
			end
			if
				math.abs(aim.x) > Verses.MAX_AIM
				or math.abs(aim.y) > Verses.MAX_AIM
				or math.abs(aim.z) > Verses.MAX_AIM
			then
				return fail("bad aim")
			end
		end
		if targeting == "combatant" or targeting == "pair" then
			if targetId == nil then
				return fail("target required")
			end
		end
		if targeting == "pair" then
			if targetB == nil then
				return fail("second target required")
			end
			if targetB == targetId then
				return fail("targets must differ")
			end
		elseif targetB ~= nil then
			return fail("unexpected second target")
		end
		if targetId ~= nil then
			local problem = checkTarget(caster, targetId, range, targeting == "pair", refuseImmune)
			if problem ~= nil then
				return fail(problem)
			end
		end
		if targetB ~= nil then
			local problem = checkTarget(caster, targetB, range, true, refuseImmune)
			if problem ~= nil then
				return fail(problem)
			end
		end

		local step = sim:stepNumber()
		for _, cost in costs do
			Resources.spend(caster.resources, cost.pool, cost.amount, sim:now())
		end
		local byVerse = readyAt[id] or {}
		byVerse[verseId] = step + toSteps(def.cooldownSeconds)
		readyAt[id] = byVerse
		casts[id] = {
			verseId = verseId,
			target = targetId,
			targetB = targetB,
			aim = if aim ~= nil then Vec3.copy(aim) else nil,
			startedStep = step,
			resolveStep = step + toSteps(castSeconds),
		}
		sim:emit("verse_cast_started", id, { verseId = verseId, target = targetId })
		return OK
	end

	local function alive(combatant: Simulation.Combatant?): boolean
		return combatant ~= nil
			and (combatant.action.state :: string) ~= "Dead"
			and not Resources.isDead(combatant.resources)
	end

	local function resolve(id: string, cast: Cast, step: number)
		casts[id] = nil
		local caster = sim:get(id)
		if caster == nil then
			return
		end
		local target = if cast.target ~= nil then sim:get(cast.target) else nil
		local targetB = if cast.targetB ~= nil then sim:get(cast.targetB) else nil
		if
			(cast.target ~= nil and not alive(target))
			or (cast.targetB ~= nil and not alive(targetB))
		then
			sim:emit("verse_fizzled", id, { verseId = cast.verseId, reason = "target lost" })
			return
		end
		local def: VerseDef? = deps.catalog:get(cast.verseId)
		local effect = effects[cast.verseId]
		if effect == nil and def ~= nil and def.effect ~= nil then
			effect = effects[def.effect]
		end
		-- A Verse that names an effect nobody provides does nothing, and so
		-- gains nothing: fail closed.
		local succeeded = not (def ~= nil and def.effect ~= nil and effect == nil)
		if effect ~= nil then
			local result = effect({
				sim = sim,
				caster = caster,
				target = target,
				targetB = targetB,
				aim = cast.aim,
				params = if def ~= nil and def.params ~= nil then def.params else {},
				verseId = cast.verseId,
				step = step,
			})
			succeeded = result ~= false
		end
		if not succeeded then
			sim:emit("verse_fizzled", id, { verseId = cast.verseId, reason = "no effect" })
			return
		end
		sim:emit("verse_resolved", id, { verseId = cast.verseId, target = cast.target })
		if deps.onResolved ~= nil then
			deps.onResolved(id, cast.verseId)
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
			-- Only an interruption state stops a cast; ordinary damage does
			-- not.
			if state == "Staggered" or state == "Dead" then
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
