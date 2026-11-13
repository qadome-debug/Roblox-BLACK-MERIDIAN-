--!strict
-- BM-018 / BM-020: the full ingress path under every rejection class.
--
-- Uses the real ClientHello adapter and a test adapter registered as
-- QuestChoice that records calls and can be told to fail, so every branch
-- of the dispatcher is exercised without any gameplay service.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local ClientHello = require(ServerScriptService.Server.Network.Adapters.ClientHello)
local Dispatcher = require(ServerScriptService.Server.Network.Dispatcher)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local RateLimiter = require(ServerScriptService.Server.Network.RateLimiter)
local Rejections = require(ServerScriptService.Server.Network.Rejections)
local Session = require(ServerScriptService.Server.Network.Session)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("Dispatcher")

type Harness = {
	dispatcher: Dispatcher.Dispatcher,
	sessions: Session.Service,
	player: Session.PlayerLike,
	epoch: string,
	calls: { any },
	-- Set to make the test adapter error or return a non-OK status.
	mode: { value: string },
	seq: { value: number },
	-- Builds a QuestChoice envelope with the next sequence number.
	request: (overrides: { [string]: any }?) -> { [string]: unknown },
	-- Runs the handshake and marks the profile loaded.
	ready: () -> (),
}

local PAYLOAD =
	{ questId = "quest-x", nodeId = "n1", choiceId = "c1", offerId = "o1", revision = 7 }

local function set(target: any, key: string, value: any)
	target[key] = value
end

local function harness(env: Suite.Env, userId: number?): Harness
	local pushed: { string } = {}
	local sessions = Session.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		sendEpoch = function(_player, epoch)
			table.insert(pushed, epoch)
		end,
	})
	local dispatcher = Dispatcher.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		sessions = sessions,
		limiter = RateLimiter.new({ clock = env.clock }),
	})
	dispatcher:register(ClientHello.new({ sessions = sessions, clock = env.clock }))

	local calls: { any } = {}
	local mode = { value = "ok" }
	dispatcher:register({
		action = "QuestChoice",
		requiresProfile = true,
		requiresReady = true,
		handle = function(ctx, payload)
			table.insert(calls, { ctx = ctx, payload = payload })
			if mode.value == "error" then
				error("adapter exploded")
			elseif mode.value == "stale" then
				return {
					requestId = ctx.requestId,
					status = "STALE_STATE",
					action = ctx.action,
					message = "internal detail",
				}
			elseif mode.value == "rejected" then
				return { requestId = ctx.requestId, status = "REJECTED", action = ctx.action }
			end
			return {
				requestId = ctx.requestId,
				status = "OK",
				action = ctx.action,
				stateRevision = 8,
				data = { questId = payload.questId, nextNodeId = "n2" } :: { [string]: unknown },
			}
		end,
	})

	local player: Session.PlayerLike = { UserId = userId or 1, Name = "tester" }
	sessions:onPlayerAdded(player)

	local h = {} :: Harness
	h.dispatcher = dispatcher
	h.sessions = sessions
	h.player = player
	h.epoch = pushed[1]
	h.calls = calls
	h.mode = mode
	h.seq = { value = 0 }

	h.request = function(overrides: { [string]: any }?): { [string]: unknown }
		h.seq.value += 1
		local raw: { [string]: unknown } = {
			v = 1,
			requestId = "req-" .. h.seq.value,
			sessionEpoch = h.epoch,
			seq = h.seq.value,
			action = "QuestChoice",
			payload = table.clone(PAYLOAD),
		}
		if overrides ~= nil then
			for key, value in overrides do
				raw[key] = value
			end
		end
		return raw
	end

	h.ready = function()
		local result = dispatcher:handle(
			player,
			h.request({ action = "ClientHello", payload = { protocolVersion = 1 } })
		)
		Assert.equal(result.status, "OK", "hello: " .. tostring(result.message))
		h.epoch = (result.data :: any).sessionEpoch
		sessions:markProfileLoaded(player, true)
	end

	return h
end

