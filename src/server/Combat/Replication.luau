--!strict
-- Combat state replication and prediction correction (BM-060).
--
-- Builds what each client is allowed to see. Public views carry only
-- state, phase, swing id and a health fraction; a client's own view adds
-- its exact resources, lock target and the acknowledged intent sequence
-- it needs to correct a mispredicted action. Deltas are incremental
-- against the revision the client last applied and become a full
-- snapshot when that revision is too old to reconstruct (packet delay).
-- Cues are the public subset of simulation events; private rejections
-- reach only the combatant they concern.
--
-- This module is the only consumer of the simulation's event log.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatReplication = require(ReplicatedStorage.Shared.Contracts.CombatReplication)
local Simulation = require(script.Parent.Simulation)
local Targeting = require(script.Parent.Targeting)

export type Delta = CombatReplication.Delta
export type Cue = CombatReplication.Cue
export type PublicCombatant = CombatReplication.PublicCombatant
export type OwnCombatant = CombatReplication.OwnCombatant

export type Deps = {
	targeting: Targeting.Targeting?,
	-- Steps of change history kept; older revisions force a full delta.
	historySteps: number?,
	maxCuesPerBatch: number?,
}

export type Replication = {
	-- Pulls new simulation events, updates change tracking. Call once
	-- after every simulation step.
	collect: (self: Replication) -> (),
	-- Public view of one combatant, or nil.
	publicView: (self: Replication, id: string) -> PublicCombatant?,
	ownView: (self: Replication, id: string) -> OwnCombatant?,
	-- Delta for a viewer that last applied `since` (nil: never).
	delta: (self: Replication, viewerId: string?, since: number?) -> Delta,
	-- Cues the viewer has not received yet. Bounded; the oldest are
	-- dropped when a viewer falls too far behind.
	cues: (self: Replication, viewerId: string?) -> { Cue },
	forgetViewer: (self: Replication, viewerId: string) -> (),
	revision: (self: Replication) -> number,
}

local Replication = {}

Replication.DEFAULT_HISTORY_STEPS = 90
Replication.DEFAULT_MAX_CUES = 64
Replication.MAX_EVENT_HISTORY = 2048

-- Event kinds every client may see, with the data fields each carries.
local PUBLIC_CUES: { [string]: { string } } = {
	action_started = { "kind", "actionId" },
	phase_entered = { "phase", "actionId" },
	action_ended = { "actionId" },
	hit = { "target", "actionId" },
	damage = { "by", "outcome", "actionId" },
	interrupted = { "by" },
	parried = { "by" },
	guarded = { "by" },
	guard_broken = { "by" },
	died = {},
	combatant_added = { "team" },
	combatant_removed = {},
	target_acquired = { "target" },
	target_lost = { "reason" },
	cant_activated = { "cantId" },
}

-- Event kinds only the combatant itself may see.
local PRIVATE_CUES: { [string]: { string } } = {
	intent_rejected = { "kind", "sequence", "reason" },
}

type Tracked = { view: PublicCombatant, changedAt: number }
type Removal = { id: string, step: number }
type StoredEvent = { event: Simulation.Event, private: boolean }

local function round2(value: number): number
	return math.floor(value * 100 + 0.5) / 100
end

local function sameView(a: PublicCombatant, b: PublicCombatant): boolean
	return a.state == b.state
		and a.phase == b.phase
		and a.actionId == b.actionId
		and a.health == b.health
		and a.team == b.team
end

local function filterData(
	fields: { string },
	data: { [string]: any }?
): { [string]: string | number | boolean }?
	if data == nil then
		return nil
	end
	local out: { [string]: string | number | boolean } = {}
	local any = false
	for _, field in fields do
		local value = data[field]
		local kind = type(value)
		if kind == "string" or kind == "number" or kind == "boolean" then
			out[field] = value
			any = true
		end
	end
	return if any then out else nil
end

