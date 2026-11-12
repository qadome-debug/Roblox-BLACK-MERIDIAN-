--!strict
-- BM-016: duplicate, reordered, modified and stale requests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)
local Replay = require(ServerScriptService.Server.Network.Replay)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Replay")

local PAYLOAD =
	{ questId = "quest-x", nodeId = "n1", choiceId = "c1", offerId = "o1", revision = 7 }

local function result(requestId: string): Protocol.ActionResult
	return {
		requestId = requestId,
		status = "OK",
		action = "QuestChoice",
		stateRevision = 8,
	}
end

suite:case("fingerprints are stable across key order and sensitive to content", function()
	local a = Replay.fingerprint("QuestChoice", { x = 1, y = { "a", "b" }, z = true })
	local b = Replay.fingerprint("QuestChoice", { z = true, y = { "a", "b" }, x = 1 })
	Assert.equal(a, b, "key order does not matter")
	Assert.notEqual(
		a,
		Replay.fingerprint("QuestChoice", { x = 1, y = { "b", "a" }, z = true }),
		"array order matters"
	)
	Assert.notEqual(
		a,
		Replay.fingerprint("QuestChoice", { x = "1", y = { "a", "b" }, z = true }),
		"type matters"
	)
	Assert.notEqual(
		a,
		Replay.fingerprint("TravelReady", { x = 1, y = { "a", "b" }, z = true }),
		"action matters"
	)
	Assert.notEqual(Replay.fingerprint("A", nil), Replay.fingerprint("A", {}), "nil vs empty")
end)

suite:case(
	"a fresh request is accepted and an identical retry gets the cached result",
	function(env)
		local state = Replay.newState()
		local fp = Replay.fingerprint("QuestChoice", PAYLOAD)
		local now = env.clock:now()

		local verdict = Replay.check(state, "r1", 1, fp, now)
		Assert.equal(verdict, "accept", "first")
		Replay.begin(state, "r1", 1, fp, now)
		Assert.equal(state.lastSeq, 1, "sequence advanced")

		local inflight = Replay.check(state, "r1", 1, fp, now)
		Assert.equal(inflight, "inflight", "while executing")

		Replay.commit(state, "r1", result("r1"))
		local again, cached = Replay.check(state, "r1", 1, fp, now)
		Assert.equal(again, "duplicate", "retry")
		Assert.equal((cached :: any).stateRevision, 8, "original result returned")
		-- Even with a new, higher sequence the same ID is still the same request.
		local later = Replay.check(state, "r1", 50, fp, now)
		Assert.equal(later, "duplicate", "duplicate regardless of seq")
		Assert.equal(state.lastSeq, 1, "duplicates do not advance the sequence")
	end
)

suite:case("reused request id with a different payload is a conflict", function(env)
	local state = Replay.newState()
	local now = env.clock:now()
	local fp = Replay.fingerprint("QuestChoice", PAYLOAD)
	Replay.begin(state, "r1", 1, fp, now)
	Replay.commit(state, "r1", result("r1"))
	local tampered = table.clone(PAYLOAD)
	tampered.choiceId = "c2"
	local verdict, cached =
		Replay.check(state, "r1", 2, Replay.fingerprint("QuestChoice", tampered), now)
	Assert.equal(verdict, "conflict", "modified payload")
	Assert.isNil(cached, "no result for a conflict")
end)

suite:case("stale and reordered sequences are rejected", function(env)
	local state = Replay.newState()
	local now = env.clock:now()
	local fp = Replay.fingerprint("QuestChoice", PAYLOAD)
	Replay.begin(state, "r5", 5, fp, now)
	Replay.commit(state, "r5", result("r5"))
	Assert.equal((Replay.check(state, "r4", 4, fp, now)), "stale", "older seq")
	Assert.equal((Replay.check(state, "r5b", 5, fp, now)), "stale", "equal seq, new id")
	Assert.equal((Replay.check(state, "r6", 6, fp, now)), "accept", "next seq")
	Replay.begin(state, "r6", 6, fp, now)
	Assert.equal((Replay.check(state, "r100", 100, fp, now)), "accept", "gaps are allowed")
end)

suite:case("abandon frees the id so the client can retry with a new sequence", function(env)
	local state = Replay.newState()
	local now = env.clock:now()
	local fp = Replay.fingerprint("QuestChoice", PAYLOAD)
	Replay.begin(state, "r1", 1, fp, now)
	Replay.abandon(state, "r1")
	Assert.equal(state.count, 0, "entry removed")
	Assert.count(state.order, 0, "order cleared")
	Assert.equal((Replay.check(state, "r1", 1, fp, now)), "stale", "old seq still stale")
	Assert.equal((Replay.check(state, "r1", 2, fp, now)), "accept", "same id, new seq accepted")
end)

suite:case("the cache is bounded by time and by entry count", function(env)
	local state = Replay.newState()
	local fp = Replay.fingerprint("QuestChoice", PAYLOAD)
	local start = env.clock:now()
	Replay.begin(state, "old", 1, fp, start)
	Replay.commit(state, "old", result("old"))
	env.clock:advance(Replay.CACHE_SECONDS + 1)
	Assert.equal(
		(Replay.check(state, "old", 1, fp, env.clock:now())),
		"stale",
		"expired entry is no longer a duplicate"
	)
	Assert.equal(state.count, 0, "expired entry pruned")

	for i = 1, Replay.MAX_ENTRIES + 100 do
		local id = "r" .. i
		Replay.begin(state, id, 10 + i, fp, env.clock:now())
		Replay.commit(state, id, result(id))
	end
	Replay.prune(state, env.clock:now())
	Assert.equal(state.count, Replay.MAX_ENTRIES, "capped")
	Assert.count(state.order, Replay.MAX_ENTRIES, "order matches")
	Assert.isNil(state.entries.r1, "oldest evicted")
	Assert.notNil(state.entries["r" .. (Replay.MAX_ENTRIES + 100)], "newest kept")
end)

suite:case(
	"state is per session: another session's ids and sequences do not interfere",
	function(env)
		local a = Replay.newState()
		local b = Replay.newState()
		local now = env.clock:now()
		local fp = Replay.fingerprint("QuestChoice", PAYLOAD)
		Replay.begin(a, "r1", 9, fp, now)
		Replay.commit(a, "r1", result("r1"))
		Assert.equal(
			(Replay.check(b, "r1", 1, fp, now)),
			"accept",
			"same id is new in another session"
		)
	end
)

return suite:cases()
