--!strict
-- BM-012: envelope parsing accepts exactly the contract and nothing else.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Envelope = require(ServerScriptService.Server.Network.Envelope)
local Fuzz = require(ServerStorage.Tests.Support.Fuzz)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Envelope")

local function good(): { [string]: unknown }
	return {
		v = 1,
		requestId = "0f3a9c2e-4b1d-4e6f-8a7b-1c2d3e4f5a6b",
		sessionEpoch = "epoch-abc123",
		seq = 42,
		action = "QuestChoice",
		payload = {
			questId = "quest-x",
			nodeId = "n1",
			choiceId = "c1",
			offerId = "o1",
			revision = 7,
		},
	}
end

local function expectReject(raw: unknown, status: string, needle: string?)
	local request, got, reason = Envelope.parse(raw)
	Assert.isNil(request, "request must be nil")
	Assert.equal(got, status, "status for " .. tostring(reason))
	if needle ~= nil then
		Assert.contains(tostring(reason), needle, "reason")
	end
end

suite:case("a well-formed envelope parses to a typed request", function()
	local request = Envelope.parse(good())
	Assert.notNil(request, "parsed")
	local r = request :: any
	Assert.equal(r.action, "QuestChoice", "action")
	Assert.equal(r.rateClass, "choice", "rate class")
	Assert.equal(r.seq, 42, "seq")
	Assert.equal(r.requestId, "0f3a9c2e-4b1d-4e6f-8a7b-1c2d3e4f5a6b", "requestId")
	Assert.isTrue(r.payloadBytes > 0 and r.payloadBytes < 512, "measured payload")
	Assert.equal((r.payload :: any).questId, "quest-x", "payload passed through untyped")
end)

suite:case("nil payload is allowed", function()
	local raw = good()
	raw.payload = nil
	raw.action = "ClientHello"
	local request = Envelope.parse(raw)
	Assert.notNil(request, "parsed")
	Assert.equal((request :: any).payloadBytes, 4, "nil measured")
end)

suite:case("non-table and extra fields are rejected", function()
	expectReject(nil, "BAD_ENVELOPE", "not a table")
	expectReject("hello", "BAD_ENVELOPE")
	expectReject(42, "BAD_ENVELOPE")
	local raw = good()
	raw.userId = 12345
	expectReject(raw, "BAD_ENVELOPE", "unexpected envelope field userId")
	local withArrayKey = good() :: any
	withArrayKey[1] = "x"
	expectReject(withArrayKey, "BAD_ENVELOPE", "unexpected envelope field")
end)

-- Values of mixed types for boundary loops; nil is tested separately
-- because it cannot live in an array literal.
local function mixed(...: any): { any }
	return { ... }
end

suite:case("protocol version must match exactly", function()
	for _, v in mixed(0, 2, "1", 1.5, true) do
		local raw = good()
		raw.v = v
		expectReject(raw, "BAD_ENVELOPE", "protocol version")
	end
	local raw = good()
	raw.v = nil
	expectReject(raw, "BAD_ENVELOPE", "protocol version")
end)

suite:case("requestId and sessionEpoch are bounded ids", function()
	for _, bad in mixed("", 12, "has space", "x;y", string.rep("a", 65), { "a" }) do
		local raw = good()
		raw.requestId = bad
		expectReject(raw, "BAD_ENVELOPE", "requestId")
		raw = good()
		raw.sessionEpoch = bad
		expectReject(raw, "BAD_ENVELOPE", "sessionEpoch")
	end
	local raw = good()
	raw.requestId = nil
	expectReject(raw, "BAD_ENVELOPE", "requestId")
	raw = good()
	raw.sessionEpoch = nil
	expectReject(raw, "BAD_ENVELOPE", "sessionEpoch")
	raw = good()
	raw.requestId = string.rep("a", 64)
	Assert.notNil(Envelope.parse(raw), "64 bytes ok")
end)

suite:case("seq must be a nonnegative bounded integer", function()
	for _, bad in mixed(-1, 1.5, 0 / 0, math.huge, 2 ^ 31, "3") do
		local raw = good()
		raw.seq = bad
		expectReject(raw, "BAD_ENVELOPE", "seq")
	end
	local raw = good()
	raw.seq = nil
	expectReject(raw, "BAD_ENVELOPE", "seq")
	raw = good()
	raw.seq = 0
	Assert.notNil(Envelope.parse(raw), "zero ok")
	raw.seq = 2 ^ 31 - 1
	Assert.notNil(Envelope.parse(raw), "max ok")
end)

suite:case("unknown actions are rejected with UNKNOWN_ACTION", function()
	for _, bad in mixed("GrantReward", "questchoice", "", 5, {}) do
		local raw = good()
		raw.action = bad
		expectReject(raw, "UNKNOWN_ACTION")
	end
	local raw = good()
	raw.action = nil
	expectReject(raw, "UNKNOWN_ACTION")
end)

