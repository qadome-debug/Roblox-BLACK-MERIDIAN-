--!strict
-- Typed request payloads fixed by Technical Plan 2.0 (3.4, 3.5) and the
-- session bootstrap (3.1). Payloads for other actions are defined by the
-- task that owns the action, in this module, when that task lands.
--
-- A value of one of these types exists only after the matching strict
-- validator (BM-013) has accepted raw client input. Nothing constructs one
-- from a client table directly.

-- 3.4 QuestChoice. Owning task BM-074.
export type QuestChoicePayload = {
	questId: string, -- canonical, <= 48 bytes
	nodeId: string, -- canonical, <= 48 bytes
	choiceId: string, -- canonical, <= 48 bytes
	offerId: string, -- server-issued opaque, <= 64 bytes
	revision: number, -- nonnegative integer, matches authoritative quest revision
}

export type QuestChoiceResultData = {
	questId: string,
	nextNodeId: string,
}

-- 3.5 TravelReady. Owning task BM-090.
export type TravelReadyPayload = {
	ticketId: string, -- server-issued opaque, <= 64 bytes
	ready: boolean, -- strict boolean
	revision: number, -- current travel roster revision
}

-- CombatInput. Owning task BM-061. `kind` is the legal action enum: timed
-- actions go to the simulation as intents, the Lock/Unlock/CycleTarget kinds
-- are validated lock-on requests. `sequence` is per-player monotonic for
-- intents (ignored for lock kinds). `target` is only a preference: the
-- server finds hits itself and validates any lock.
export type CombatInputKind =
	"Attack"
	| "Dodge"
	| "Guard"
	| "Parry"
	| "Release"
	| "Lock"
	| "Unlock"
	| "CycleTarget"

export type CombatInputPayload = {
	kind: CombatInputKind,
	sequence: number, -- integer 1 .. Limits.MAX_REVISION
	target: string?, -- combatant id, opaque, <= 64 bytes
}

export type CombatInputResultData = {
	kind: CombatInputKind,
	sequence: number,
	-- For intents: queued for the next simulation step. Whether it then
	-- starts is reported by the acknowledgement and private cues.
	queued: boolean,
	target: string?,
}

-- Cant equipment. Owning task BM-064. `cantId` nil unequips the slot.
export type CantSlot = "primary" | "secondary"

export type CantEquipPayload = {
	slot: CantSlot,
	cantId: string?, -- canonical cant id
}

export type CantEquipResultData = {
	slot: CantSlot,
	cantId: string?,
	changed: boolean,
}

-- Verse casting. Owning task BM-067. The target is a hint the server
-- verifies (existence, liveness, range), never a claim.
export type VerseCastPayload = {
	verseId: string, -- canonical verse id
	target: string?, -- combatant id, opaque, <= 64 bytes
}

export type VerseCastResultData = {
	verseId: string,
	target: string?,
	resolveStep: number,
}

-- Dissonance actions. Owning task BM-068. Names an action only; the meter
-- is server state and is never sent by the client.
export type DissonanceActionPayload = {
	actionId: string, -- opaque, <= 64 bytes, judged against server actions
}

export type DissonanceActionResultData = {
	actionId: string,
	level: number,
}

-- Session bootstrap. Owning task BM-017.
export type ClientHelloPayload = {
	protocolVersion: number,
}

export type ClientHelloResultData = {
	sessionEpoch: string,
	serverTime: number,
}

return {}
