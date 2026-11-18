--!strict
-- Server effects of Burdens.
--
-- A Burden belongs to a Cant. The Burden in force for a combatant is the
-- Cant's default Burden, unless the player has unlocked mastery and chosen
-- one of the Cant's mastery Burdens (BurdenCatalog.activeFor). This layer
-- applies whatever effect that Burden names.
--
-- Implemented effect:
--
--   stamina_regen_penalty   (Long Way Home) Each qualifying Nearness move
--     lowers stamina regeneration by `perMove` (a fraction), up to `cap`.
--     The penalty is cleared when the combatant reaches stable ground. A
--     qualifying move is a Close Step; being pulled or tethered is not one.
--     Initial test values: 10% per move, capped at 50%.
--
-- Not implemented, by design: Unwanted Company (the default Nearness
-- Burden) has no effect until a behaviour-based version is approved
-- (docs/unwanted-company-proposal.md). A Burden without an effect changes
-- nothing. An effect name this layer does not know changes nothing either.
--
-- Stable ground is whatever the injected check says. Until the world
-- defines it, nothing is stable and a penalty clears only when the Burden
-- is removed, for example by re-equipping the Cant.

local Simulation = require(script.Parent.Simulation)

export type Def = { effect: string?, params: { [string]: number }? }

-- The part of the Burden catalog this layer reads.
export type Catalog = {
	get: (self: any, id: string) -> any,
	activeFor: (self: any, cantId: string, chosen: string?, masteryUnlocked: boolean) -> string?,
}

export type Deps = {
	catalog: Catalog,
	-- Whether a combatant stands on stable ground right now.
	inStableEnvironment: ((id: string) -> boolean)?,
}

export type Layer = {
	-- Re-resolves the Burden after the equipped Cant changed.
	sync: (
		self: Layer,
		id: string,
		cantId: string?,
		chosen: string?,
		masteryUnlocked: boolean
	) -> string?,
	active: (self: Layer, id: string) -> string?,
	onNearnessMove: (self: Layer, id: string) -> (),
	-- Current stamina regeneration penalty as a fraction, 0 to cap.
	penalty: (self: Layer, id: string) -> number,
	moves: (self: Layer, id: string) -> number,
	tick: (self: Layer) -> (),
	forget: (self: Layer, id: string) -> (),
	reset: (self: Layer, id: string) -> (),
}

local BurdenEffects = {}

type State = { burdenId: string, def: Def, moves: number, baseRegen: number }

function BurdenEffects.attach(sim: Simulation.Simulation, deps: Deps): Layer
	local states: { [string]: State } = {}

	local function apply(id: string, state: State)
		local combatant = sim:get(id)
		if combatant == nil then
			return
		end
		local penalty = 0
		local params = state.def.params
		if state.def.effect == "stamina_regen_penalty" and params ~= nil then
			penalty = math.min(params.cap or 0, (params.perMove or 0) * state.moves)
		end
		combatant.derived.staminaRegen = state.baseRegen * (1 - penalty)
	end

	local function release(id: string)
		local state = states[id]
		if state == nil then
			return
		end
		states[id] = nil
		local combatant = sim:get(id)
		if combatant ~= nil then
			combatant.derived.staminaRegen = state.baseRegen
		end
	end

	local layer = {} :: Layer

	function layer:sync(
		id: string,
		cantId: string?,
		chosen: string?,
		masteryUnlocked: boolean
	): string?
		release(id)
		local combatant = sim:get(id)
		if combatant == nil or cantId == nil then
			return nil
		end
		local burdenId = deps.catalog:activeFor(cantId, chosen, masteryUnlocked)
		if burdenId == nil then
			return nil
		end
		local def = deps.catalog:get(burdenId)
		states[id] = {
			burdenId = burdenId,
			def = { effect = def.effect, params = def.params },
			moves = 0,
			baseRegen = combatant.derived.staminaRegen,
		}
		return burdenId
	end

	function layer:active(id: string): string?
		local state = states[id]
		return if state ~= nil then state.burdenId else nil
	end

	function layer:onNearnessMove(id: string)
		local state = states[id]
		if state == nil or state.def.effect ~= "stamina_regen_penalty" then
			return
		end
		state.moves += 1
		apply(id, state)
	end

	function layer:penalty(id: string): number
		local state = states[id]
		local combatant = sim:get(id)
		if state == nil or combatant == nil or state.baseRegen <= 0 then
			return 0
		end
		return 1 - combatant.derived.staminaRegen / state.baseRegen
	end

	function layer:moves(id: string): number
		local state = states[id]
		return if state ~= nil then state.moves else 0
	end

	function layer:tick()
		local check = deps.inStableEnvironment
		if check == nil then
			return
		end
		for id, state in states do
			if state.moves > 0 and check(id) then
				state.moves = 0
				apply(id, state)
			end
		end
	end

	function layer:forget(id: string)
		release(id)
	end

	-- Clears the temporary penalty (the Burden itself stays chosen).
	function layer:reset(id: string)
		local state = states[id]
		if state ~= nil then
			state.moves = 0
			apply(id, state)
		end
	end

	return table.freeze(layer) :: any
end

return table.freeze(BurdenEffects)