suite:case("payload structure is bounded", function()
	local raw = good()
	raw.payload = "string"
	expectReject(raw, "BAD_ENVELOPE", "payload must be a table")

	raw = good()
	raw.payload = { n = 0 / 0 }
	expectReject(raw, "BAD_ENVELOPE", "non-finite")

	raw = good()
	raw.payload = { s = string.rep("x", Limits.MAX_STRING_BYTES + 1) }
	expectReject(raw, "BAD_ENVELOPE", "string longer")

	raw = good()
	local deep: { [string]: unknown } = {}
	local cursor = deep
	for _ = 1, Limits.MAX_PAYLOAD_DEPTH + 1 do
		local next = {}
		cursor.child = next
		cursor = next
	end
	raw.payload = deep
	expectReject(raw, "BAD_ENVELOPE", "nesting deeper")

	raw = good()
	local wide: { [string]: unknown } = {}
	for i = 1, Limits.MAX_PAYLOAD_FIELDS + 1 do
		wide["f" .. i] = i
	end
	raw.payload = wide
	expectReject(raw, "BAD_ENVELOPE", "more than")

	raw = good()
	local long: { number } = {}
	for i = 1, Limits.MAX_PAYLOAD_ARRAY_ITEMS + 1 do
		long[i] = i
	end
	raw.payload = { list = long }
	expectReject(raw, "BAD_ENVELOPE", "array longer")

	raw = good()
	raw.payload = { [true] = 1 }
	expectReject(raw, "BAD_ENVELOPE", "unsupported key type")

	raw = good()
	raw.payload = { [1] = "a", [3] = "b" }
	expectReject(raw, "BAD_ENVELOPE", "sparse")

	raw = good()
	raw.payload = { f = function() end }
	expectReject(raw, "BAD_ENVELOPE", "unsupported value type")
end)

suite:case("payload size respects the action's rate class", function()
	-- Combat payloads are capped at 256 bytes; choices at 512.
	local raw = good()
	raw.action = "CombatInput"
	raw.payload = { blob = string.rep("x", 250) }
	expectReject(raw, "BAD_ENVELOPE", "exceeds the combat limit")
	raw.action = "QuestChoice"
	Assert.notNil(Envelope.parse(raw), "same payload fits the choice class")
	raw.payload = { blob = string.rep("x", 256), more = string.rep("y", 256) }
	expectReject(raw, "BAD_ENVELOPE", "exceeds")
end)

suite:case("response builders produce the contract shape", function()
	local ok = Envelope.ok("r1", "QuestChoice", 8, { questId = "quest-x", nextNodeId = "n2" })
	Assert.equal(ok.status, "OK", "ok status")
	Assert.equal(ok.stateRevision, 8, "revision")
	Assert.equal((ok.data :: any).nextNodeId, "n2", "data")
	local rejected = Envelope.reject("r1", "QuestChoice", "STALE_STATE", "Please refresh")
	Assert.equal(rejected.status, "STALE_STATE", "status")
	Assert.equal(rejected.message, "Please refresh", "message")
	Assert.isNil(rejected.data, "no data on rejection")
	local anonymous = Envelope.reject(nil, nil, "BAD_ENVELOPE")
	Assert.equal(anonymous.requestId, "", "empty requestId when unknown")
end)

suite:caseWithSeeds(
	"fuzz: parse never throws and never accepts a malformed envelope",
	{ 1, 2, 3 },
	function(env)
		local rng = env.rng:fork("envelope")
		local accepted = 0
		for _ = 1, 2000 do
			local raw: unknown
			if rng:chance(0.7) then
				raw = Fuzz.nearMiss(rng, good())
			else
				raw = Fuzz.value(rng, 3)
			end
			local okCall, request = pcall(Envelope.parse :: (unknown) -> any, raw)
			Assert.isTrue(okCall, "parse threw: " .. tostring(request))
			if request ~= nil then
				accepted += 1
				local r = request :: any
				Assert.equal(r.v, 1, "version")
				Assert.isTrue(
					type(r.requestId) == "string" and #r.requestId <= 64,
					"requestId bounds"
				)
				Assert.isTrue(r.seq >= 0 and r.seq % 1 == 0, "seq bounds")
				Assert.isTrue(r.payload == nil or type(r.payload) == "table", "payload kind")
				Assert.isTrue(
					r.payloadBytes <= Limits.RATE.envelope.maxPayloadBytes,
					"payload size"
				)
			end
		end
		Assert.isTrue(accepted > 0, "some near-miss envelopes were valid")
	end
)

return suite:cases()
