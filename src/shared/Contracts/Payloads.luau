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

-- Session bootstrap. Owning task BM-017.
export type ClientHelloPayload = {
	protocolVersion: number,
}

export type ClientHelloResultData = {
	sessionEpoch: string,
	serverTime: number,
}

return {}
