--!strict
-- Client combat view model (BM-060).
--
-- Holds the client's copy of replicated combat state, applies deltas and
-- cues from the server, and reconciles the client's own prediction: when
-- the player presses an action the client may show it at once, tagged
-- with the intent sequence; the server's acknowledged sequence then
-- confirms or snaps it. Nothing here is ever sent back to the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatReplication = require(ReplicatedStorage.Shared.Contracts.CombatReplication)

export type Prediction =
	{ sequence: number, state: CombatReplication.ActionState, startedAt: number }

export type Listener = (event: string, payload: unknown) -> ()

export type Controller = {
	applyDelta: (self: Controller, delta: CombatReplication.Delta) -> (),
	applyCues: (self: Controller, batch: CombatReplication.CueBatch) -> (),
	-- Records a prediction for an intent the client just sent.
	predict: (self: Controller, sequence: number, state: CombatReplication.ActionState) -> (),
	-- State to render for the local player: the prediction while it is
	-- unsettled, the server's state otherwise.
	displayedState: (self: Controller) -> CombatReplication.ActionState,
	own: (self: Controller) -> CombatReplication.OwnCombatant?,
	combatant: (self: Controller, id: string) -> CombatReplication.PublicCombatant?,
	revision: (self: Controller) -> number,
	-- Presentation hooks: "delta", "cue", "corrected".
	on: (self: Controller, listener: Listener) -> (),
}

local CombatState = {}

-- A prediction older than this (in revisions) is dropped even without an
-- acknowledgement, so a lost intent never leaves a ghost animation.
CombatState.PREDICTION_TIMEOUT_REVISIONS = 30

function CombatState.new(): Controller
	local combatants: { [string]: CombatReplication.PublicCombatant } = {}
	local own: CombatReplication.OwnCombatant? = nil
	local revision = 0
	local prediction: Prediction? = nil
	local listeners: { Listener } = {}

	local controller = {} :: Controller

	local function fire(event: string, payload: unknown)
		for _, listener in listeners do
			task.spawn(listener, event, payload)
		end
	end

	local function reconcile()
		local p = prediction
		local view = own
		if p == nil or view == nil then
			return
		end
		if view.ackSequence >= p.sequence then
			prediction = nil
			if view.state ~= p.state then
				fire(
					"corrected",
					{ predicted = p.state, actual = view.state, sequence = p.sequence }
				)
			end
		elseif revision - p.startedAt > CombatState.PREDICTION_TIMEOUT_REVISIONS then
			prediction = nil
			fire(
				"corrected",
				{ predicted = p.state, actual = view.state, sequence = p.sequence, timedOut = true }
			)
		end
	end

	function controller:applyDelta(delta: CombatReplication.Delta)
		if type(delta) ~= "table" or delta.kind ~= "combat" or type(delta.revision) ~= "number" then
			return
		end
		if delta.revision < revision then
			return -- stale; RemoteEvents are ordered, but be safe
		end
		revision = delta.revision
		if delta.full then
			combatants = {}
		end
		for _, view in delta.combatants do
			combatants[view.id] = view
		end
		for _, id in delta.removed do
			combatants[id] = nil
		end
		if delta.own ~= nil then
			own = delta.own
		end
		reconcile()
		fire("delta", delta)
	end

	function controller:applyCues(batch: CombatReplication.CueBatch)
		if type(batch) ~= "table" or batch.kind ~= "cues" then
			return
		end
		for _, cue in batch.cues do
			fire("cue", cue)
		end
	end

	function controller:predict(sequence: number, state: CombatReplication.ActionState)
		prediction = { sequence = sequence, state = state, startedAt = revision }
	end

	function controller:displayedState(): CombatReplication.ActionState
		local p = prediction
		if p ~= nil then
			return p.state
		end
		local view = own
		return if view ~= nil then view.state else "Idle"
	end

	function controller:own(): CombatReplication.OwnCombatant?
		return own
	end

	function controller:combatant(id: string): CombatReplication.PublicCombatant?
		return combatants[id]
	end

	function controller:revision(): number
		return revision
	end

	function controller:on(listener: Listener)
		table.insert(listeners, listener)
	end

	return table.freeze(controller)
end

return table.freeze(CombatState)
