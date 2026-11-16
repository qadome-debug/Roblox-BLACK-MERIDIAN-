--!strict
-- Equipped Cant layer (BM-063).
--
-- A Cant is a supernatural discipline. It has no ability of its own: its
-- Verses are the techniques (design report, approved 2026-11-16). In the
-- combat simulation a Cant is therefore only what a combatant has
-- equipped. That decides which Verses the combatant may cast
-- (Combat/Verses) and which Burden applies (Content/BurdenCatalog).
--
-- Equipping is server-owned:
--
--   * the Cant must be one the catalog knows (`resolve`);
--   * the combatant must exist and be idle, so a discipline cannot be
--     swapped in the middle of an action.
--
-- Who owns a Cant, which slot it may sit in and where a player may change
-- it are decided before this layer is reached, by the CantEquip adapter.
--
-- An earlier version gave every Cant a standalone activation with its own
-- cooldown, cost and effect, and gave Nearness a placeholder kit. The
-- design does not support that, so it was removed.

local ActionMachine = require(script.Parent.ActionMachine)
local Simulation = require(script.Parent.Simulation)

export type Deps = {
	-- Catalog check, for example CantCatalog:resolve. Without it every
	-- well-formed ID is accepted (tests only).
	resolve: ((value: unknown) -> string?)?,
}

export type Layer = {
	equip: (self: Layer, id: string, cantId: string?) -> ActionMachine.Outcome,
	equipped: (self: Layer, id: string) -> string?,
	forget: (self: Layer, id: string) -> (),
}

local Cants = {}

local function fail(reason: string): ActionMachine.Outcome
	return { ok = false, reason = reason } :: any
end

local OK: ActionMachine.Outcome = { ok = true } :: any

function Cants.attach(sim: Simulation.Simulation, deps: Deps?): Layer
	local resolve = deps and deps.resolve
	local equippedBy: { [string]: string } = {}

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
		if resolve ~= nil and resolve(cantId) == nil then
			return fail("unknown cant")
		end
		if (combatant.action.state :: string) ~= "Idle" then
			return fail("busy")
		end
		equippedBy[id] = cantId
		return OK
	end

	function layer:equipped(id: string): string?
		return equippedBy[id]
	end

	function layer:forget(id: string)
		equippedBy[id] = nil
	end

	return table.freeze(layer) :: any
end

return table.freeze(Cants)