function Replication.new(sim: Simulation.Simulation, deps: Deps?): Replication
	local options: Deps = deps or {}
	local historySteps = options.historySteps or Replication.DEFAULT_HISTORY_STEPS
	local maxCues = options.maxCuesPerBatch or Replication.DEFAULT_MAX_CUES
	local tracked: { [string]: Tracked } = {}
	local removals: { Removal } = {}
	local events: { StoredEvent } = {}
	local firstEventIndex = 1 -- events before this index were dropped
	local cursors: { [string]: number } = {} -- viewer -> last event index seen
	local collectedAt = 0

	local replication = {} :: Replication

	local function buildPublic(combatant: Simulation.Combatant): PublicCombatant
		return {
			id = combatant.id,
			team = combatant.team,
			state = combatant.action.state,
			phase = combatant.action.phase,
			actionId = combatant.action.actionId,
			health = round2(
				math.clamp(
					combatant.resources.health / math.max(1, combatant.derived.maxHealth),
					0,
					1
				)
			),
		}
	end

	function replication:collect()
		local step = sim:stepNumber()
		collectedAt = step
		-- Views.
		local present: { [string]: boolean } = {}
		for _, id in sim:ids() do
			local combatant = sim:get(id)
			if combatant == nil then
				continue
			end
			present[id] = true
			local view = buildPublic(combatant)
			local entry = tracked[id]
			if entry == nil then
				tracked[id] = { view = view, changedAt = step }
			elseif not sameView(entry.view, view) then
				entry.view = view
				entry.changedAt = step
			end
		end
		for id in tracked do
			if not present[id] then
				tracked[id] = nil
				table.insert(removals, { id = id, step = step })
			end
		end
		-- Drop removal records older than the history window.
		while #removals > 0 and step - removals[1].step > historySteps do
			table.remove(removals, 1)
		end
		-- Events.
		for _, event in sim:drainEvents() do
			if PUBLIC_CUES[event.kind] ~= nil then
				table.insert(events, { event = event, private = false })
			elseif PRIVATE_CUES[event.kind] ~= nil then
				table.insert(events, { event = event, private = true })
			end
		end
		local overflow = #events - Replication.MAX_EVENT_HISTORY
		if overflow > 0 then
			for _ = 1, overflow do
				table.remove(events, 1)
			end
			firstEventIndex += overflow
		end
	end

	function replication:publicView(id: string): PublicCombatant?
		local entry = tracked[id]
		return if entry ~= nil then table.clone(entry.view) else nil
	end

	function replication:ownView(id: string): OwnCombatant?
		local combatant = sim:get(id)
		if combatant == nil then
			return nil
		end
		local targeting = options.targeting
		return {
			id = id,
			state = combatant.action.state,
			phase = combatant.action.phase,
			actionId = combatant.action.actionId,
			health = combatant.resources.health,
			maxHealth = combatant.derived.maxHealth,
			stamina = combatant.resources.stamina,
			maxStamina = combatant.derived.maxStamina,
			posture = combatant.resources.posture,
			maxPosture = combatant.derived.maxPosture,
			ackSequence = combatant.lastSequence,
			target = if targeting ~= nil then targeting:target(id) else nil,
			engaged = if targeting ~= nil then targeting:engaged(id) else false,
		}
	end

	function replication:delta(viewerId: string?, since: number?): Delta
		local step = collectedAt
		local full = since == nil
			or (since :: number) < step - historySteps
			or (since :: number) > step
		local combatants: { PublicCombatant } = {}
		local removed: { string } = {}
		local ids = {}
		for id in tracked do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local entry = tracked[id]
			if full or entry.changedAt > (since :: number) then
				table.insert(combatants, table.clone(entry.view))
			end
		end
		if not full then
			for _, removal in removals do
				if removal.step > (since :: number) then
					table.insert(removed, removal.id)
				end
			end
		end
		return {
			kind = "combat",
			revision = step,
			full = full,
			own = if viewerId ~= nil then replication:ownView(viewerId) else nil,
			combatants = combatants,
			removed = removed,
		}
	end

	function replication:cues(viewerId: string?): { Cue }
		local key = viewerId or ""
		local cursor = cursors[key] or (firstEventIndex - 1)
		if cursor < firstEventIndex - 1 then
			cursor = firstEventIndex - 1
		end
		local out: { Cue } = {}
		local lastIndex = firstEventIndex + #events - 1
		-- Start from the newest `maxCues`-ish window so a stalled viewer
		-- never receives an unbounded burst.
		local index = math.max(cursor + 1, lastIndex - Replication.MAX_EVENT_HISTORY + 1)
		while index <= lastIndex and #out < maxCues do
			local stored = events[index - firstEventIndex + 1]
			local event = stored.event
			local allowed = not stored.private or (viewerId ~= nil and event.id == viewerId)
			if allowed then
				local fields = if stored.private
					then PRIVATE_CUES[event.kind]
					else PUBLIC_CUES[event.kind]
				table.insert(out, {
					step = event.step,
					kind = event.kind,
					id = event.id,
					data = filterData(fields, event.data),
				})
			end
			index += 1
		end
		cursors[key] = index - 1
		return out
	end

	function replication:forgetViewer(viewerId: string)
		cursors[viewerId] = nil
	end

	function replication:revision(): number
		return collectedAt
	end

	return table.freeze(replication)
end

return table.freeze(Replication)
