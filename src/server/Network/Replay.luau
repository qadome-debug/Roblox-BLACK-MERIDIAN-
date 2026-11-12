--!strict
-- Replay protection (BM-016).
--
-- Per-session state that makes a request effectively once-only within the
-- session:
--   * a monotonic sequence number: a request whose seq is not greater than
--     the last accepted one is stale, unless it is a byte-for-byte repeat of
--     a request whose result is cached (then the cached result is returned),
--   * request-ID deduplication with a payload fingerprint: the same ID with
--     a different payload is a conflict and is rejected,
--   * a bounded result cache (time window and entry cap) so memory stays
--     flat under flood.
--
-- This protects gameplay mutations within a session. It is not durable:
-- reward and permanent-progression idempotency lives with the profile
-- (BM-036 onward), keyed by receipts, and survives crashes and reconnects.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

export type Entry = {
	fingerprint: string,
	seq: number,
	startedAt: number,
	-- nil while the request is still executing.
	result: Protocol.ActionResult?,
}

export type State = {
	lastSeq: number,
	entries: { [string]: Entry },
	-- Request IDs in arrival order, for bounded eviction.
	order: { string },
	count: number,
}

export type Verdict = "accept" | "duplicate" | "inflight" | "conflict" | "stale"

local Replay = {}

Replay.CACHE_SECONDS = Limits.DUPLICATE_RESULT_CACHE_SECONDS
Replay.MAX_ENTRIES = 512

function Replay.newState(): State
	return { lastSeq = -1, entries = {}, order = {}, count = 0 }
end

-- Deterministic serialization of a payload: sorted keys, typed scalars.
local function serialize(value: unknown, out: { string })
	local kind = type(value)
	if kind == "table" then
		local t = value :: { [any]: unknown }
		local keys = {}
		for key in t do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			local ta, tb = type(a), type(b)
			if ta ~= tb then
				return ta < tb
			end
			return tostring(a) < tostring(b)
		end)
		table.insert(out, "{")
		for _, key in keys do
			table.insert(out, type(key) .. ":" .. tostring(key) .. "=")
			serialize(t[key], out)
			table.insert(out, ";")
		end
		table.insert(out, "}")
	else
		table.insert(out, kind .. ":" .. tostring(value))
	end
end

-- 64 bits of FNV-style hash over the canonical form, plus its length.
function Replay.fingerprint(action: string, payload: unknown): string
	local parts = { "action:", action, "|" }
	serialize(payload, parts)
	local canonical = table.concat(parts)
	local a = Rng.hashString(canonical)
	local b = Rng.hashString("\1" .. canonical .. "\2")
	return string.format("%08x%08x:%d", a, b, #canonical)
end

local function evict(state: State, requestId: string)
	if state.entries[requestId] ~= nil then
		state.entries[requestId] = nil
		state.count -= 1
	end
end

-- Drops entries outside the cache window and beyond the entry cap.
function Replay.prune(state: State, now: number)
	local keep = {}
	for _, requestId in state.order do
		local entry = state.entries[requestId]
		if entry ~= nil and now - entry.startedAt <= Replay.CACHE_SECONDS then
			table.insert(keep, requestId)
		else
			evict(state, requestId)
		end
	end
	while #keep > Replay.MAX_ENTRIES do
		evict(state, table.remove(keep, 1) :: string)
	end
	state.order = keep
end

-- Decides what to do with a request. Returns the verdict and, for
-- "duplicate", the cached result to resend.
function Replay.check(
	state: State,
	requestId: string,
	seq: number,
	fingerprint: string,
	now: number
): (Verdict, Protocol.ActionResult?)
	Replay.prune(state, now)
	local entry = state.entries[requestId]
	if entry ~= nil then
		if entry.fingerprint ~= fingerprint then
			return "conflict", nil
		end
		if entry.result == nil then
			return "inflight", nil
		end
		return "duplicate", entry.result
	end
	if seq <= state.lastSeq then
		return "stale", nil
	end
	return "accept", nil
end

-- Reserves the request ID and advances the sequence. Call only after
-- `check` returned "accept".
function Replay.begin(
	state: State,
	requestId: string,
	seq: number,
	fingerprint: string,
	now: number
)
	state.entries[requestId] =
		{ fingerprint = fingerprint, seq = seq, startedAt = now, result = nil }
	state.count += 1
	table.insert(state.order, requestId)
	state.lastSeq = seq
end

-- Records the outcome so an identical retry gets the same answer.
function Replay.commit(state: State, requestId: string, result: Protocol.ActionResult)
	local entry = state.entries[requestId]
	if entry ~= nil then
		entry.result = result
	end
end

-- Forgets a reservation whose execution failed before producing a result,
-- so the client may retry with a new sequence.
function Replay.abandon(state: State, requestId: string)
	evict(state, requestId)
	local index = table.find(state.order, requestId)
	if index then
		table.remove(state.order, index)
	end
end

return table.freeze(Replay)
