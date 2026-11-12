--!strict
-- Client/server protocol contracts (Technical Plan 2.0, 3.1, 3.2, 3.4).
--
-- One versioned ingress, `ActionRequest`, answered by `ActionResult`.
-- Server-to-client presentation goes over separate one-way remotes whose
-- names are listed here; they carry no authority.

local Actions = require(script.Parent.Actions)

export type ActionName = Actions.ActionName

local Protocol = {}

Protocol.VERSION = 1

-- Remote names. The dispatcher creates exactly these and nothing else.
Protocol.REMOTES = table.freeze({
	-- Client -> server (RemoteEvent). The only gameplay ingress.
	ACTION_REQUEST = "ActionRequest",
	-- Server -> client (RemoteEvent).
	ACTION_RESULT = "ActionResult",
	STATE_DELTA = "StateDelta",
	COMBAT_CUE = "CombatCue",
	PARTY_STATE = "PartyState",
	TRAVEL_STATE = "TravelState",
})

-- Request envelope as sent by the client. Everything in it is untrusted
-- until the validation sequence has run; `payload` stays `unknown` on
-- purpose and only becomes typed after the action's validator accepts it.
export type ActionRequest = {
	v: number,
	requestId: string,
	sessionEpoch: string,
	seq: number,
	action: string,
	payload: unknown,
}

-- Outcome codes. `OK` is the only success. BM-019 standardizes client-safe
-- messages for each rejection; the codes themselves are fixed here so every
-- adapter speaks the same vocabulary from the start.
export type Status =
	"OK"
	| "BAD_ENVELOPE" -- version, structure, request ID or sequence invalid
	| "UNKNOWN_ACTION" -- action not in the registry (default deny)
	| "NOT_READY" -- no session, profile not loaded, or lease not held
	| "STALE_EPOCH" -- session epoch is not the current one
	| "REPLAY" -- stale sequence or request ID reused with a different payload
	| "RATE_LIMITED" -- action or envelope budget exceeded
	| "BAD_PAYLOAD" -- payload failed its schema validator
	| "UNAUTHORIZED" -- player does not own or is not eligible for the target
	| "STALE_STATE" -- revision or offer no longer current; client must refresh
	| "REJECTED" -- legal request, but the world state does not allow it now
	| "INTERNAL" -- server-side failure; nothing was committed

export type ActionResult = {
	requestId: string,
	status: Status,
	action: string,
	-- Authoritative revision of the state the action touched. Clients use it
	-- to detect staleness, never to assert anything.
	stateRevision: number?,
	-- Action-specific success data. Typed per action by its owning task;
	-- never reveals hidden progression or anti-cheat thresholds.
	data: { [string]: unknown }?,
	-- Client-safe message for non-OK statuses.
	message: string?,
}

function Protocol.isSuccess(result: ActionResult): boolean
	return result.status == "OK"
end

return table.freeze(Protocol)