suite:case("happy path: hello, then a validated request reaches the adapter once", function(env)
	local h = harness(env)
	h.ready()
	local result = h.dispatcher:handle(h.player, h.request())
	Assert.equal(result.status, "OK", "accepted")
	Assert.equal(result.stateRevision, 8, "revision from adapter")
	Assert.equal((result.data :: any).nextNodeId, "n2", "data from adapter")
	Assert.count(h.calls, 1, "adapter called once")
	local ctx = h.calls[1].ctx
	Assert.equal(ctx.userId, 1, "identity from the Player object")
	Assert.equal(ctx.action, "QuestChoice", "action in context")
	Assert.isTrue(#ctx.correlationId == 16, "correlation id issued")
	Assert.equal(h.calls[1].payload.questId, "quest-x", "typed payload")
	Assert.count(env.logged("gameplay", "request_ok"), 2, "hello and quest both logged ok")
end)

suite:case("malformed and oversized envelopes are BAD_ENVELOPE with a safe message", function(env)
	local h = harness(env)
	h.ready()
	Assert.equal(h.dispatcher:handle(h.player, nil).status, "BAD_ENVELOPE", "nil envelope")
	for _, raw in { 5 :: any, "x", {}, { v = 2 } } do
		local result = h.dispatcher:handle(h.player, raw)
		Assert.equal(result.status, "BAD_ENVELOPE", "status")
		Assert.equal(result.message, Rejections.message("BAD_ENVELOPE"), "generic message")
	end
	local big =
		h.request({ payload = { blob = string.rep("x", Limits.RATE.choice.maxPayloadBytes) } })
	local result = h.dispatcher:handle(h.player, big)
	Assert.equal(result.status, "BAD_ENVELOPE", "oversized")
	Assert.equal(result.requestId, big.requestId, "request id echoed from the hint")
	Assert.count(h.calls, 0, "adapter never called")
	Assert.isTrue(#env.logged("security", "request_rejected") >= 6, "logged as security events")
end)

suite:case("unknown and unavailable actions are UNKNOWN_ACTION", function(env)
	local h = harness(env)
	h.ready()
	Assert.equal(
		h.dispatcher:handle(h.player, h.request({ action = "GrantReward" })).status,
		"UNKNOWN_ACTION",
		"unknown"
	)
	-- TravelReady has a validator but no adapter on this server.
	local result = h.dispatcher:handle(
		h.player,
		h.request({
			action = "TravelReady",
			payload = { ticketId = "t", ready = true, revision = 1 },
		})
	)
	Assert.equal(result.status, "UNKNOWN_ACTION", "registered but unavailable")
	Assert.equal(result.message, Rejections.message("UNKNOWN_ACTION"), "same message as unknown")
	Assert.count(h.calls, 0, "adapter never called")
end)

suite:case("no session, stale epoch, and requests before the handshake", function(env)
	local h = harness(env)
	local stranger: Session.PlayerLike = { UserId = 99, Name = "stranger" }
	Assert.equal(h.dispatcher:handle(stranger, h.request()).status, "NOT_READY", "no session")

	Assert.equal(
		h.dispatcher:handle(h.player, h.request()).status,
		"NOT_READY",
		"gameplay before hello"
	)
	Assert.equal(
		h.dispatcher:handle(h.player, h.request({ sessionEpoch = "forged" })).status,
		"STALE_EPOCH",
		"forged epoch"
	)

	local initial = h.epoch
	h.ready()
	Assert.equal(
		h.dispatcher:handle(h.player, h.request({ sessionEpoch = initial })).status,
		"STALE_EPOCH",
		"pre-hello epoch after hello"
	)
	Assert.equal(h.dispatcher:handle(h.player, h.request()).status, "OK", "current epoch works")

	local second = h.dispatcher:handle(
		h.player,
		h.request({ action = "ClientHello", payload = { protocolVersion = 1 } })
	)
	Assert.equal(second.status, "REJECTED", "second hello refused")
end)

suite:case("the initial epoch expires without a hello", function(env)
	local h = harness(env)
	env.clock:advance(Session.HELLO_TIMEOUT_SECONDS + 1)
	local result = h.dispatcher:handle(
		h.player,
		h.request({ action = "ClientHello", payload = { protocolVersion = 1 } })
	)
	Assert.equal(result.status, "STALE_EPOCH", "expired initial epoch")
end)

suite:case("hello with the wrong protocol version", function(env)
	local h = harness(env)
	local result = h.dispatcher:handle(
		h.player,
		h.request({ action = "ClientHello", payload = { protocolVersion = 2 } })
	)
	Assert.equal(result.status, "BAD_ENVELOPE", "version mismatch")
	Assert.equal(result.message, Rejections.message("BAD_ENVELOPE"), "sanitized message")
end)

suite:case("profile must be loaded for gameplay actions", function(env)
	local h = harness(env)
	local hello = h.dispatcher:handle(
		h.player,
		h.request({ action = "ClientHello", payload = { protocolVersion = 1 } })
	)
	h.epoch = (hello.data :: any).sessionEpoch
	Assert.equal(
		h.dispatcher:handle(h.player, h.request()).status,
		"NOT_READY",
		"profile not loaded"
	)
	h.sessions:markProfileLoaded(h.player, true)
	Assert.equal(h.dispatcher:handle(h.player, h.request()).status, "OK", "profile loaded")
	h.sessions:markProfileLoaded(h.player, false)
	Assert.equal(
		h.dispatcher:handle(h.player, h.request()).status,
		"NOT_READY",
		"profile unloaded again"
	)
end)

suite:case("duplicate request ids return the cached result without re-executing", function(env)
	local h = harness(env)
	h.ready()
	local raw = h.request()
	local first = h.dispatcher:handle(h.player, raw)
	local again = h.dispatcher:handle(h.player, raw)
	Assert.equal(first.status, "OK", "first")
	Assert.equal(again, first, "identical cached result object")
	Assert.count(h.calls, 1, "adapter ran once")

	local tampered = table.clone(raw)
	tampered.payload = table.clone(PAYLOAD)
	set(tampered.payload, "choiceId", "c2")
	Assert.equal(
		h.dispatcher:handle(h.player, tampered).status,
		"REPLAY",
		"same id, different payload"
	)

	local stale = h.request()
	stale.seq = 1
	Assert.equal(h.dispatcher:handle(h.player, stale).status, "REPLAY", "stale sequence")
	Assert.count(h.calls, 1, "still once")
end)

suite:case("rate limiting stops the flood before the adapter", function(env)
	local h = harness(env)
	h.ready()
	local okCount, limited = 0, 0
	for _ = 1, 50 do
		local status = h.dispatcher:handle(h.player, h.request()).status
		if status == "OK" then
			okCount += 1
		elseif status == "RATE_LIMITED" then
			limited += 1
		end
	end
	-- One token of the choice class went to nothing (hello is "session" class)
	-- so the burst is the full choice burst.
	Assert.equal(okCount, Limits.RATE.choice.burst, "burst admitted")
	Assert.equal(limited, 50 - okCount, "rest limited")
	Assert.count(h.calls, okCount, "adapter only ran for admitted requests")
	env.clock:advance(1)
	Assert.equal(h.dispatcher:handle(h.player, h.request()).status, "OK", "refilled")
end)

suite:case("bad payloads, including a forged userId, are BAD_PAYLOAD", function(env)
	local h = harness(env)
	h.ready()
	local forged = h.request()
	set(forged.payload, "userId", 999)
	Assert.equal(h.dispatcher:handle(h.player, forged).status, "BAD_PAYLOAD", "extra field")
	Assert.equal(
		h.dispatcher:handle(h.player, h.request({ payload = { questId = "quest-x" } })).status,
		"BAD_PAYLOAD",
		"missing fields"
	)
	local noPayload = h.request()
	noPayload.payload = nil
	Assert.equal(h.dispatcher:handle(h.player, noPayload).status, "BAD_PAYLOAD", "nil payload")
	Assert.count(h.calls, 0, "adapter never called")
end)

suite:case("adapter errors are INTERNAL, nothing is cached, and a retry works", function(env)
	local h = harness(env)
	h.ready()
	h.mode.value = "error"
	local raw = h.request()
	local result = h.dispatcher:handle(h.player, raw)
	Assert.equal(result.status, "INTERNAL", "status")
	Assert.equal(result.message, Rejections.message("INTERNAL"), "no stack trace to the client")
	Assert.count(env.logged("network", "request_failed"), 1, "error logged")
	Assert.contains(
		tostring(env.logged("network", "request_failed")[1].fields.reason),
		"adapter exploded",
		"reason in log"
	)

	h.mode.value = "ok"
	local retry = table.clone(raw)
	h.seq.value += 1
	retry.seq = h.seq.value
	Assert.equal(h.dispatcher:handle(h.player, retry).status, "OK", "retry with a new seq succeeds")
end)

suite:case("adapter rejections are sanitized and cached", function(env)
	local h = harness(env)
	h.ready()
	h.mode.value = "stale"
	local raw = h.request()
	local result = h.dispatcher:handle(h.player, raw)
	Assert.equal(result.status, "STALE_STATE", "status passthrough")
	Assert.equal(result.message, Rejections.message("STALE_STATE"), "internal detail replaced")
	Assert.equal(h.dispatcher:handle(h.player, raw), result, "cached")
	Assert.count(h.calls, 1, "ran once")
	h.mode.value = "rejected"
	Assert.equal(
		h.dispatcher:handle(h.player, h.request()).status,
		"REJECTED",
		"illegal transition"
	)
	Assert.count(
		env.logged("gameplay", "request_rejected"),
		2,
		"gameplay-category log, not security"
	)
end)

suite:case(
	"register refuses unknown actions, duplicates, and actions without validators",
	function(env)
		local h = harness(env)
		local function adapter(action: string): Dispatcher.Adapter
			return {
				action = action :: any,
				requiresProfile = true,
				requiresReady = true,
				handle = function(ctx)
					return { requestId = ctx.requestId, status = "OK", action = ctx.action }
				end,
			}
		end
		Assert.throws(function()
			h.dispatcher:register(adapter("GrantReward"))
		end, "not a registered action")
		Assert.throws(function()
			h.dispatcher:register(adapter("QuestChoice"))
		end, "already registered")
		Assert.throws(function()
			h.dispatcher:register(adapter("CombatInput"))
		end, "no payload validator")
		Assert.deepEqual(
			h.dispatcher:registeredActions(),
			{ "ClientHello", "QuestChoice" },
			"registered set"
		)
	end
)

suite:case("players are isolated from each other", function(env)
	local a = harness(env, 1)
	a.ready()
	local b: Session.PlayerLike = { UserId = 2, Name = "other" }
	a.sessions:onPlayerAdded(b)
	-- Player B presenting player A's epoch and request ids gets nowhere.
	local result = a.dispatcher:handle(b, a.request())
	Assert.equal(result.status, "STALE_EPOCH", "A's epoch is not B's")
	Assert.count(a.calls, 0, "nothing executed for B")
end)

return suite:cases()
